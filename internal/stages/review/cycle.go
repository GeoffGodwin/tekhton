package review

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/provider"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// cycleDecision is the per-cycle terminal classification the loop driver
// branches on. Reduced from the bash side's verdict + sentinel cocktail to a
// single enum so RunStage can switch over it cleanly.
type cycleDecision int

const (
	cycleAccept cycleDecision = iota
	cycleReplanAbort
	cycleReplanContinue
	cycleUpstreamErrorAtMax
	cycleNullRunAtMax
	cycleSynthesizedAtMax
	cycleRework
)

// cycleOutcome carries the cycle's outcome plus the bookkeeping RunStage
// needs to schedule the next iteration.
type cycleOutcome struct {
	Decision      cycleDecision
	Report        *reviewparse.Report
	TurnsUsed     int
	ReviewerLimit int
	AgentCalls    int
	Metadata      map[string]string
}

// runOneCycle drives a single reviewer pass. Returns the outcome without
// mutating PIPELINE_STATE (the runner owns persistence).
func runOneCycle(ctx context.Context, cfg *config, budget *reviewparse.CycleBudget,
	bumpedLimit int, log staglog.Logger,
) (*cycleOutcome, error) {
	limit := bumpedLimit
	if limit == 0 {
		limit = cfg.AdjustedReviewerTurn
	}
	if limit == 0 {
		limit = cfg.ReviewerMaxTurns
	}

	// 1. Invoke the reviewer agent.
	priorBlockers := ""
	if budget.Current > 1 {
		priorBlockers = "yes"
	}

	agentRes, err := invokeReviewerAgent(ctx, cfg, budget.Current, limit, priorBlockers)
	if err != nil {
		// m47 classification: pre-parse infrastructure error. The reviewer
		// agent could not be dispatched, so there is no verdict envelope to
		// preserve. Propagate to the runner.
		return nil, err
	}
	out := &cycleOutcome{
		TurnsUsed:     providerResultTurns(agentRes),
		ReviewerLimit: limit,
		AgentCalls:    1,
	}

	// 2. Handle upstream / null-run / no-report fallbacks.
	if agentRes != nil && agentRes.ErrorCategory == "UPSTREAM" {
		log.Warn(fmt.Sprintf("Reviewer hit an API error (%s).", agentRes.ErrorSubcategory))
		if budget.IsExhausted() {
			out.Decision = cycleUpstreamErrorAtMax
			out.Metadata = map[string]string{
				"agent_error_subcategory": agentRes.ErrorSubcategory,
				"agent_error_message":     agentRes.ErrorMessage,
			}
			return out, nil
		}
		out.Decision = cycleRework
		return out, nil
	}
	if isNullRun(agentRes) {
		log.Warn(fmt.Sprintf("Reviewer was a null run (%d turns).", out.TurnsUsed))
		if budget.IsExhausted() {
			out.Decision = cycleNullRunAtMax
			return out, nil
		}
		out.Decision = cycleRework
		return out, nil
	}

	if !fileExists(cfg.ReviewerReportFile) {
		log.Warn(fmt.Sprintf("Reviewer did not produce %s.", cfg.ReviewerReportFile))
		if !budget.IsExhausted() {
			out.Decision = cycleRework
			return out, nil
		}
		// Synthesize-at-max: build the bash-byte-identical fallback report,
		// trip the commit gate, return synthesized-at-max.
		if err := synthesizeMinimalReport(cfg.ReviewerReportFile, cfg.ReviewerReportFileRaw); err != nil {
			// m47 classification: synthesize-at-max IS the envelope-emission
			// step on this branch; if it fails, there is no envelope to
			// preserve and the runner must record a synth-path failure.
			return nil, fmt.Errorf("synthesize minimal report: %w", err)
		}
		if err := tripCommitGate(cfg, "reviewer_did_not_produce_report"); err != nil {
			log.Warn(fmt.Sprintf("trip_commit_gate: %v", err))
		}
		out.Decision = cycleSynthesizedAtMax
		return out, nil
	}

	// 3. Parse the reviewer report.
	report, err := reviewparse.ParseReviewerReport(cfg.ReviewerReportFile)
	if err != nil {
		// m47 classification: pre-parse error. Without a parsed verdict the
		// stage has nothing to preserve — propagate so the runner records a
		// structural failure.
		return nil, fmt.Errorf("cycle %d: parse report: %w", budget.Current, err)
	}
	out.Report = report
	log.Info(fmt.Sprintf("Reviewer verdict: %s", report.Verdict))

	// 4. REPLAN_REQUIRED branch.
	if report.Verdict == reviewparse.VerdictReplanRequired {
		decision, err := triggerReplan(ctx, cfg, cfg.ReviewerReportFile)
		if err != nil {
			// m47 classification: triggerReplan drives an out-of-band human
			// dialog. A failure to run it is structural — the operator
			// cannot have signalled intent, so we propagate rather than
			// silently treating it as approved.
			return nil, err
		}
		switch decision {
		case replanUserAborted:
			out.Decision = cycleReplanAbort
			return out, nil
		case replanContinue:
			out.Decision = cycleReplanContinue
			return out, nil
		}
	}

	// 5. APPROVED / APPROVED_WITH_NOTES.
	if report.IsApproved() {
		out.Decision = cycleAccept
		return out, nil
	}

	// 6. CHANGES_REQUIRED — caller drives rework or blockers-remain.
	out.Decision = cycleRework
	return out, nil
}

