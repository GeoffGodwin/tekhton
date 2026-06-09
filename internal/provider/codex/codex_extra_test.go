package codex_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/codex"
)

// TestNew_BinaryPresent verifies that New() succeeds when a fake "codex"
// binary is placed on PATH. This is the happy-path constructor coverage.
func TestNew_BinaryPresent(t *testing.T) {
	dir := t.TempDir()
	fakeBin := filepath.Join(dir, "codex")
	if err := os.WriteFile(fakeBin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	p, err := codex.New()
	if err != nil {
		t.Fatalf("New() returned unexpected error: %v", err)
	}
	if p == nil {
		t.Fatal("New() returned nil provider")
	}
	if got := p.Name(); got != "codex" {
		t.Errorf("Name() = %q, want %q", got, "codex")
	}
}

// TestRunAgent_NonZeroExit verifies that RunAgent returns a non-error Result
// with OutcomeUpstreamError and ExitCode=1 when the binary exits non-zero.
// /bin/false is the stub: exits 1, no output. This exercises the
// buildExecArgs → runCodex → interpretExitCode integration path.
func TestRunAgent_NonZeroExit(t *testing.T) {
	if _, err := os.Stat("/bin/false"); err != nil {
		t.Skip("/bin/false not available")
	}

	p := codex.NewWithBinary("/bin/false")
	req := &provider.Request{
		Prompt: "hello",
		ProviderSpecific: map[string]string{
			"codex.output_last_message": t.TempDir() + "/last.md",
		},
	}
	res, err := p.RunAgent(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error for non-zero exit: %v", err)
	}
	if res == nil {
		t.Fatal("expected non-nil Result for non-zero exit")
	}
	if res.Outcome != provider.OutcomeUpstreamError {
		t.Errorf("Outcome = %v, want OutcomeUpstreamError", res.Outcome)
	}
	if res.ExitCode != 1 {
		t.Errorf("ExitCode = %d, want 1", res.ExitCode)
	}
}

// TestRunAgent_ProcessLevelError verifies that RunAgent returns an error (not a
// Result) when the binary cannot be launched at the OS level — for example
// because the path does not exist. Process-level failures must surface as
// errors, not as Results with OutcomeUnknown.
func TestRunAgent_ProcessLevelError(t *testing.T) {
	p := codex.NewWithBinary("/nonexistent/bin/codex")
	req := &provider.Request{
		Prompt: "hello",
		ProviderSpecific: map[string]string{
			"codex.output_last_message": t.TempDir() + "/last.md",
		},
	}
	_, err := p.RunAgent(context.Background(), req)
	if err == nil {
		t.Fatal("expected error when binary path does not exist, got nil")
	}
}
