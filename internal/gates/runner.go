package gates

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"time"
)

// CommandRunner abstracts subprocess exec for phases. Production wiring
// uses ExecRunner (which forks `bash -c <cmd>`); tests substitute a
// deterministic fake.
//
// The contract mirrors the bash `timeout 124` semantics: when a command
// exceeds its timeout, the runner returns exit code 124 and the bash gate
// treats that as Pass with a warning. Phases that need to distinguish a
// real exit code 124 from a timeout can check ctx.Err() — production
// ExecRunner sets ctx.Err() to context.DeadlineExceeded on timeout.
type CommandRunner interface {
	Run(ctx context.Context, cmd string, timeout time.Duration) (output []byte, exitCode int, timedOut bool, err error)
}

// ExecRunner is the production CommandRunner. Each invocation forks
// `bash -c <cmd>` with stdin explicitly set to nil so the subprocess
// cannot block on `read < /dev/tty` (the M27.2 hang site).
type ExecRunner struct {
	// Bash is the bash binary path. Defaults to "bash" (PATH lookup).
	// Tests override to "/bin/false" to deterministically force a failure
	// without spawning a shell.
	Bash string
}

// Run implements CommandRunner. Empty cmd returns (nil, 0, false, nil) so
// gates can pass zero-config phases through (e.g. BUILD_CHECK_CMD unset).
func (r ExecRunner) Run(ctx context.Context, cmd string, timeout time.Duration) ([]byte, int, bool, error) {
	out, exit, timedOut, err := runBashCmd(ctx, r.Bash, cmd, nil, timeout)
	return out, exit, timedOut, err
}

// UIEnvRunner implements UICommandRunner for production. Mirrors
// ExecRunner's bash semantics (M27.2 stdin guard, timeout 124 mapping)
// while injecting the supplied env list at the exec(1) boundary so it
// never leaks into the parent shell.
type UIEnvRunner struct {
	// Bash is the bash binary path. Defaults to "bash" (PATH lookup).
	Bash string
}

// Run implements UICommandRunner. The env slice is appended to os.Environ()
// so PATH/HOME survive; UI-gate-specific keys (PLAYWRIGHT_HTML_OPEN=never,
// CI=1) take precedence because Go's exec uses the LAST occurrence of a
// duplicate key.
func (r UIEnvRunner) Run(ctx context.Context, cmd string, env []string, timeout time.Duration) ([]byte, int, error) {
	out, exit, _, err := runBashCmd(ctx, r.Bash, cmd, env, timeout)
	return out, exit, err
}

// runBashCmd is the shared bash-c subprocess driver for ExecRunner and
// UIEnvRunner. Empty cmd returns immediately. timeout==0 disables the
// deadline; non-zero wraps ctx in WithTimeout.
//
// Output streams (stdout + stderr) are captured into a single buffer so
// the gate's grep + sed pipeline sees the same byte stream the bash side
// produced via `2>&1`.
//
// Exit code mapping:
//   - subprocess exits 0 → (out, 0, false, nil)
//   - subprocess exits N → (out, N, false, nil)
//   - context deadline    → (out, 124, true, nil)  (parity with bash timeout 124)
//   - unexpected runtime  → (out, -1, false, err)
func runBashCmd(ctx context.Context, bash, cmd string, env []string, timeout time.Duration) ([]byte, int, bool, error) {
	if cmd == "" {
		return nil, 0, false, nil
	}
	if bash == "" {
		bash = "bash"
	}
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	c := exec.CommandContext(ctx, bash, "-c", cmd)
	c.Stdin = nil // M27.2: prevent read < /dev/tty from blocking the gate
	if len(env) > 0 {
		c.Env = append(defaultEnviron(), env...)
	}
	var buf bytes.Buffer
	c.Stdout = &buf
	c.Stderr = &buf
	runErr := c.Run()
	out := buf.Bytes()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return out, 124, true, nil
	}
	if runErr == nil {
		return out, 0, false, nil
	}
	var ee *exec.ExitError
	if errors.As(runErr, &ee) {
		return out, ee.ExitCode(), false, nil
	}
	return out, -1, false, runErr
}
