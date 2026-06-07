package review

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
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
		return nil, err
	}
	out := &cycleOutcome{
		TurnsUsed:     agentResultTurns(agentRes),
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
		return nil, fmt.Errorf("cycle %d: parse report: %w", budget.Current, err)
	}
	out.Report = report
	log.Info(fmt.Sprintf("Reviewer verdict: %s", report.Verdict))

	// 4. REPLAN_REQUIRED branch.
	if report.Verdict == reviewparse.VerdictReplanRequired {
		decision, err := triggerReplan(ctx, cfg, cfg.ReviewerReportFile)
		if err != nil {
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
// dispatches it via the package-level AgentRunner.
func invokeReviewerAgent(ctx context.Context, cfg *config, cycle, limit int, priorBlockers string) (*proto.AgentResultV1, error) {
	vars := prompt.EnvVars()
	vars["REVIEW_CYCLE"] = fmt.Sprintf("%d", cycle)
	vars["MAX_REVIEW_CYCLES"] = fmt.Sprintf("%d", cfg.MaxReviewCycles)
	vars["PRIOR_BLOCKERS_BLOCK"] = priorBlockers

	body, err := prompt.Render(cfg.PromptsDir, "reviewer", vars)
	if err != nil {
		return nil, fmt.Errorf("render reviewer prompt: %w", err)
	}
	promptFile, cleanup, err := writePromptTmpFile(body)
	if err != nil {
		return nil, fmt.Errorf("write reviewer prompt: %w", err)
	}
	defer cleanup()

	agentReq := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        fmt.Sprintf("Reviewer (cycle %d)", cycle),
		Model:        cfg.ReviewerModel,
		MaxTurns:     limit,
		PromptFile:   promptFile,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.ReviewerTools,
	}
	return agentRunner.Run(ctx, agentReq)
}

// agentResultTurns extracts turns_used from an agent result, defaulting to 0.
func agentResultTurns(r *proto.AgentResultV1) int {
	if r == nil {
		return 0
	}
	return r.TurnsUsed
}

// isNullRun mirrors the bash `was_null_run` predicate — true when the agent
// exited non-zero AND used zero turns. The supervisor's Outcome covers both
// turn_exhausted and fatal_error paths; we treat all non-success outcomes
// with zero turns as null runs.
func isNullRun(r *proto.AgentResultV1) bool {
	if r == nil {
		return true
	}
	if r.Outcome == proto.OutcomeSuccess {
		return false
	}
	return r.TurnsUsed == 0
}

// writePromptTmpFile writes content to a temp file and returns its path plus
// a cleanup func.
func writePromptTmpFile(content string) (string, func(), error) {
	f, err := os.CreateTemp("", "tekhton-review-prompt-*.md")
	if err != nil {
		return "", func() {}, err
	}
	if _, err := f.WriteString(content); err != nil {
		_ = f.Close()
		_ = os.Remove(f.Name())
		return "", func() {}, err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(f.Name())
		return "", func() {}, err
	}
	return f.Name(), func() { _ = os.Remove(f.Name()) }, nil
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
