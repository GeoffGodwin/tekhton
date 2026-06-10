package runner

import (
	"fmt"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/claude"
	"github.com/geoffgodwin/tekhton/internal/provider/codex"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// ResolveProvider returns the Provider that should run for the given stage.
// Resolution order:
//  1. PROVIDER_<STAGE>= env var (stage-specific override, uppercased)
//  2. PROVIDER= env var (global spec)
//  3. Default "codex,claude" (cost-ranked: cheapest first)
//
// A comma-separated spec builds a Chain via NewChain; TEKHTON_REQUIRE_TIER
// is applied to the chain when set. A single-name spec returns that provider
// directly without a chain wrapper.
func ResolveProvider(stage string) (provider.Provider, error) {
	envKey := "PROVIDER_" + strings.ToUpper(stage)
	spec := os.Getenv(envKey)
	if spec == "" {
		spec = os.Getenv("PROVIDER")
	}
	if spec == "" {
		spec = "codex,claude" // cost-ranked default: cheapest first
	}
	names := splitCSV(spec)
	if len(names) == 0 {
		return nil, fmt.Errorf("provider: empty spec for stage %q", stage)
	}
	providers := make([]provider.Provider, 0, len(names))
	for _, name := range names {
		p, err := constructProvider(name)
		if err != nil {
			return nil, err
		}
		providers = append(providers, p)
	}
	if len(providers) == 1 {
		return providers[0], nil
	}
	chain := NewChain(providers...)
	if rt := os.Getenv("TEKHTON_REQUIRE_TIER"); rt != "" {
		chain.RequiredTier = rt
	}
	return chain, nil
}

func constructProvider(name string) (provider.Provider, error) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "claude":
		return claude.New(supervisor.New(nil, nil)), nil
	case "codex":
		return codex.New()
	default:
		return nil, fmt.Errorf("unknown provider %q", name)
	}
}

func splitCSV(s string) []string {
	parts := strings.Split(s, ",")
	out := parts[:0]
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
