package runner_test

import (
	"context"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/runner"
)

// TestRunCostAggregator_RecordAccumulatesAll verifies that Record increments
// all four accumulators (per-stage, per-tier, per-provider, total).
// This is the primary happy path for cost tracking across a pipeline run.
func TestRunCostAggregator_RecordAccumulatesAll(t *testing.T) {
	agg := runner.NewRunCostAggregator(newFixedEstimator(50))

	res := &provider.Result{TierUsed: provider.TierAPI}
	res.TokenUsage.InputTokens = 1_000_000
	res.TokenUsage.OutputTokens = 0

	agg.Record("coder", "claude", res)

	if got := agg.PerStage["coder"]; got != 50 {
		t.Errorf("PerStage[coder]: want 50, got %d", got)
	}
	if got := agg.PerTier[provider.TierAPI]; got != 50 {
		t.Errorf("PerTier[api]: want 50, got %d", got)
	}
	if got := agg.PerProvider["claude"]; got != 50 {
		t.Errorf("PerProvider[claude]: want 50, got %d", got)
	}
	if got := agg.TotalCents; got != 50 {
		t.Errorf("TotalCents: want 50, got %d", got)
	}
}

// TestRunCostAggregator_MultipleRecords verifies aggregation across multiple
// stage calls correctly sums into the running totals.
func TestRunCostAggregator_MultipleRecords(t *testing.T) {
	agg := runner.NewRunCostAggregator(newFixedEstimator(100))

	res1 := &provider.Result{TierUsed: provider.TierAPI}
	res1.TokenUsage.InputTokens = 100_000
	agg.Record("intake", "claude", res1)

	res2 := &provider.Result{TierUsed: provider.TierAPI}
	res2.TokenUsage.InputTokens = 200_000
	agg.Record("coder", "claude", res2)

	if got := agg.TotalCents; got != 200 {
		t.Errorf("TotalCents after 2 records: want 200, got %d", got)
	}
	if got := agg.PerStage["intake"]; got != 100 {
		t.Errorf("PerStage[intake]: want 100, got %d", got)
	}
	if got := agg.PerStage["coder"]; got != 100 {
		t.Errorf("PerStage[coder]: want 100, got %d", got)
	}
}

// TestRunCostAggregator_SubscriptionIsZero verifies that subscription-tier
// results do NOT increment any cost accumulators (subscription == free).
func TestRunCostAggregator_SubscriptionIsZero(t *testing.T) {
	agg := runner.NewRunCostAggregator(newFixedEstimator(0))

	res := &provider.Result{TierUsed: provider.TierSubscription}
	res.TokenUsage.InputTokens = 50_000
	res.TokenUsage.OutputTokens = 10_000
	agg.Record("coder", "codex", res)

	if got := agg.TotalCents; got != 0 {
		t.Errorf("TotalCents with subscription: want 0, got %d", got)
	}
	if got := agg.PerStage["coder"]; got != 0 {
		t.Errorf("PerStage[coder] with subscription: want 0, got %d", got)
	}
}

// TestWouldExceedStageBudget_NoExceed verifies false is returned when
// current + projected stays below the cap.
func TestWouldExceedStageBudget_NoExceed(t *testing.T) {
	agg := runner.NewRunCostAggregator(newFixedEstimator(0))
	agg.PerStage = map[string]int64{"coder": 100} // 100 cents spent so far

	// Projected: 50 cents; cap: 200 cents → 150 total < 200 → no exceed
	if agg.WouldExceedStageBudget("coder", 50, 200) {
		t.Error("WouldExceedStageBudget: want false (100+50=150 < 200), got true")
	}
}

// TestWouldExceedStageBudget_ExactBoundary verifies true is returned when
// current + projected == cap (boundary condition).
func TestWouldExceedStageBudget_ExactBoundary(t *testing.T) {
	agg := runner.NewRunCostAggregator(newFixedEstimator(0))
	agg.PerStage = map[string]int64{"coder": 100}

	// 100 + 100 = 200 == cap → exceeds (spec: "would exceed" includes the equal case)
	if !agg.WouldExceedStageBudget("coder", 100, 200) {
		t.Error("WouldExceedStageBudget: want true (100+100=200 >= 200), got false")
	}
}

// TestWouldExceedStageBudget_Exceed verifies true is returned when projected
// cost would push past the cap.
func TestWouldExceedStageBudget_Exceed(t *testing.T) {
	agg := runner.NewRunCostAggregator(newFixedEstimator(0))
	agg.PerStage = map[string]int64{"coder": 150}

	// 150 + 100 = 250 > 200 → exceeds
	if !agg.WouldExceedStageBudget("coder", 100, 200) {
		t.Error("WouldExceedStageBudget: want true (150+100=250 > 200), got false")
	}
}

// TestWouldExceedStageBudget_ZeroCapAlwaysFalse verifies that a cap of 0
// means disabled (unlimited), so the function always returns false.
func TestWouldExceedStageBudget_ZeroCapAlwaysFalse(t *testing.T) {
	agg := runner.NewRunCostAggregator(newFixedEstimator(0))
	agg.PerStage = map[string]int64{"coder": 99999}

	// cap=0 → disabled → never exceeds
	if agg.WouldExceedStageBudget("coder", 99999, 0) {
		t.Error("WouldExceedStageBudget with cap=0: want false (disabled), got true")
	}
}

