package review

import (
	"context"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
)

// TestCycle_AcceptsApprovedReport verifies the happy-path cycle: agent runs,
// produces an APPROVED report, runOneCycle returns cycleAccept.
func TestCycle_AcceptsApprovedReport(t *testing.T) {
	dir, req := setupProject(t)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(_ *provider.Request) (*provider.Result, error) {
				writeReport(t, dir, "## Verdict\nAPPROVED\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 4}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	cfg := loadConfig(req)
	budget := reviewparse.CycleBudget{Max: 3}
	budget.Increment()
	out, err := runOneCycle(context.Background(), &cfg, &budget, 0, &nullLogger{})
	if err != nil {
		t.Fatalf("runOneCycle: %v", err)
	}
	if out.Decision != cycleAccept {
		t.Errorf("decision=%v want cycleAccept", out.Decision)
	}
	if out.Report == nil || out.Report.Verdict != reviewparse.VerdictApproved {
		t.Errorf("report verdict=%v want APPROVED", out.Report)
	}
	if out.TurnsUsed != 4 {
		t.Errorf("TurnsUsed=%d want 4", out.TurnsUsed)
	}
}

// TestCycle_ChangesRequiredReturnsRework verifies CHANGES_REQUIRED routes to
// cycleRework with the parsed report so the caller can run the rework matrix.
func TestCycle_ChangesRequiredReturnsRework(t *testing.T) {
	dir, req := setupProject(t)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(_ *provider.Request) (*provider.Result, error) {
				writeReport(t, dir, `## Verdict
CHANGES_REQUIRED

## Complex Blockers
- Refactor the auth middleware

## Simple Blockers
- None
`)
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 12}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	cfg := loadConfig(req)
	budget := reviewparse.CycleBudget{Max: 3}
	budget.Increment()
	out, _ := runOneCycle(context.Background(), &cfg, &budget, 0, &nullLogger{})
	if out.Decision != cycleRework {
		t.Errorf("decision=%v want cycleRework", out.Decision)
	}
	if out.Report.HasComplexBlockers() != 1 {
		t.Errorf("complex=%d want 1", out.Report.HasComplexBlockers())
	}
}

// TestCycle_UpstreamErrorAtMax returns cycleUpstreamErrorAtMax with metadata.
func TestCycle_UpstreamErrorAtMax(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(_ *provider.Request) (*provider.Result, error) {
				return &provider.Result{
					Outcome:          provider.OutcomeUpstreamError,
					ErrorCategory:    "UPSTREAM",
					ErrorSubcategory: "api_rate_limit",
					ErrorMessage:     "429 too many requests",
				}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	cfg := loadConfig(req)
	budget := reviewparse.CycleBudget{Max: 1}
	budget.Increment()
	out, _ := runOneCycle(context.Background(), &cfg, &budget, 0, &nullLogger{})
	if out.Decision != cycleUpstreamErrorAtMax {
		t.Errorf("decision=%v want cycleUpstreamErrorAtMax", out.Decision)
	}
	if out.Metadata["agent_error_subcategory"] != "api_rate_limit" {
		t.Errorf("metadata sub=%q want api_rate_limit", out.Metadata["agent_error_subcategory"])
	}
}

// TestCycle_NullRunMidLoopReturnsRework — a null run with cycles remaining
// returns cycleRework so the loop retries.
func TestCycle_NullRunMidLoopReturnsRework(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(_ *provider.Request) (*provider.Result, error) {
				return &provider.Result{
					Outcome:   provider.OutcomeUnknown,
					ExitCode:  1,
					TurnsUsed: 0,
				}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	cfg := loadConfig(req)
	budget := reviewparse.CycleBudget{Max: 3}
	budget.Increment()
	out, _ := runOneCycle(context.Background(), &cfg, &budget, 0, &nullLogger{})
	if out.Decision != cycleRework {
		t.Errorf("decision=%v want cycleRework on mid-loop null run", out.Decision)
	}
}

// TestCycle_SynthesizesReportAtMax exercises the synthesize-at-max path —
// agent succeeds without producing REVIEWER_REPORT.md on the final cycle.
func TestCycle_SynthesizesReportAtMax(t *testing.T) {
	dir, req := setupProject(t)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(_ *provider.Request) (*provider.Result, error) {
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 3}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	cfg := loadConfig(req)
	budget := reviewparse.CycleBudget{Max: 1}
	budget.Increment()
	out, _ := runOneCycle(context.Background(), &cfg, &budget, 0, &nullLogger{})
	if out.Decision != cycleSynthesizedAtMax {
		t.Errorf("decision=%v want cycleSynthesizedAtMax", out.Decision)
	}
	body := readReviewerReport(t, dir)
	if !strings.Contains(body, "## Verdict\nAPPROVED_WITH_NOTES") {
		t.Errorf("synthesized body missing verdict:\n%s", body)
	}
	if !strings.Contains(body, ".tekhton/REVIEWER_REPORT.md was synthesized") {
		t.Errorf("synthesized body missing path embed:\n%s", body)
	}
}

// TestCycle_BumpReviewerTurnsBetweenCycles verifies that BumpFromUsage threads
// the new limit forward and the next agent invocation receives it. The cycle
// helper exposes this as the (TurnsUsed, ReviewerLimit) outputs from
// cycleOutcome; the budget recalibration happens in RunStage.
func TestCycle_TurnUsageRecordedForBump(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("REVIEWER_MAX_TURNS", "20")
	t.Setenv("REVIEWER_MAX_TURNS_CAP", "60")
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(_ *provider.Request) (*provider.Result, error) {
				writeReport(t, dir, "## Verdict\nCHANGES_REQUIRED\n\n## Complex Blockers\n- needs fix\n\n## Simple Blockers\n- None\n")
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 18}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	cfg := loadConfig(req)
	budget := reviewparse.CycleBudget{Max: 3}
	budget.Increment()
	out, _ := runOneCycle(context.Background(), &cfg, &budget, 0, &nullLogger{})
	if out.TurnsUsed != 18 || out.ReviewerLimit != 20 {
		t.Errorf("got (used=%d, limit=%d) want (18, 20)", out.TurnsUsed, out.ReviewerLimit)
	}
	newLimit, bumped := budget.BumpFromUsage(out.TurnsUsed, out.ReviewerLimit, cfg.ReviewerMaxTurnsCap)
	if !bumped {
		t.Errorf("expected bump at 18/20=90%% usage")
	}
	if newLimit != 25 {
		t.Errorf("newLimit=%d want 25 (20*125/100)", newLimit)
	}
}

// nullLogger is a quiet staglog.Logger used by cycle tests.
type nullLogger struct{}

func (nullLogger) Header(string)  {}
func (nullLogger) Info(string)    {}
func (nullLogger) Warn(string)    {}
func (nullLogger) Success(string) {}
