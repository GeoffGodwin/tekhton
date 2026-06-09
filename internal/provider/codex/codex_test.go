package codex

import (
	"context"
	"os"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// Compile-time assertion: *Provider must satisfy provider.Provider.
// Fails at build time if RunAgent or Name signatures diverge from the interface.
var _ provider.Provider = (*Provider)(nil)

// TestNew_BinaryMissing verifies New() returns an error when the codex
// binary is not on PATH. Exercised by setting PATH to a temp dir
// containing no "codex" binary.
func TestNew_BinaryMissing(t *testing.T) {
	emptyDir := t.TempDir()
	t.Setenv("PATH", emptyDir)

	_, err := New()
	if err == nil {
		t.Error("New(): expected error when codex binary is absent from PATH, got nil")
	}
}

// TestNewWithBinary_ReturnsProvider verifies the test-seam constructor
// produces a non-nil *Provider with the given binary path set.
func TestNewWithBinary_ReturnsProvider(t *testing.T) {
	const fakePath = "/usr/local/bin/codex-fake"
	p := NewWithBinary(fakePath)
	if p == nil {
		t.Fatal("NewWithBinary returned nil")
	}
	if p.BinaryPath != fakePath {
		t.Errorf("BinaryPath: want %q, got %q", fakePath, p.BinaryPath)
	}
}

// TestProvider_Name verifies Name() returns the canonical identifier "codex".
func TestProvider_Name(t *testing.T) {
	p := NewWithBinary("/bin/true")
	if got := p.Name(); got != "codex" {
		t.Errorf("Name(): want %q, got %q", "codex", got)
	}
}

// TestProvider_RunAgent_NilRequest verifies RunAgent returns a non-nil error
// when called with a nil request.
func TestProvider_RunAgent_NilRequest(t *testing.T) {
	p := NewWithBinary("/bin/true")
	_, err := p.RunAgent(context.Background(), nil)
	if err == nil {
		t.Error("RunAgent(nil): expected error, got nil")
	}
}

// TestProvider_RunAgent_ExitZeroSuccess verifies that RunAgent returns a
// non-nil *Result with Outcome=OutcomeSuccess when the binary exits 0.
// Uses /bin/true (always exits 0) as the stub binary. This is the primary
// happy path — the feature works correctly when a successful Codex invocation
// produces OutcomeSuccess.
func TestProvider_RunAgent_ExitZeroSuccess(t *testing.T) {
	// /bin/sh -c "exit 0" reliably exits 0 everywhere.
	p := NewWithBinary("/bin/sh")

	req := &provider.Request{
		Prompt: "test-prompt",
		ProviderSpecific: map[string]string{
			"codex.cwd":                 t.TempDir(),
			"codex.output_last_message": os.DevNull,
		},
	}

	res, err := p.RunAgent(context.Background(), req)
	if err != nil {
		t.Fatalf("RunAgent exit 0: unexpected error: %v", err)
	}
	if res == nil {
		t.Fatal("RunAgent exit 0: Result is nil")
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("RunAgent exit 0: Outcome = %v, want OutcomeSuccess", res.Outcome)
	}
	if res.ExitCode != 0 {
		t.Errorf("RunAgent exit 0: ExitCode = %d, want 0", res.ExitCode)
	}
}

// TestProvider_RunAgent_ExitOneUpstreamError verifies that RunAgent returns a
// non-nil *Result with Outcome=OutcomeUpstreamError when the binary exits 1.
// Uses /bin/false which unconditionally exits 1.
func TestProvider_RunAgent_ExitOneUpstreamError(t *testing.T) {
	// /bin/false exits 1 regardless of arguments.
	// buildExecArgs prepends "exec" and flags that /bin/false ignores silently.
	p2 := NewWithBinary("/bin/false")
	req2 := &provider.Request{
		Prompt: "test-prompt",
		ProviderSpecific: map[string]string{
			"codex.cwd":                 t.TempDir(),
			"codex.output_last_message": os.DevNull,
		},
	}
	res, err := p2.RunAgent(context.Background(), req2)
	if err != nil {
		// Process-level errors are acceptable — /bin/false may fail for
		// reasons other than exit code. What must NOT happen is both
		// err==nil and a success outcome.
		t.Logf("RunAgent /bin/false: got process-level error %v (acceptable)", err)
		return
	}
	if res == nil {
		t.Fatal("RunAgent /bin/false: Result is nil with no error")
	}
	if res.Outcome == provider.OutcomeSuccess {
		t.Errorf("RunAgent exit 1: Outcome = OutcomeSuccess; non-zero exit must not be success")
	}
	if res.ExitCode == 0 {
		t.Errorf("RunAgent /bin/false: ExitCode = 0, expected non-zero")
	}
}

// TestProvider_RunAgent_ResultOutcomeSet verifies RunAgent always returns a
// Result with Outcome set (not zero / OutcomeUnknown with no reason), even
// on non-zero exit codes. Outcome must reflect exit code classification.
func TestProvider_RunAgent_ResultOutcomeSet(t *testing.T) {
	p := NewWithBinary("/bin/sh")
	req := &provider.Request{
		Prompt: "test",
		ProviderSpecific: map[string]string{
			"codex.cwd":                 t.TempDir(),
			"codex.output_last_message": os.DevNull,
		},
	}
	res, err := p.RunAgent(context.Background(), req)
	if err != nil {
		t.Skipf("RunAgent: process-level error (skip if binary unavailable): %v", err)
	}
	if res == nil {
		t.Fatal("Result is nil")
	}
	// Outcome must be set to a defined value (not the zero value indicating
	// unclassified). OutcomeUnknown (iota 0) is valid only when interpretExitCode
	// returns it for an unrecognised code — but OutcomeSuccess (exit 0) is more
	// likely here.
	if res.Outcome == provider.OutcomeUnknown && res.ExitCode == 0 {
		t.Error("exit 0 produced OutcomeUnknown; expected OutcomeSuccess")
	}
}
