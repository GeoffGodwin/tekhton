package runner_test

import (
	"context"
	"errors"
	"strings"
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
//
// m21 note: the default paid-fallback gate (PROVIDER_ALLOW_PAID_FALLBACK=false)
// blocks subscription→api fallthrough. This test explicitly opts in so it
// continues to exercise the fall-through path. See
// TestChain_RunAgent_PaidFallbackBlocked_DefaultBehavior for the blocking path.
func TestChain_RunAgent_FallsThrough(t *testing.T) {
	t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "true") // m21: explicit opt-in for api fallthrough
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
//
// m21 note: PROVIDER_ALLOW_PAID_FALLBACK=true required so the gate doesn't
// block p1→p2 before p2 gets a chance to exhaust itself.
func TestChain_RunAgent_AllExhausted(t *testing.T) {
	t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "true") // m21: both providers exhaust via UpstreamError
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

// TestChain_RunAgent_LocalTierWins asserts that when a local-tier provider
// succeeds in a multi-provider chain, TierUsed records the local tier.
func TestChain_RunAgent_LocalTierWins(t *testing.T) {
	local := &fixedProvider{name: "qwen-local", tier: provider.TierLocal, outcome: provider.OutcomeSuccess}
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(local, codex, claude)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error: %v", err)
	}
	if res.TierUsed != provider.TierLocal {
		t.Errorf("TierUsed: want %q (local won), got %q", provider.TierLocal, res.TierUsed)
	}
}

// TestChain_RunAgent_RequiredTier_Local_RejectsAll asserts that
// RequiredTier=TierLocal rejects subscription-tier and api-tier providers,
// returning ErrTierLimitExceeded and ErrorSubcategory TIER_LIMIT_EXCEEDED.
func TestChain_RunAgent_RequiredTier_Local_RejectsAll(t *testing.T) {
	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex, claude)
	c.RequiredTier = provider.TierLocal // only local passes; both providers exceed it

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

// TestChain_RunAgent_EmptyProviders asserts the m19 empty-chain guard:
// a Chain with zero providers must return a non-nil result with
// Outcome=OutcomeUpstreamError, ErrorSubcategory="EMPTY_CHAIN", and
// a non-nil error — never (nil, nil), which silently panics callers.
func TestChain_RunAgent_EmptyProviders(t *testing.T) {
	c := runner.NewChain() // zero providers

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err == nil {
		t.Error("RunAgent on empty chain: want non-nil error, got nil")
	}
	if res == nil {
		t.Fatal("RunAgent on empty chain: want non-nil result with EMPTY_CHAIN, got nil")
	}
	if res.Outcome != provider.OutcomeUpstreamError {
		t.Errorf("Outcome: want %q, got %q", provider.OutcomeUpstreamError, res.Outcome)
	}
	if res.ErrorSubcategory != "EMPTY_CHAIN" {
		t.Errorf("ErrorSubcategory: want %q, got %q", "EMPTY_CHAIN", res.ErrorSubcategory)
	}
}

// ---------------------------------------------------------------------------
// m21 — paid-fallback gate tests (Goal 2 of m21)
// ---------------------------------------------------------------------------

// TestChain_RunAgent_PaidFallbackBlocked_DefaultBehavior asserts that when
// PROVIDER_ALLOW_PAID_FALLBACK is not set (the m21 default), a subscription→api
// fallthrough is blocked with ErrorSubcategory=PAID_FALLBACK_BLOCKED.
// Acceptance criterion 5 of m21.
func TestChain_RunAgent_PaidFallbackBlocked_DefaultBehavior(t *testing.T) {
	// Unset the flag explicitly to test the default (false) behavior.
	t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "")

	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex, claude)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})

	// The chain must stop — not return success — because the api fallthrough is blocked.
	if err == nil && res != nil && res.Outcome == provider.OutcomeSuccess {
		t.Error("RunAgent succeeded (claude was called) with default paid-fallback gate; expected block")
	}
	if res == nil {
		t.Fatal("RunAgent: want non-nil result with error details, got nil")
	}
	if res.ErrorSubcategory != "PAID_FALLBACK_BLOCKED" {
		t.Errorf("ErrorSubcategory: want PAID_FALLBACK_BLOCKED, got %q", res.ErrorSubcategory)
	}
}

// TestChain_RunAgent_PaidFallbackBlocked_ErrorNamesEnvKey asserts that the
// error message produced by the paid-fallback gate explicitly names the
// PROVIDER_ALLOW_PAID_FALLBACK env key so operators know how to unblock.
// Acceptance criterion 5 of m21: "the error message must name the env key to flip."
func TestChain_RunAgent_PaidFallbackBlocked_ErrorNamesEnvKey(t *testing.T) {
	t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "")

	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex, claude)

	res, _ := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if res == nil {
		t.Fatal("RunAgent: want non-nil result, got nil")
	}
	if !strings.Contains(res.ErrorMessage, "PROVIDER_ALLOW_PAID_FALLBACK") {
		t.Errorf("ErrorMessage %q does not name PROVIDER_ALLOW_PAID_FALLBACK", res.ErrorMessage)
	}
}

// TestChain_RunAgent_PaidFallbackAllowed_ExplicitFlag asserts that when
// PROVIDER_ALLOW_PAID_FALLBACK=true, the chain falls through to the api-tier
// provider and stamps TierUsed correctly.
// Acceptance criterion 6 of m21.
func TestChain_RunAgent_PaidFallbackAllowed_ExplicitFlag(t *testing.T) {
	t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "true")

	codex := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	claude := &fixedProvider{name: "claude", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex, claude)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error with PROVIDER_ALLOW_PAID_FALLBACK=true: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want Success, got %v", res.Outcome)
	}
	if res.TierUsed != provider.TierAPI {
		t.Errorf("TierUsed: want api (claude won), got %q", res.TierUsed)
	}
}

// TestChain_RunAgent_PaidFallbackGate_SameTierNotBlocked asserts that the
// paid-fallback gate does NOT fire when cost rank stays the same or decreases
// — only an INCREASE to api is blocked. This covers subscription→subscription
// and local→local fallthrough paths.
func TestChain_RunAgent_PaidFallbackGate_SameTierNotBlocked(t *testing.T) {
	// PROVIDER_ALLOW_PAID_FALLBACK not set (default=false) — same-tier must
	// still fall through freely.
	t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "")

	sub1 := &fixedProvider{name: "sub1", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	sub2 := &fixedProvider{name: "sub2", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(sub1, sub2)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error for same-tier fallthrough: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want Success (same-tier fallthrough), got %v", res.Outcome)
	}
}

// TestChain_RunAgent_PaidFallbackGate_ApiToApiNotBlocked asserts that
// api→api fallthrough (same tier, higher→higher is still the same rank) is
// not blocked. The gate only fires when the cost rank *increases* to api.
func TestChain_RunAgent_PaidFallbackGate_ApiToApiNotBlocked(t *testing.T) {
	t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "")

	api1 := &fixedProvider{name: "api1", tier: provider.TierAPI, outcome: provider.OutcomeUpstreamError}
	api2 := &fixedProvider{name: "api2", tier: provider.TierAPI, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(api1, api2)

	res, err := c.RunAgent(context.Background(), &provider.Request{Prompt: "test"})
	if err != nil {
		t.Fatalf("RunAgent: unexpected error for api→api fallthrough: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want Success (api→api fallthrough), got %v", res.Outcome)
	}
}
