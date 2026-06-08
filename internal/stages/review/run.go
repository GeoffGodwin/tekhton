// Package review implements the Tekhton review stage (m37.2 port).
//
// RunStage is the entry point registered in
// internal/stagerunner.DefaultStageDefs[proto.StageReview].GoImpl. It mirrors
// stages/review.sh + stages/review_helpers.sh end-to-end:
//
//  1. Skip checks: polish heuristic + diff-size threshold (M42 + M48).
//  2. Cycle loop bounded by MAX_REVIEW_CYCLES — invoke reviewer, parse,
//     classify, dispatch (replan / synthesize-at-max / rework / accept).
//  3. After loop: specialist post-loop branch (passthrough / rework / exhausted).
//
// Cycle-loop placement decision per m37 parent: the loop stays in-stage for
// M37. Hoisting into internal/orchestrate is a post-M39 candidate.
package review

import (
	"context"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// BuildGateRunner is the seam for the post-rework build gate. Production
// shells out to `tekhton gate build`; tests substitute a recording fake.
type BuildGateRunner interface {
	Run(ctx context.Context, projectDir, stageLabel string) error
}

var (
	stageProvider   provider.Provider
	buildGateRunner BuildGateRunner = subprocessBuildGate{}
)

// SetProvider replaces the package-level provider. Returns the previous
// value so callers can defer-restore.
func SetProvider(p provider.Provider) provider.Provider {
	prev := stageProvider
	stageProvider = p
	return prev
}

// SetBuildGateRunner replaces the package-level build-gate seam.
func SetBuildGateRunner(r BuildGateRunner) BuildGateRunner {
	prev := buildGateRunner
	buildGateRunner = r
	return prev
}

// RunStage is the m37.2 entry point. Owns the cycle loop end-to-end and
// returns ONCE with a terminal StageResultV1.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	cfg := loadConfig(req)
	log := staglog.New(req)
	log.Header("Reviewer")

	// --- Skip heuristics (bash lines 14-36) ---
	if shouldSkipPolish(&cfg) {
		log.Info("Skipping reviewer — all changes are non-logic files (polish mode).")
		return approvedSkipResult(req, "skipped_polish_mode", map[string]string{
			"reviewer_skipped": "true",
		}), nil
	}
	if reason, skip := shouldSkipBySize(&cfg); skip {
		log.Info(fmt.Sprintf("Skipping reviewer — diff size (%s lines) below threshold (%s).",
			reason.DiffLines, reason.Threshold))
		return approvedSkipResult(req, "skipped_diff_threshold", map[string]string{
			"reviewer_skipped": "true",
			"skip_threshold":   reason.Threshold,
			"skip_diff_lines":  reason.DiffLines,
		}), nil
	}

	// --- Cycle loop ---
	budget := reviewparse.CycleBudget{Max: cfg.MaxReviewCycles}
	bumpedReviewerTurns := 0 // 0 means no bump in effect
	var lastReport *reviewparse.Report
	agentCalls := 0

	for budget.Current < budget.Max {
		budget.Increment()
		log.Info(fmt.Sprintf("Reviewer cycle %d/%d", budget.Current, budget.Max))

		cycleOut, err := runOneCycle(ctx, &cfg, &budget, bumpedReviewerTurns, log)
		if err != nil {
			// m47 classification: this propagates the cycle.go pre-parse
			// error sites (reviewer agent infra failure, prompt-render
			// failure, parse failure, replan-trigger failure). No verdict
			// envelope was produced for this cycle, so the runner needs
			// the Go-level error to record a structural failure.
			return nil, err
		}
		agentCalls += cycleOut.AgentCalls

		// Apply in-cycle turn-budget recalibration for the NEXT iteration.
		if newLimit, bumped := budget.BumpFromUsage(cycleOut.TurnsUsed, cycleOut.ReviewerLimit, cfg.ReviewerMaxTurnsCap); bumped {
			log.Info(fmt.Sprintf("[turns] Reviewer used %d/%d turns — bumping limit to %d for next cycle.",
				cycleOut.TurnsUsed, cycleOut.ReviewerLimit, newLimit))
			bumpedReviewerTurns = newLimit
		}

		switch cycleOut.Decision {
		case cycleAccept:
			lastReport = cycleOut.Report
			return finalizeApproved(ctx, req, &cfg, lastReport, &budget, agentCalls, log)
		case cycleReplanAbort:
			return failResult(req, "replan_user_aborted", agentCalls, cycleOut.Metadata), nil
		case cycleReplanContinue:
			// Bash line 235 — verdict overridden to APPROVED_WITH_NOTES.
			synth := &reviewparse.Report{Verdict: reviewparse.VerdictApprovedWithNotes}
			return finalizeApproved(ctx, req, &cfg, synth, &budget, agentCalls, log)
		case cycleUpstreamErrorAtMax:
			return failResult(req, "upstream_error", agentCalls, cycleOut.Metadata), nil
		case cycleNullRunAtMax:
			return failResult(req, "null_run", agentCalls, cycleOut.Metadata), nil
		case cycleSynthesizedAtMax:
			return synthesizedResult(req, agentCalls), nil
		case cycleRework:
			lastReport = cycleOut.Report
			if budget.IsExhausted() && cycleOut.Report != nil {
				// Final cycle ended with blockers remaining.
				return blockersRemainResult(req, cycleOut.Report, &budget, agentCalls), nil
			}
			// Cycles remain — drive the rework matrix.
			if cycleOut.Report != nil {
				reworkCalls, err := runRework(ctx, &cfg, cycleOut.Report, budget, log)
				agentCalls += reworkCalls
				if err != nil {
					return reworkFailureResult(req, &budget, agentCalls, err), nil
				}
			}
			continue
		}
	}

	// Loop exited without a terminal decision (defensive — should not happen
	// because the cycleRework branch handles the IsExhausted case). Treat as
	// blockers-remain.
	return blockersRemainResult(req, lastReport, &budget, agentCalls), nil
}

