// Package codex — Auth resolution for Codex provider.
// V5 m11 — three-tier precedence: per-request key > stored OAuth > env key.
package codex

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// resolveAuth determines which auth method to use for a Codex invocation and
// returns the cost tier the resolved auth represents.
//
// Precedence (highest to lowest):
//
//  1. req.ProviderSpecific["codex.api_key"] — explicit per-request override → tier "api" (paid)
//  2. stored OAuth at ~/.codex/auth.json   — ChatGPT subscription           → tier "subscription" (free within quota)
//  3. CODEX_API_KEY env var                — process-level API key           → tier "api" (paid)
//
// Subscription OAuth precedes the env-var API key so the default path stays in
// the free tier whenever ChatGPT OAuth is present. Operators who want to force
// API-key usage do so explicitly via ProviderSpecific["codex.api_key"] OR by
// removing ~/.codex/auth.json.
//
// Returns:
//   - envOverrides: env slice to pass via cmd.Env (nil when using OAuth or process env)
//   - tier: "subscription" | "api"
//   - err: non-nil when no auth source is available
func resolveAuth(req *provider.Request) (envOverrides []string, tier string, err error) {
	if req != nil {
		if key := req.ProviderSpecific["codex.api_key"]; key != "" {
			return []string{"CODEX_API_KEY=" + key}, "api", nil
		}
	}
	if authPath := storedAuthPath(); fileExists(authPath) {
		return nil, "subscription", nil
	}
	if envKey := os.Getenv("CODEX_API_KEY"); envKey != "" {
		return nil, "api", nil // already in process env, no override needed
	}
	return nil, "", errors.New(
		"codex auth: no stored OAuth at ~/.codex/auth.json and no CODEX_API_KEY" +
			" — run `codex login` for subscription (free within quota)" +
			" or set CODEX_API_KEY for API-tier (paid)",
	)
}

func storedAuthPath() string {
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".codex", "auth.json")
	}
	return ""
}

func fileExists(p string) bool {
	if p == "" {
		return false
	}
	_, err := os.Stat(p)
	return err == nil
}