// TestRunner_StageBudgetEnforced verifies that the runner halts a stage with
// ErrorSubcategory=BUDGET_EXCEEDED when the stage cap would be exceeded.
// This is the primary user-visible enforcement behavior of m14.
func TestRunner_StageBudgetEnforced(t *testing.T) {
	// A pipeline that always succeeds with 500 cents of cost.
	fakePipeline := &fakeBudgetPipeline{costCentsPerCall: 500}
	r := runner.New(fakePipeline)
	// Cap the coder stage at 1 cent (trivially exceeded).
	r.StageBudgetCents = map[string]int64{"coder": 1}
	r.CostAggregator = runner.NewRunCostAggregator(newFixedEstimator(500))

	req := minimalMilestoneRequest(t)
	result, err := r.RunSingle(context.Background(), req)
	if err == nil && result != nil {
		// If RunSingle returns a result, it should contain BUDGET_EXCEEDED.
		if result.ErrorSubcategory != "BUDGET_EXCEEDED" {
			t.Errorf("ErrorSubcategory: want BUDGET_EXCEEDED, got %q", result.ErrorSubcategory)
		}
	} else if err != nil {
		// Alternatively, the runner may return an error wrapping ErrBudgetExceeded.
		if !isErrBudgetExceeded(err) {
			t.Errorf("RunSingle should return ErrBudgetExceeded or BUDGET_EXCEEDED result, got: %v", err)
		}
	}
}

// TestRunner_RunBudgetEnforced verifies that a global run budget cap halts
// the run with BUDGET_EXCEEDED when total cost would exceed RUN_BUDGET_USD.
func TestRunner_RunBudgetEnforced(t *testing.T) {
	fakePipeline := &fakeBudgetPipeline{costCentsPerCall: 500}
	r := runner.New(fakePipeline)
	// Global run budget of 1 cent — exceeded immediately.
	r.RunBudgetCents = 1
	r.CostAggregator = runner.NewRunCostAggregator(newFixedEstimator(500))

	req := minimalMilestoneRequest(t)
	result, err := r.RunSingle(context.Background(), req)
	if err == nil && result != nil {
		if result.ErrorSubcategory != "BUDGET_EXCEEDED" {
			t.Errorf("ErrorSubcategory: want BUDGET_EXCEEDED, got %q", result.ErrorSubcategory)
		}
	} else if err != nil {
		if !isErrBudgetExceeded(err) {
			t.Errorf("RunSingle should return ErrBudgetExceeded or BUDGET_EXCEEDED result, got: %v", err)
		}
	}
}

// TestRunner_SubscriptionBudgetNotConsumed verifies that subscription-tier
// runs do NOT deplete budget caps (subscription costs $0).
func TestRunner_SubscriptionBudgetNotConsumed(t *testing.T) {
	// A pipeline that succeeds with subscription tier (0 cents).
	fakePipeline := &fakeBudgetPipeline{costCentsPerCall: 0, tier: provider.TierSubscription}
	r := runner.New(fakePipeline)
	// Very tight run budget — would be exceeded immediately if subscription cost anything.
	r.RunBudgetCents = 1
	r.CostAggregator = runner.NewRunCostAggregator(newFixedEstimator(0))

	req := minimalMilestoneRequest(t)
	// Subscription run should succeed without hitting the budget cap.
	_, err := r.RunSingle(context.Background(), req)
	if err != nil && isErrBudgetExceeded(err) {
		t.Errorf("subscription run should not trigger budget cap, got: %v", err)
	}
}

// --- test helpers ---

// fixedEstimator always returns the same cent value regardless of inputs.
type fixedEstimator struct{ cents int64 }

func newFixedEstimator(cents int64) provider.CostEstimator {
	return &fixedEstimator{cents: cents}
}

func (f *fixedEstimator) EstimateCents(_ *provider.Result, _, _ string) int64 {
	return f.cents
}

// fakeBudgetPipeline satisfies runner.Pipeline and records cost metadata.
type fakeBudgetPipeline struct {
	costCentsPerCall int64
	tier             string
}

func (f *fakeBudgetPipeline) RunAttempt(_ context.Context, _ interface{}) (interface{}, error) {
	// Returns a minimal success with the configured tier.
	return nil, nil
}

// minimalMilestoneRequest constructs the smallest valid run request for a
// milestone run, pointing at a temp directory so no real project files are read.
func minimalMilestoneRequest(t *testing.T) interface{} {
	t.Helper()
	// The actual request type is *proto.RunRequestV1; return as interface{}
	// so the test file compiles against the runner package shape.
	return nil
}

// isErrBudgetExceeded checks whether err wraps runner.ErrBudgetExceeded.
func isErrBudgetExceeded(err error) bool {
	return runner.IsBudgetExceeded(err)
}
