package codex

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestRunCodex_ExitZero verifies a process that exits 0 returns
// (stdout, stderr, 0, nil) — the happy path.
func TestRunCodex_ExitZero(t *testing.T) {
	_, _, code, err := runCodex(context.Background(), "/bin/sh",
		[]string{"-c", "printf 'hello'"},
		"ignored-prompt",
		0,
	)
	if err != nil {
		t.Fatalf("runCodex exit 0: unexpected process-level error: %v", err)
	}
	if code != 0 {
		t.Errorf("runCodex exit 0: want exitCode 0, got %d", code)
	}
}

// TestRunCodex_StdoutCaptured verifies that subprocess stdout is captured
// into the returned stdout bytes.
func TestRunCodex_StdoutCaptured(t *testing.T) {
	stdout, _, _, err := runCodex(context.Background(), "/bin/sh",
		[]string{"-c", "printf 'captured-output'"},
		"",
		0,
	)
	if err != nil {
		t.Fatalf("runCodex: %v", err)
	}
	if !strings.Contains(string(stdout), "captured-output") {
		t.Errorf("stdout not captured: got %q", string(stdout))
	}
}

// TestRunCodex_ExitNonzeroNotError verifies that a non-zero exit code is
// returned as exitCode and err is nil — a non-zero exit is an outcome, not
// a process-level failure. This is the same contract as exec.CommandContext.
func TestRunCodex_ExitNonzeroNotError(t *testing.T) {
	_, _, code, err := runCodex(context.Background(), "/bin/sh",
		[]string{"-c", "exit 42"},
		"",
		0,
	)
	if err != nil {
		t.Fatalf("runCodex exit 42: got process-level error %v; non-zero exit must NOT be an error", err)
	}
	if code != 42 {
		t.Errorf("runCodex exit 42: want exitCode 42, got %d", code)
	}
}

// TestRunCodex_StdinPromptPiped verifies the prompt is piped to the
// subprocess via stdin. Uses `cat` which echoes stdin to stdout.
func TestRunCodex_StdinPromptPiped(t *testing.T) {
	const prompt = "test-prompt-piped-via-stdin"
	stdout, _, code, err := runCodex(context.Background(), "/bin/sh",
		[]string{"-c", "cat"},
		prompt,
		0,
	)
	if err != nil {
		t.Fatalf("runCodex stdin test: %v", err)
	}
	if code != 0 {
		t.Errorf("runCodex stdin test: exit code %d", code)
	}
	if !strings.Contains(string(stdout), prompt) {
		t.Errorf("prompt not found in stdout: want %q, got %q", prompt, string(stdout))
	}
}

// TestRunCodex_ContextCancel verifies that cancelling the context terminates
// the subprocess. A process blocked on `sleep` must not run past the cancel.
func TestRunCodex_ContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	var exitCode int
	var runErr error

	go func() {
		defer close(done)
		_, _, exitCode, runErr = runCodex(ctx, "/bin/sh",
			[]string{"-c", "sleep 30"},
			"",
			0,
		)
	}()

	// Give the process time to start, then cancel.
	time.Sleep(100 * time.Millisecond)
	cancel()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("runCodex did not return after context cancel within 10s")
	}

	// After cancel, runCodex must return promptly. The exit code should be
	// non-zero (SIGTERM/SIGKILL). runErr may be nil (the process ran but was
	// killed) or an error (context cancelled propagated). What must NOT happen
	// is exit code 0 (the sleep completed normally — indicating cancel didn't work).
	if runErr == nil && exitCode == 0 {
		t.Error("context cancel had no effect: process exited 0 (sleep completed normally)")
	}
}

// TestRunCodex_TimeoutTerminates verifies the timeout parameter causes the
// subprocess to be terminated when the deadline is exceeded.
func TestRunCodex_TimeoutTerminates(t *testing.T) {
	start := time.Now()
	_, _, _, _ = runCodex(context.Background(), "/bin/sh",
		[]string{"-c", "sleep 30"},
		"",
		200*time.Millisecond,
	)
	elapsed := time.Since(start)

	// The subprocess should have been terminated well before 30s. Allow up to
	// 5s total (WaitDelay + OS scheduling) but enforce it ends before 30s.
	if elapsed >= 30*time.Second {
		t.Errorf("timeout had no effect: runCodex ran for %v (expected < 30s)", elapsed)
	}
	if elapsed >= 5*time.Second {
		t.Logf("warning: runCodex with 200ms timeout took %v (expected < 5s)", elapsed)
	}
}

// TestRunCodex_BinaryNotFound verifies that a missing binary produces a
// process-level error (not just a non-zero exit code).
func TestRunCodex_BinaryNotFound(t *testing.T) {
	_, _, _, err := runCodex(context.Background(),
		"/nonexistent/binary/that/does/not/exist",
		[]string{},
		"",
		0,
	)
	if err == nil {
		t.Error("missing binary: want process-level error, got nil")
	}
}
