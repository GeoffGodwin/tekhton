package runner_test

import (
	"context"
	"errors"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/runner"
)

// fixedProvider is a test double that returns a pre-configured Result and tier.
type fixedProvider struct {
	name    string
	tier    string
	outcome provider.Outcome
	err     error
}

func (f *fixedProvider) Name() string { return f.name }
func (f *fixedProvider) Tier() string { return f.tier }
func (f *fixedProvider) RunAgent(_ context.Context, _ *provider.Request) (*provider.Result, error) {
	if f.err != nil {
		return nil, f.err
	}
	return &provider.Result{Outcome: f.outcome}, f.err
}

// TestChain_SortByCostRank asserts that SortByCostRank reorders providers from
// most-expensive-first to cheapest-first. The acceptance criterion in m13:
// [Claude(api), Codex(subscription)] becomes [Codex(subscription), Claude(api)].
func TestChain_SortByCostRank(t *testing.T) {
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}

	c := runner.NewChain(claude, codex) // expensive first
	c.SortByCostRank()

	if c.Providers[0].Name() != "codex" {
		t.Errorf("after sort, Providers[0]: want codex (subscription), got %s", c.Providers[0].Name())
	}
	if c.Providers[1].Name() != "claude" {
		t.Errorf("after sort, Providers[1]: want claude (api), got %s", c.Providers[1].Name())
	}
}

// TestChain_SortByCostRank_Local asserts local ranks before subscription.
func TestChain_SortByCostRank_Local(t *testing.T) {
	api := &fixedProvider{name: "paid", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	sub := &fixedProvider{name: "sub", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	local := &fixedProvider{name: "local", tier: provider.TierLocal, outcome: provider.OutcomeSuccess}

	c := runner.NewChain(api, sub, local) // worst order
	c.SortByCostRank()

	names := []string{c.Providers[0].Name(), c.Providers[1].Name(), c.Providers[2].Name()}
	if names[0] != "local" || names[1] != "sub" || names[2] != "paid" {
		t.Errorf("sort order: want [local, sub, paid], got %v", names)
	}
}

// TestChain_SortByCostRank_AlreadySorted asserts stable sort doesn't permute
// an already-sorted chain.
func TestChain_SortByCostRank_AlreadySorted(t *testing.T) {
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}

	c := runner.NewChain(codex, claude) // already cheapest-first
	c.SortByCostRank()

	if c.Providers[0].Name() != "codex" || c.Providers[1].Name() != "claude" {
		t.Errorf("already-sorted chain was permuted: got [%s, %s]",
			c.Providers[0].Name(), c.Providers[1].Name())
	}
}

// TestChain_RunAgent_RecordsTierUsed asserts that RunAgent stamps
// Result.TierUsed with the tier of the winning provider.
func TestChain_RunAgent_RecordsTierUsed(t *testing.T) {
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error: %v", err)
	}
	if res.TierUsed != provider.TierSubscription {
		t.Errorf("TierUsed: want %q, got %q", provider.TierSubscription, res.TierUsed)
	}
}

// TestChain_RunAgent_FallsThrough asserts that OutcomeUpstreamError from the
// first provider causes fallthrough to the second, and TierUsed reflects the
// second provider's tier.
func TestChain_RunAgent_FallsThrough(t *testing.T) {
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex, claude)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want OutcomeSuccess, got %v", res.Outcome)
	}
	if res.TierUsed != provider.TierAPI {
		t.Errorf("TierUsed: want %q (claude won), got %q", provider.TierAPI, res.TierUsed)
	}
}

// TestChain_RunAgent_NoFallthroughOnNonUpstream asserts that non-upstream
// failures (e.g., MaxTurns, NullRun) do NOT cause fallthrough.
func TestChain_RunAgent_NoFallthroughOnNonUpstream(t *testing.T) {
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeMaxTurns}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex, claude)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error: %v", err)
	}
	// Codex returned MaxTurns — should stop there, not fall to claude.
	if res.Outcome != provider.OutcomeMaxTurns {
		t.Errorf("Outcome: want OutcomeMaxTurns (no fallthrough), got %v", res.Outcome)
	}
	if res.TierUsed != provider.TierSubscription {
		t.Errorf("TierUsed: want %q (codex ran, not claude), got %q",
			provider.TierSubscription, res.TierUsed)
	}
}

