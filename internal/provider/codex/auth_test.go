package codex

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// makeRequest is a helper to build a minimal provider.Request with the given
// ProviderSpecific values.
func makeRequest(ps map[string]string) *provider.Request {
	return &provider.Request{ProviderSpecific: ps}
}

// TestResolveAuth_ExplicitAPIKey verifies that when codex.api_key is set in
// ProviderSpecific, resolveAuth returns a CODEX_API_KEY env override and the
// "api" tier regardless of OAuth presence or process env.
func TestResolveAuth_ExplicitAPIKey(t *testing.T) {
	// Blank out CODEX_API_KEY so we know the override comes from the request.
	t.Setenv("CODEX_API_KEY", "")

	req := makeRequest(map[string]string{
		"codex.api_key": "sk-test-explicit",
	})
	envOverrides, tier, err := resolveAuth(req)
	if err != nil {
		t.Fatalf("resolveAuth: unexpected error: %v", err)
	}
	if tier != "api" {
		t.Errorf("tier = %q, want %q", tier, "api")
	}
	if len(envOverrides) != 1 || envOverrides[0] != "CODEX_API_KEY=sk-test-explicit" {
		t.Errorf("envOverrides = %v, want [CODEX_API_KEY=sk-test-explicit]", envOverrides)
	}
}

// TestResolveAuth_StoredOAuth verifies that when ~/.codex/auth.json exists and
// no explicit API key is supplied, resolveAuth returns tier "subscription" with
// nil envOverrides (codex reads OAuth from the file itself).
func TestResolveAuth_StoredOAuth(t *testing.T) {
	// Blank CODEX_API_KEY so the env-var path isn't hit.
	t.Setenv("CODEX_API_KEY", "")

	// Create a fake auth.json in a temp home directory.
	fakeHome := t.TempDir()
	authDir := filepath.Join(fakeHome, ".codex")
	if err := os.MkdirAll(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	authFile := filepath.Join(authDir, "auth.json")
	if err := os.WriteFile(authFile, []byte(`{"access_token":"tok"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", fakeHome)

	req := makeRequest(nil)
	envOverrides, tier, err := resolveAuth(req)
	if err != nil {
		t.Fatalf("resolveAuth: unexpected error: %v", err)
	}
	if tier != "subscription" {
		t.Errorf("tier = %q, want %q", tier, "subscription")
	}
	if len(envOverrides) != 0 {
		t.Errorf("envOverrides = %v, want nil (OAuth needs no env override)", envOverrides)
	}
}

// TestResolveAuth_EnvAPIKey verifies that when CODEX_API_KEY is set in the
// process environment and no explicit key or OAuth file is present, resolveAuth
// returns tier "api" with nil envOverrides (key is already in process env).
func TestResolveAuth_EnvAPIKey(t *testing.T) {
	t.Setenv("CODEX_API_KEY", "sk-env-key")

	// Point HOME to a temp dir that has no .codex/auth.json.
	t.Setenv("HOME", t.TempDir())

	req := makeRequest(nil)
	envOverrides, tier, err := resolveAuth(req)
	if err != nil {
		t.Fatalf("resolveAuth: unexpected error: %v", err)
	}
	if tier != "api" {
		t.Errorf("tier = %q, want %q", tier, "api")
	}
	// No override needed: key is already in process environment.
	if len(envOverrides) != 0 {
		t.Errorf("envOverrides = %v, want nil (env key needs no override)", envOverrides)
	}
}

// TestResolveAuth_NoAuthSource verifies that resolveAuth returns a non-nil
// error when no auth source is available (no explicit key, no OAuth file, no
// CODEX_API_KEY env var).
func TestResolveAuth_NoAuthSource(t *testing.T) {
	t.Setenv("CODEX_API_KEY", "")
	// Point HOME to a temp dir with no .codex/auth.json.
	t.Setenv("HOME", t.TempDir())

	req := makeRequest(nil)
	_, _, err := resolveAuth(req)
	if err == nil {
		t.Fatal("resolveAuth: expected error when no auth source is available, got nil")
	}
}

// TestResolveAuth_ExplicitKeyPrecedesOAuth verifies that an explicit
// codex.api_key overrides stored OAuth even when ~/.codex/auth.json exists.
// This is the operator override path: explicit key forces API-tier billing
// even when ChatGPT OAuth is configured.
func TestResolveAuth_ExplicitKeyPrecedesOAuth(t *testing.T) {
	t.Setenv("CODEX_API_KEY", "")

	fakeHome := t.TempDir()
	authDir := filepath.Join(fakeHome, ".codex")
	if err := os.MkdirAll(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(authDir, "auth.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", fakeHome)

	req := makeRequest(map[string]string{"codex.api_key": "sk-override"})
	envOverrides, tier, err := resolveAuth(req)
	if err != nil {
		t.Fatalf("resolveAuth: unexpected error: %v", err)
	}
	if tier != "api" {
		t.Errorf("tier = %q, want %q (explicit key must take precedence)", tier, "api")
	}
	if len(envOverrides) == 0 || envOverrides[0] != "CODEX_API_KEY=sk-override" {
		t.Errorf("envOverrides = %v, want [CODEX_API_KEY=sk-override]", envOverrides)
	}
}
