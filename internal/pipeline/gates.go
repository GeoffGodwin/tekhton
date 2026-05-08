package pipeline

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Sentinel errors for gate failures.
var (
	// ErrGateTimeout is returned when the gate runs past its configured
	// timeout. Mirrors lib/gates.sh's BUILD_GATE_TIMEOUT behavior.
	ErrGateTimeout = errors.New("pipeline: gate timed out")
)

// BuildGate runs the analyze + compile + UI commands after the coder stage.
// On failure, the runner re-invokes coder up to MaxBuildRetries times.
//
// This is the *gate* — does the build pass? — not the *fix loop* (M128 in
// stages/coder_buildfix.sh, which stays bash). The gate is policy: pass/fail.
type BuildGate struct {
	// AnalyzeCmd is the static-analysis command (e.g. "go vet ./..." or
	// "ruff check ."). Empty means skip the analyze phase.
	AnalyzeCmd string

	// CompileCmd is the compile/build command (e.g. "go build ./..."). Empty
	// means skip the compile phase.
	CompileCmd string

	// Timeout caps a single gate run. Zero means use 10 minutes (parity
	// with BUILD_GATE_TIMEOUT default).
	Timeout time.Duration

	// Runner overrides command execution. Tests stub this to avoid spawning
	// real subprocesses.
	Runner CommandRunner
}

// CompletionGate runs the test command after the tester stage. Pass means
// downstream finalize hooks may proceed; failure routes the outer loop back
// to coder.
type CompletionGate struct {
	TestCmd string
	Timeout time.Duration

	// PassOnPreexisting mirrors TEST_BASELINE_PASS_ON_PREEXISTING — when
	// true, a non-zero exit whose failures all match the recorded baseline
	// is treated as pass.
	PassOnPreexisting bool

	// IsPreexistingFailure is the baseline-comparison hook. Tests stub it.
	// nil means no baseline comparison.
	IsPreexistingFailure func(stdout []byte, exitCode int) bool

	Runner CommandRunner
}

// CommandRunner abstracts os/exec for gate invocation. Tests substitute a
// recorded fake; the production wiring uses ExecRunner.
type CommandRunner interface {
	// Run executes cmd under ctx with the given timeout, returning combined
	// stdout/stderr and the exit code (0 on success).
	Run(ctx context.Context, cmd string, timeout time.Duration) (output []byte, exitCode int, err error)
}

// ExecRunner is the production CommandRunner; runs the command via
// `bash -c` so we get shell parsing for free.
type ExecRunner struct{}

// Run implements CommandRunner using exec.CommandContext.
func (ExecRunner) Run(ctx context.Context, cmd string, timeout time.Duration) ([]byte, int, error) {
	if cmd == "" {
		return nil, 0, nil
	}
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	c := exec.CommandContext(ctx, "bash", "-c", cmd)
	var buf bytes.Buffer
	c.Stdout = &buf
	c.Stderr = &buf
	err := c.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return buf.Bytes(), -1, fmt.Errorf("%w: %s", ErrGateTimeout, cmd)
	}
	exitCode := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			exitCode = ee.ExitCode()
		} else {
			return buf.Bytes(), -1, err
		}
	}
	return buf.Bytes(), exitCode, nil
}

// Run executes the build gate phases in sequence. Returns VerdictPass when
// every configured phase exits 0, VerdictFail otherwise. The error return
// is for *infrastructure* failures (gate timeout, runner crash) — a
// command exiting non-zero is a normal "fail" outcome, not an error.
//
// attempt is the build-gate attempt counter (0-indexed). Currently unused
// inside the gate but reserved for future per-attempt timeout scaling.
func (g *BuildGate) Run(ctx context.Context, attempt int) (string, error) {
	_ = attempt
	if g == nil {
		return proto.VerdictPass, nil
	}
	timeout := g.Timeout
	if timeout == 0 {
		timeout = 10 * time.Minute
	}
	runner := g.Runner
	if runner == nil {
		runner = ExecRunner{}
	}
	if g.AnalyzeCmd != "" {
		_, exit, err := runner.Run(ctx, g.AnalyzeCmd, timeout)
		if err != nil {
			return proto.VerdictFail, err
		}
		if exit != 0 {
			return proto.VerdictFail, nil
		}
	}
	if g.CompileCmd != "" {
		_, exit, err := runner.Run(ctx, g.CompileCmd, timeout)
		if err != nil {
			return proto.VerdictFail, err
		}
		if exit != 0 {
			return proto.VerdictFail, nil
		}
	}
	return proto.VerdictPass, nil
}

// Run executes the test command. Returns VerdictPass on success or when
// PassOnPreexisting is set and IsPreexistingFailure agrees that every
// failure was already in the baseline.
func (g *CompletionGate) Run(ctx context.Context) (string, error) {
	if g == nil || g.TestCmd == "" {
		return proto.VerdictPass, nil
	}
	timeout := g.Timeout
	if timeout == 0 {
		timeout = 10 * time.Minute
	}
	runner := g.Runner
	if runner == nil {
		runner = ExecRunner{}
	}
	out, exit, err := runner.Run(ctx, g.TestCmd, timeout)
	if err != nil {
		return proto.VerdictFail, err
	}
	if exit == 0 {
		return proto.VerdictPass, nil
	}
	if g.PassOnPreexisting && g.IsPreexistingFailure != nil {
		if g.IsPreexistingFailure(out, exit) {
			return proto.VerdictPass, nil
		}
	}
	return proto.VerdictFail, nil
}