// TestChain_RunAgent_AllExhausted asserts that when all providers return
// UpstreamError, the chain returns the last result.
func TestChain_RunAgent_AllExhausted(t *testing.T) {
	p1 := &fixedProvider{name: "p1", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	p2 := &fixedProvider{name: "p2", tier: provider.TierAPI, outcome: provider.OutcomeUpstreamError}
	c := runner.NewChain(p1, p2)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error: %v", err)
	}
	if res.Outcome != provider.OutcomeUpstreamError {
		t.Errorf("Outcome: want OutcomeUpstreamError (all exhausted), got %v", res.Outcome)
	}
}

// TestChain_RunAgent_RequiredTier_Rejected asserts that a provider whose
// tier exceeds RequiredTier is rejected with ErrorSubcategory=TIER_LIMIT_EXCEEDED.
func TestChain_RunAgent_RequiredTier_Rejected(t *testing.T) {
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(claude)
	c.RequiredTier = provider.TierSubscription // subscription tier max

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err == nil {
		t.Fatal("RunAgent: expected error for tier limit exceeded, got nil")
	}
	if !errors.Is(err, runner.ErrTierLimitExceeded) {
		t.Errorf("error: want ErrTierLimitExceeded, got %v", err)
	}
	if res == nil {
		t.Fatal("result: want non-nil result with ErrorSubcategory, got nil")
	}
	if res.ErrorSubcategory != "TIER_LIMIT_EXCEEDED" {
		t.Errorf("ErrorSubcategory: want TIER_LIMIT_EXCEEDED, got %q", res.ErrorSubcategory)
	}
}

// TestChain_RunAgent_RequiredTier_Allowed asserts that a provider at exactly
// the required tier is allowed to run.
func TestChain_RunAgent_RequiredTier_Allowed(t *testing.T) {
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex)
	c.RequiredTier = provider.TierSubscription

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent with matching tier: unexpected error: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want Success, got %v", res.Outcome)
	}
}

// TestChain_RunAgent_ProcessError asserts that a process-level error (non-nil
// err from provider.RunAgent) stops the chain without TierUsed being set.
func TestChain_RunAgent_ProcessError(t *testing.T) {
	boom := &fixedProvider{
		name: "boom", tier: provider.TierSubscription,
		err: errors.New("binary not found"),
	}
	c := runner.NewChain(boom)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err == nil {
		t.Fatal("RunAgent: expected error for process failure, got nil")
	}
	// nil res or TierUsed="" — process errors don't record tier
	if res != nil && res.TierUsed != "" {
		t.Errorf("TierUsed: want empty on process error, got %q", res.TierUsed)
	}
}

// TestChain_Name asserts the diagnostic name encodes all provider names.
func TestChain_Name(t *testing.T) {
	c := runner.NewChain(
		&fixedProvider{name: "codex", tier: provider.TierSubscription},
		&fixedProvider{name: "claude", tier: provider.TierAPI},
	)
	if got := c.Name(); got != "chain(codex,claude)" {
		t.Errorf("Name: want chain(codex,claude), got %s", got)
	}
}

// TestChain_RunAgent_EmptyProviders documents the (nil, nil) return when no
// providers are registered. The for-loop body never executes, so both
// lastResult and lastErr remain their zero values. Callers must nil-check
// the result before dereferencing. Reviewer gap: internal/runner/provider_chain.go
// lacks an early guard for this case, making it a silent hazard.
func TestChain_RunAgent_EmptyProviders(t *testing.T) {
	c := runner.NewChain() // zero providers

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Errorf("RunAgent on empty chain: want nil error, got %v", err)
	}
	if res != nil {
		t.Errorf("RunAgent on empty chain: want nil result, got %+v", res)
	}
}