// invokeReviewerAgent renders the reviewer prompt with cycle-aware vars and
// dispatches it via the config's Provider.
func invokeReviewerAgent(ctx context.Context, cfg *config, cycle, limit int, priorBlockers string) (*provider.Result, error) {
	vars := prompt.EnvVars()
	vars["REVIEW_CYCLE"] = fmt.Sprintf("%d", cycle)
	vars["MAX_REVIEW_CYCLES"] = fmt.Sprintf("%d", cfg.MaxReviewCycles)
	vars["PRIOR_BLOCKERS_BLOCK"] = priorBlockers

	body, err := prompt.Render(cfg.PromptsDir, "reviewer", vars)
	if err != nil {
		// m47 classification: pre-parse failure — the reviewer agent never
		// runs without a rendered prompt.
		return nil, fmt.Errorf("render reviewer prompt: %w", err)
	}
	return cfg.Provider.RunAgent(ctx, &provider.Request{
		Prompt:       body,
		Label:        fmt.Sprintf("Reviewer (cycle %d)", cycle),
		Model:        cfg.ReviewerModel,
		MaxTurns:     limit,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.ReviewerTools,
	})
}

// providerResultTurns extracts turns_used from a provider result, defaulting to 0.
func providerResultTurns(r *provider.Result) int {
	if r == nil {
		return 0
	}
	return r.TurnsUsed
}

// isNullRun mirrors the bash `was_null_run` predicate — true when the agent
// exited non-zero AND used zero turns.
func isNullRun(r *provider.Result) bool {
	if r == nil {
		return true
	}
	if r.Outcome == provider.OutcomeSuccess {
		return false
	}
	return r.TurnsUsed == 0
}

// errSynthesize is returned when the synthesize-at-max path is engaged but
// the report file cannot be written. Surfaced as a generic error to the
// runner — it will record the failure under the synth path.
var errSynthesize = errors.New("review: failed to synthesize minimal report")

// synthesizeMinimalReport writes the bash-byte-identical synthesize-template
// from stages/review.sh:194-211. Field-for-field preservation is required so
// downstream parsers (tester stage, metrics) see the same shape.
//
// reportPath is the resolved (absolute) destination written to disk; displayPath
// is what the bash `${REVIEWER_REPORT_FILE:-.tekhton/REVIEWER_REPORT.md}` shell
// expansion would render — embedded in the body so a temp-dir test fixture
// keeps the bash-equivalent path string in the file contents.
func synthesizeMinimalReport(reportPath, displayPath string) error {
	if reportPath == "" {
		return errSynthesize
	}
	if displayPath == "" {
		displayPath = reportPath
	}
	body := "## Verdict\nAPPROVED_WITH_NOTES\n\n" +
		"## Summary\n" +
		displayPath + " was synthesized by the pipeline after the reviewer agent\n" +
		"failed to produce it. The reviewer may have encountered issues reading or\n" +
		"writing the report file. The tester should validate all changes thoroughly.\n\n" +
		"## Complex Blockers\n- None (reviewer did not report)\n\n" +
		"## Simple Blockers\n- None (reviewer did not report)\n\n" +
		"## Non-Blocking Notes\n- Reviewer agent did not produce a report — extra tester scrutiny recommended.\n"
	return os.WriteFile(reportPath, []byte(body), 0o644)
}
