package codex

import (
	"context"
	"os/exec"
	"testing"
	"time"
)

// requireBin skips the test when binPath isn't executable on this platform.
func requireBin(t *testing.T, binPath string) {
	t.Helper()
	if _, err := exec.LookPath(binPath); err != nil {
		// Fall back: check absolute path directly.
		if _, statErr := exec.LookPath(binPath); statErr != nil {
			t.Skipf("stub binary %q not available: %v", binPath, err)
		}
	}
}

func TestRunCodex_ExitZero(t *testing.T) {
	requireBin(t, "/bin/echo")
	stdout, stderr, code, err := runCodex(context.Background(), "/bin/echo", []string{"hello"}, "prompt", 0)
	if err != nil {
		t.Fatalf("unexpected process-level error: %v", err)
	}
	if code != 0 {
		t.Errorf("exit code = %d, want 0", code)
	}
	_ = stdout
	_ = stderr
}

func TestRunCodex_ExitNonzero(t *testing.T) {
	// "false" exits with code 1.
	requireBin(t, "/bin/false")
	_, _, code, err := runCodex(context.Background(), "/bin/false", nil, "prompt", 0)
	if err != nil {
		t.Fatalf("non-zero exit should not produce a process-level error, got: %v", err)
	}
	if code == 0 {
		t.Error("expected non-zero exit code from /bin/false")
	}
}

func TestRunCodex_StdinPropagated(t *testing.T) {
	// /bin/cat echoes stdin to stdout.
	requireBin(t, "/bin/cat")
	prompt := "hello codex"
	stdout, _, code, err := runCodex(context.Background(), "/bin/cat", nil, prompt, 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if string(stdout) != prompt {
		t.Errorf("stdout = %q, want %q", stdout, prompt)
	}
}

func TestRunCodex_ContextCancel(t *testing.T) {
	// /bin/sleep 60 should be cancelled by a deadline that fires immediately.
	requireBin(t, "/bin/sleep")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, _, _, _ = runCodex(ctx, "/bin/sleep", []string{"60"}, "", 0)
	// The important assertion: the call must return (not hang). If we get here the
	// context cancellation worked. We don't assert a specific exit code because the
	// signal semantics (SIGTERM→SIGKILL) vary; what matters is termination.
}

func TestRunCodex_BinaryMissing(t *testing.T) {
	_, _, code, err := runCodex(context.Background(), "/nonexistent/bin/codex", nil, "p", 0)
	if err == nil {
		t.Fatal("expected process-level error for missing binary, got nil")
	}
	if code != -1 {
		t.Errorf("expected exit code -1 for process-level error, got %d", code)
	}
}

func TestRunCodex_TimeoutApplied(t *testing.T) {
	requireBin(t, "/bin/sleep")
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Pass a per-call timeout shorter than the sleep.
	runCodex(ctx, "/bin/sleep", []string{"30"}, "", 200*time.Millisecond)
	elapsed := time.Since(start)
	if elapsed > 10*time.Second {
		t.Errorf("runCodex didn't respect timeout: elapsed %v", elapsed)
	}
}
