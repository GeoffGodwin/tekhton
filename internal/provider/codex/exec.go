package codex

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// runCodex invokes the codex binary with the given argv, feeds the prompt
// via stdin, and returns captured stdout/stderr bytes and the process exit code.
//
// timeout (0 = no timeout) applies to the whole invocation. Context
// cancellation propagates via exec.CommandContext — codex receives SIGTERM on
// cancel, with WaitDelay enforcing SIGKILL escalation after 5s.
//
// envExtra, when non-nil, is appended to the process environment (os.Environ())
// so subprocess sees the merged env. Used by m11 auth wiring to inject
// CODEX_API_KEY without mutating the process environment.
//
// The returned error is non-nil ONLY for process-level failures (binary
// missing, fork failure, permission denied). A non-zero exit code is NOT an
// error — the caller inspects exitCode to determine outcome.
func runCodex(parent context.Context, bin string, args []string, prompt string, timeout time.Duration, envExtra []string) (stdout, stderr []byte, exitCode int, err error) {
	ctx := parent
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(parent, timeout)
		defer cancel()
	}

	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Stdin = strings.NewReader(prompt)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	if len(envExtra) > 0 {
		cmd.Env = append(os.Environ(), envExtra...)
	}

	// Give codex 5s to respond to SIGTERM before SIGKILL escalation.
	cmd.WaitDelay = 5 * time.Second

	if runErr := cmd.Run(); runErr != nil {
		if exitErr, ok := runErr.(*exec.ExitError); ok {
			// Non-zero exit — not a process-level error.
			return outBuf.Bytes(), errBuf.Bytes(), exitErr.ExitCode(), nil
		}
		// Process-level failure.
		return outBuf.Bytes(), errBuf.Bytes(), -1, fmt.Errorf("exec: %w", runErr)
	}
	return outBuf.Bytes(), errBuf.Bytes(), 0, nil
}
