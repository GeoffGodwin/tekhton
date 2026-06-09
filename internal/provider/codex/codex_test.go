package codex_test

import (
	"context"
	"os"
	"path/filepath"
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

// TestProvider_Tier_SubscriptionOAuth asserts Tier() returns "subscription"
// when ~/.codex/auth.json exists.
func TestProvider_Tier_SubscriptionOAuth(t *testing.T) {
	// Clear the API key env var so only OAuth path applies.
	t.Setenv("CODEX_API_KEY", "")

	fakeHome := t.TempDir()
	authDir := filepath.Join(fakeHome, ".codex")
	if err := os.MkdirAll(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(authDir, "auth.json"), []byte(`{"access_token":"tok"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", fakeHome)

	p := codex.NewWithBinary("/bin/echo")
	if got := p.Tier(); got != provider.TierSubscription {
		t.Errorf("Tier() with auth.json: want %q, got %q", provider.TierSubscription, got)
	}
}

// TestProvider_Tier_APIKey asserts Tier() returns "api" when CODEX_API_KEY
// is set and no OAuth file is present.
func TestProvider_Tier_APIKey(t *testing.T) {
	t.Setenv("CODEX_API_KEY", "sk-test-api-key")
	// Point HOME to a temp dir with no .codex/auth.json.
	t.Setenv("HOME", t.TempDir())

	p := codex.NewWithBinary("/bin/echo")
	if got := p.Tier(); got != provider.TierAPI {
		t.Errorf("Tier() with CODEX_API_KEY: want %q, got %q", provider.TierAPI, got)
	}
}

// TestProvider_Tier_Unknown asserts Tier() returns "unknown" when neither
// OAuth file nor CODEX_API_KEY is available.
func TestProvider_Tier_Unknown(t *testing.T) {
	t.Setenv("CODEX_API_KEY", "")
	// Point HOME to a temp dir with no .codex/auth.json.
	t.Setenv("HOME", t.TempDir())

	p := codex.NewWithBinary("/bin/echo")
	if got := p.Tier(); got != provider.TierUnknown {
		t.Errorf("Tier() with no auth: want %q, got %q", provider.TierUnknown, got)
	}
}

// TestProvider_Tier_OAuthPrecedesEnvKey asserts that OAuth takes precedence
// over CODEX_API_KEY when both are present (subscription is cheaper).
func TestProvider_Tier_OAuthPrecedesEnvKey(t *testing.T) {
	t.Setenv("CODEX_API_KEY", "sk-env-key")

	fakeHome := t.TempDir()
	authDir := filepath.Join(fakeHome, ".codex")
	if err := os.MkdirAll(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(authDir, "auth.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", fakeHome)

	p := codex.NewWithBinary("/bin/echo")
	if got := p.Tier(); got != provider.TierSubscription {
		t.Errorf("Tier() with OAuth+CODEX_API_KEY: want %q (OAuth wins), got %q",
			provider.TierSubscription, got)
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
