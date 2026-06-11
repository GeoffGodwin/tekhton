package runner_test

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/runner"
)

// TestResolveProvider_SingleClaude asserts that PROVIDER=claude returns a
// single claude.Provider (not a chain). No codex binary required.
func TestResolveProvider_SingleClaude(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	t.Setenv("PROVIDER_CODER", "")

	p, err := runner.ResolveProvider("coder")
	if err != nil {
		t.Fatalf("ResolveProvider: %v", err)
	}
	if p.Name() != "claude" {
		t.Errorf("Name: want claude, got %q", p.Name())
	}
	// Single provider, not a chain.
	if strings.HasPrefix(p.Name(), "chain(") {
		t.Errorf("expected single provider, got chain: %s", p.Name())
	}
}

// TestResolveProvider_StageOverrideClaude asserts that PROVIDER_CODER=claude
// takes precedence over PROVIDER=codex. No codex binary required.
func TestResolveProvider_StageOverrideClaude(t *testing.T) {
	t.Setenv("PROVIDER", "codex")
	t.Setenv("PROVIDER_CODER", "claude")

	p, err := runner.ResolveProvider("coder")
	if err != nil {
		t.Fatalf("ResolveProvider: %v", err)
	}
	if p.Name() != "claude" {
		t.Errorf("Name: want claude (PROVIDER_CODER override), got %q", p.Name())
	}
}

// TestResolveProvider_MultipleProviders_CreatesChain asserts that a
// comma-separated PROVIDER spec builds a Chain. Uses "claude,claude" to
// avoid requiring a codex binary.
func TestResolveProvider_MultipleProviders_CreatesChain(t *testing.T) {
	t.Setenv("PROVIDER", "claude,claude")
	t.Setenv("PROVIDER_CODER", "")

	p, err := runner.ResolveProvider("coder")
	if err != nil {
		t.Fatalf("ResolveProvider: %v", err)
	}
	if !strings.HasPrefix(p.Name(), "chain(") {
		t.Errorf("Name: want chain(...), got %q", p.Name())
	}
}

// TestResolveProvider_ChainWithRequiredTier asserts that TEKHTON_REQUIRE_TIER
// is wired onto the chain's RequiredTier field when set.
func TestResolveProvider_ChainWithRequiredTier(t *testing.T) {
	t.Setenv("PROVIDER", "claude,claude")
	t.Setenv("PROVIDER_CODER", "")
	t.Setenv("TEKHTON_REQUIRE_TIER", "subscription")

	p, err := runner.ResolveProvider("coder")
	if err != nil {
		t.Fatalf("ResolveProvider: %v", err)
	}
	c, ok := p.(*runner.Chain)
	if !ok {
		t.Fatalf("want *runner.Chain, got %T", p)
	}
	if c.RequiredTier != "subscription" {
		t.Errorf("RequiredTier: want subscription, got %q", c.RequiredTier)
	}
}

// TestResolveProvider_UnknownProvider asserts that an unrecognised provider
// name returns an error.
func TestResolveProvider_UnknownProvider(t *testing.T) {
	t.Setenv("PROVIDER", "grok")
	t.Setenv("PROVIDER_CODER", "")

	_, err := runner.ResolveProvider("coder")
	if err == nil {
		t.Fatal("expected error for unknown provider, got nil")
	}
}

// TestResolveProvider_SingleQwenLocal asserts that PROVIDER=qwen-local returns
// a qwen-local provider. Skipped when codex is not on PATH because New() wraps
// codex.New() which requires the binary.
func TestResolveProvider_SingleQwenLocal(t *testing.T) {
	if _, err := exec.LookPath("codex"); err != nil {
		t.Skip("codex binary not on PATH — qwen-local delegates to codex")
	}
	t.Setenv("PROVIDER", "qwen-local")
	t.Setenv("PROVIDER_CODER", "")

	p, err := runner.ResolveProvider("coder")
	if err != nil {
		t.Fatalf("ResolveProvider: %v", err)
	}
	if p.Name() != "qwen-local" {
		t.Errorf("Name: want qwen-local, got %q", p.Name())
	}
}

// TestResolveProvider_SingleCodex asserts that PROVIDER=codex returns a codex
// provider. Skipped when codex is not on PATH.
func TestResolveProvider_SingleCodex(t *testing.T) {
	if _, err := exec.LookPath("codex"); err != nil {
		t.Skip("codex binary not on PATH")
	}
	t.Setenv("PROVIDER", "codex")
	t.Setenv("PROVIDER_CODER", "")

	p, err := runner.ResolveProvider("coder")
	if err != nil {
		t.Fatalf("ResolveProvider: %v", err)
	}
	if p.Name() != "codex" {
		t.Errorf("Name: want codex, got %q", p.Name())
	}
}

// TestResolveProvider_Default asserts that no PROVIDER env set yields a Chain
// with codex first, then claude (cheapest-first default). Skipped when codex
// is not on PATH since codex.New() requires the binary to exist.
func TestResolveProvider_Default(t *testing.T) {
	if _, err := exec.LookPath("codex"); err != nil {
		t.Skip("codex binary not on PATH — default codex,claude chain requires it")
	}
	t.Setenv("PROVIDER", "")
	t.Setenv("PROVIDER_CODER", "")

	p, err := runner.ResolveProvider("coder")
	if err != nil {
		t.Fatalf("ResolveProvider with defaults: %v", err)
	}
	if !strings.HasPrefix(p.Name(), "chain(") {
		t.Errorf("Name: want chain(...), got %q", p.Name())
	}
	// Default is codex,claude — codex must appear first.
	if !strings.HasPrefix(p.Name(), "chain(codex,") {
		t.Errorf("default chain should start with codex, got %q", p.Name())
	}
}
