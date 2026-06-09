package codex_test

import (
	"context"
	"os"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/codex"
)

// TestNew_BinaryMissing verifies that New returns an error when codex is not
// on PATH. Achieved by running the sub-test with an empty PATH.
func TestNew_BinaryMissing(t *testing.T) {
	t.Setenv("PATH", "")
	_, err := codex.New()
	if err == nil {
		t.Fatal("expected error when codex binary is missing, got nil")
	}
}

// TestNewWithBinary_Name ensures Name() returns "codex".
func TestNewWithBinary_Name(t *testing.T) {
	p := codex.NewWithBinary("/bin/echo")
	if got := p.Name(); got != "codex" {
		t.Fatalf("Name() = %q, want %q", got, "codex")
	}
}

// TestProvider_ImplementsInterface is a compile-time check that surfaced at
// test time via a nil-pointer cast.
func TestProvider_ImplementsInterface(t *testing.T) {
	var _ provider.Provider = (*codex.Provider)(nil)
}

// TestRunAgent_NilRequest verifies that a nil *provider.Request returns an
// error rather than panicking.
func TestRunAgent_NilRequest(t *testing.T) {
	p := codex.NewWithBinary("/bin/echo")
	_, err := p.RunAgent(context.Background(), nil)
	if err == nil {
		t.Fatal("expected error for nil request, got nil")
	}
}

// TestRunAgent_StubBinary verifies that RunAgent returns a non-nil Result
// with Outcome and ExitCode set when the stub binary exits 0.
func TestRunAgent_StubBinary(t *testing.T) {
	// /bin/echo exits 0 and ignores stdin — good enough for a scaffold test.
	echo, err := os.Executable()
	if err != nil {
		t.Skip("cannot determine test binary path")
	}
	_ = echo

	p := codex.NewWithBinary("/bin/echo")
	req := &provider.Request{
		Prompt: "hello",
		ProviderSpecific: map[string]string{
			// Provide a fixed output path so we don't leave tempfiles behind.
			"codex.output_last_message": t.TempDir() + "/last.md",
		},
	}
	res, err := p.RunAgent(context.Background(), req)
	if err != nil {
		t.Fatalf("RunAgent returned unexpected error: %v", err)
	}
	if res == nil {
		t.Fatal("RunAgent returned nil result")
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome = %v, want OutcomeSuccess", res.Outcome)
	}
	if res.ExitCode != 0 {
		t.Errorf("ExitCode = %d, want 0", res.ExitCode)
	}
}