// approvedSkipResult emits the skip-path APPROVED_WITH_NOTES verdict the bash
// stage returned from the polish + diff-size branches.
func approvedSkipResult(req *proto.StageRequestV1, reason string, meta map[string]string) *proto.StageResultV1 {
	merged := mergeMeta(map[string]string{"verdict": "APPROVED_WITH_NOTES"}, meta)
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: reason,
		NextAction: "approve",
		Error:      metaToError(merged),
	}
}

// failResult returns a verdict=fail envelope with the supplied exit reason +
// metadata. Metadata is serialized into the Error field as a `key=value\n…`
// blob — the StageResultV1 envelope does not carry a structured metadata map
// today, so we stuff it into Error per the existing intake-stage precedent.
// Test assertions in this package decode by line.
func failResult(req *proto.StageRequestV1, reason string, agentCalls int, meta map[string]string) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictFail,
		ExitReason: reason,
		AgentCalls: agentCalls,
		Error:      metaToError(meta),
	}
}

// synthesizedResult builds the envelope for the synthesize-at-max branch.
// The reviewer never produced REVIEWER_REPORT.md, the cycle loop synthesized
// a minimal one + tripped the commit gate, and the stage proceeds with
// APPROVED_WITH_NOTES.
func synthesizedResult(req *proto.StageRequestV1, agentCalls int) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: "synthesized_at_max",
		AgentCalls: agentCalls,
		NextAction: "approve",
		Error: metaToError(map[string]string{
			"verdict":             "APPROVED_WITH_NOTES",
			"commit_gate_tripped": "true",
			"synthesized_report":  "true",
		}),
	}
}

// blockersRemainResult emits the fail envelope when max cycles is reached
// with unresolved CHANGES_REQUIRED blockers. Mirrors bash lines 354-368.
func blockersRemainResult(req *proto.StageRequestV1, report *reviewparse.Report, budget *reviewparse.CycleBudget, agentCalls int) *proto.StageResultV1 {
	meta := map[string]string{
		"verdict": "CHANGES_REQUIRED",
	}
	if report != nil {
		meta["complex_blockers"] = fmt.Sprintf("%d", report.HasComplexBlockers())
		meta["simple_blockers"] = fmt.Sprintf("%d", report.HasSimpleBlockers())
	}
	if budget != nil {
		meta["cycles_done"] = fmt.Sprintf("%d", budget.Current)
		meta["max_cycles"] = fmt.Sprintf("%d", budget.Max)
	}
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictFail,
		ExitReason: "blockers_remain",
		AgentCalls: agentCalls,
		NextAction: "rework",
		Error:      metaToError(meta),
	}
}

// reworkFailureResult emits the fail envelope when the rework matrix's
// build-gate escalation path could not recover.
func reworkFailureResult(req *proto.StageRequestV1, budget *reviewparse.CycleBudget, agentCalls int, cause error) *proto.StageResultV1 {
	meta := map[string]string{}
	if cause != nil {
		meta["rework_error"] = cause.Error()
	}
	if budget != nil {
		meta["cycles_done"] = fmt.Sprintf("%d", budget.Current)
	}
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictFail,
		ExitReason: "build_failure",
		AgentCalls: agentCalls,
		Error:      metaToError(meta),
	}
}

// approvedResult is the happy-path verdict — reviewer approved, specialists
// passed (or specialist branch wasn't engaged).
func approvedResult(req *proto.StageRequestV1, report *reviewparse.Report, budget *reviewparse.CycleBudget, agentCalls int) *proto.StageResultV1 {
	verdict := string(reviewparse.VerdictApproved)
	if report != nil && report.Verdict != reviewparse.VerdictUnknown {
		verdict = string(report.Verdict)
	}
	meta := map[string]string{"verdict": verdict}
	if budget != nil {
		meta["cycles_done"] = fmt.Sprintf("%d", budget.Current)
	}
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: "approved",
		AgentCalls: agentCalls,
		NextAction: "approve",
		Error:      metaToError(meta),
	}
}

// mergeMeta returns a single map composed of the inputs; later maps override
// earlier ones key-by-key.
func mergeMeta(maps ...map[string]string) map[string]string {
	out := map[string]string{}
	for _, m := range maps {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}

// metaToError serializes a metadata map into the StageResultV1.Error blob.
// Lines are sorted lexically by key so two identical input maps yield
// byte-identical output (parity-test fixtures depend on this).
func metaToError(meta map[string]string) string {
	if len(meta) == 0 {
		return ""
	}
	keys := make([]string, 0, len(meta))
	for k := range meta {
		keys = append(keys, k)
	}
	sortStrings(keys)
	var s string
	for _, k := range keys {
		s += k + "=" + meta[k] + "\n"
	}
	return s
}

// sortStrings is a tiny insertion sort to avoid an `sort` import in this
// small helper file. Keeps the metaToError serializer hermetic.
func sortStrings(a []string) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j-1] > a[j]; j-- {
			a[j-1], a[j] = a[j], a[j-1]
		}
	}
}

// fileExists is a small filesystem helper used by the cycle loop.
func fileExists(p string) bool {
	if p == "" {
		return false
	}
	_, err := os.Stat(p)
	return err == nil
}
