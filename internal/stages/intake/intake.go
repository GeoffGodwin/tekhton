// Package intake implements the Tekhton intake stage (m36.3 port).
//
// RunStage is the entry point registered in
// internal/stagerunner.DefaultStageDefs[proto.StageIntake].GoImpl. It mirrors
// the bash run_stage_intake flow at stages/intake.sh line-for-line:
//
//  1. Pipeline-start cleanup — clear .final_check_result + .commit_decision.
//     This is the SOLE owner of those sentinels (intake runs first).
//  2. Skip checks: INTAKE_AGENT_ENABLED, HUMAN_MODE.
//  3. Cached-run branch: INTAKE_CACHED + report present.
//  4. Content read + content-hash skip.
//  5. Render prompt → invoke agent.
//  6. Parse verdict + dispatch (PASS / TWEAKED / SPLIT_RECOMMENDED / NEEDS_CLARITY).
//  7. Emit verdict + INTAKE_VERDICT / INTAKE_CONFIDENCE / _INTAKE_PASS_EMIT exports.
//
// The stage never returns verdict=fail under normal operation; verdict=block
// is reserved for the halt paths driven by the VerdictHandler (operator
// rejected tweaks; complete-mode needs-clarity; clarify-handle aborted).
package intake

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	pkgintake "github.com/geoffgodwin/tekhton/internal/intake"
	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// stageProvider is the package-level provider seam. Production code sets it
// via SetProvider before running the pipeline; tests inject a fake.
// A nil stageProvider panics on first RunAgent call so wiring gaps surface
// immediately rather than silently falling back to direct supervisor calls.
var stageProvider provider.Provider

// SetProvider replaces the package-level provider. Returns the previous value
// so callers can defer-restore.
func SetProvider(p provider.Provider) provider.Provider {
	prev := stageProvider
	stageProvider = p
	return prev
}

// RunStage is the m36.3 entry point. Signature matches stagerunner.StageImpl.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	cfg := loadConfig(req)
	log := staglog.New(req)

	// 1. Sentinel cleanup — sole owner of these per-run sentinels.
	cleanupSentinels(cfg)

	// 2. Disabled-agent skip.
	if !cfg.AgentEnabled {
		log.Info("Intake agent disabled (INTAKE_AGENT_ENABLED=false). Skipping.")
		return skipResult(req, "disabled"), nil
	}

	// 3. HUMAN_MODE skip — notes already triaged.
	if cfg.HumanMode {
		log.Info("Intake: skipped in --human mode (notes are pre-triaged by user).")
		setVerdictEnv("PASS", "100", false)
		return skipResult(req, "human_mode"), nil
	}

	h := newHelpers(cfg)

	// 4. Cached-run branch (dry-run).
	if cfg.Cached && fileExists(cfg.ReportFile) {
		log.Header("Pre-stage 1 — Task Intake (cached)")
		log.Info("Intake: using cached results from dry-run.")
		verdict := h.ParseVerdict(cfg.ReportFile)
		confidence := h.ParseConfidence(cfg.ReportFile)
		log.Info(fmt.Sprintf("Intake verdict: %s (confidence: %d)", verdict, confidence))
		setVerdictEnv(verdict, strconv.Itoa(confidence), false)
		// Cache still re-dispatches NEEDS_CLARITY / TWEAKED — user may have
		// resolved questions since dry-run.
		switch verdict {
		case "NEEDS_CLARITY":
			return dispatchOne(ctx, cfg, h, "NEEDS_CLARITY", confidence, req, "cached_needs_clarity", log)
		case "TWEAKED":
			return dispatchOne(ctx, cfg, h, "TWEAKED", confidence, req, "cached_tweaked", log)
		}
		return passResult(req, "cached_pass", 0), nil
	}

	// 5. Get content (before banner — silently skip if empty / unchanged).
	content, err := h.MilestoneContent(cfg.MilestoneMode, cfg.CurrentMilestone, cfg.Task)
	if err != nil {
		log.Warn(fmt.Sprintf("Intake: milestone content read failed: %v", err))
	}
	if content == "" {
		log.Info("Intake: no content to evaluate. Passing.")
		return skipResult(req, "no_content"), nil
	}

	hash := h.ContentHash(content)
	if h.ShouldSkip(hash) {
		log.Info("Intake: content unchanged since last evaluation. Skipping.")
		return skipResult(req, "unchanged"), nil
	}

	// 6. Banner + render prompt.
	log.Header("Pre-stage 1 — Task Intake")

	promptVars := buildPromptVars(ctx, cfg, content)

	promptText, err := prompt.Render(cfg.PromptsDir, "intake_scan", promptVars)
	if err != nil {
		log.Warn(fmt.Sprintf("Intake: render prompt failed: %v", err))
		return skipResult(req, "render_failed"), nil
	}

	// 7. Invoke agent.
	log.Info(fmt.Sprintf("Running intake evaluation (model: %s, turns: %d)...",
		cfg.Model, cfg.MaxTurns))

	if _, agentErr := cfg.Provider.RunAgent(ctx, &provider.Request{
		Prompt:     promptText,
		Label:      "Intake",
		Model:      cfg.Model,
		MaxTurns:   cfg.MaxTurns,
		WorkingDir: cfg.ProjectDir,
	}); agentErr != nil {
		log.Warn(fmt.Sprintf("Intake agent failed: %v", agentErr))
		// Best-effort: continue to parse whatever report exists.
	}

	// 8. Parse verdict + save hash.
	verdict := h.ParseVerdict(cfg.ReportFile)
	confidence := h.ParseConfidence(cfg.ReportFile)
	log.Info(fmt.Sprintf("Intake verdict: %s (confidence: %d)", verdict, confidence))
	if err := h.SaveHash(hash); err != nil {
		log.Warn(fmt.Sprintf("Intake: save hash failed: %v", err))
	}

	// 9. Dispatch + emit exports + result.
	return dispatchOne(ctx, cfg, h, verdict, confidence, req, "complete", log)
}

// dispatchOne routes the verdict to the appropriate handler, exports the
// verdict env vars, and returns a stage result. The `_INTAKE_PASS_EMIT`
// flag is set ONLY on the PASS dispatch path (NOT on the skip-paths that
// short-circuit before this point).
func dispatchOne(ctx context.Context, cfg config, h *pkgintake.Helpers,
	verdict string, confidence int, req *proto.StageRequestV1,
	successReason string, log staglog.Logger,
) (*proto.StageResultV1, error) {
	confStr := strconv.Itoa(confidence)

	switch verdict {
	case "PASS":
		// M118: defer the success line to the caller. Set the flag so the
		// downstream pipeline knows to emit the success line AFTER closing
		// the TUI pill.
		setVerdictEnv(verdict, confStr, true)
		return passResultWithReason(req, successReason, 1), nil

	case "TWEAKED", "SPLIT_RECOMMENDED", "NEEDS_CLARITY":
		setVerdictEnv(verdict, confStr, false)
		vh := newVerdictHandler(cfg, h)
		err := dispatchVerdictHandler(ctx, vh, verdict, cfg.ReportFile)
		if errors.Is(err, pkgintake.ErrHalt) {
			log.Warn(fmt.Sprintf("Intake: halt requested (verdict=%s).", verdict))
			return blockResult(req, verdictExitReason(verdict), 1), nil
		}
		if err != nil {
			log.Warn(fmt.Sprintf("Intake: verdict handler failed: %v", err))
			return passResultWithReason(req, verdictExitReason(verdict), 1), nil
		}
		return passResultWithReason(req, verdictExitReason(verdict), 1), nil

	default:
		setVerdictEnv(verdict, confStr, false)
		return passResultWithReason(req, successReason, 1), nil
	}
}

func dispatchVerdictHandler(ctx context.Context, vh *pkgintake.VerdictHandler,
	verdict, reportFile string,
) error {
	switch verdict {
	case "TWEAKED":
		return vh.HandleTweaked(ctx, reportFile)
	case "SPLIT_RECOMMENDED":
		return vh.HandleSplitRecommended(ctx, reportFile)
	case "NEEDS_CLARITY":
		return vh.HandleNeedsClarity(ctx, reportFile)
	}
	return nil
}

// cleanupSentinels removes per-run sentinel files at pipeline-start. This is
// the SOLE owner — other stages may WRITE these; nothing else CLEARS them.
func cleanupSentinels(cfg config) {
	for _, name := range []string{".final_check_result", ".commit_decision"} {
		p := filepath.Join(cfg.ProjectDir, cfg.TekhtonDir, name)
		_ = os.Remove(p)
	}
}

// setVerdictEnv exports INTAKE_VERDICT, INTAKE_CONFIDENCE, and (only on
// the PASS dispatch path) _INTAKE_PASS_EMIT. Skip-paths set verdict but
// explicitly leave _INTAKE_PASS_EMIT unset — see Watch For in m36.3.
//
// When TEKHTON_INTAKE_ENV_OUT is set (the bash shim wires this so it can
// source the result back into the parent shell), the values are also
// written to that path as a sourceable bash file. The emit-pass flag is
// emitted as an `export` only when emitPass is true; on skip paths the
// file contains an `unset _INTAKE_PASS_EMIT` so re-sourcing across
// multiple stages can't leak stale state.
func setVerdictEnv(verdict, confidence string, emitPass bool) {
	_ = os.Setenv("INTAKE_VERDICT", verdict)
	_ = os.Setenv("INTAKE_CONFIDENCE", confidence)
	if emitPass {
		_ = os.Setenv("_INTAKE_PASS_EMIT", "true")
	} else {
		_ = os.Unsetenv("_INTAKE_PASS_EMIT")
	}
	writeEnvSidecar(verdict, confidence, emitPass)
}

// writeEnvSidecar drops a sourceable bash file at TEKHTON_INTAKE_ENV_OUT
// so the bash shim can read the verdict exports back across the
// subprocess boundary. No-op when the env var is unset (in-process
// callers reach the same state via the os.Setenv side effect above).
func writeEnvSidecar(verdict, confidence string, emitPass bool) {
	out := os.Getenv("TEKHTON_INTAKE_ENV_OUT")
	if out == "" {
		return
	}
	body := "export INTAKE_VERDICT=" + shellQuote(verdict) + "\n" +
		"export INTAKE_CONFIDENCE=" + shellQuote(confidence) + "\n"
	if emitPass {
		body += "export _INTAKE_PASS_EMIT=true\n"
	} else {
		body += "unset _INTAKE_PASS_EMIT\n"
	}
	_ = os.WriteFile(out, []byte(body), 0o644)
}

// shellQuote returns s wrapped in single quotes with embedded single quotes
// escaped via the standard `'\”` dance. Safe for sourceable bash files.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// verdictExitReason maps a verdict to the exit_reason string carried on the
// stage result envelope. Distinct from the verdict so downstream consumers
// (causal log, metrics) can read the routing decision.
func verdictExitReason(verdict string) string {
	switch verdict {
	case "PASS":
		return "pass"
	case "TWEAKED":
		return "tweaked"
	case "SPLIT_RECOMMENDED":
		return "split_recommended"
	case "NEEDS_CLARITY":
		return "needs_clarity"
	}
	return "complete"
}

// skipResult returns a verdict=skip result.
func skipResult(req *proto.StageRequestV1, reason string) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictSkip,
		ExitReason: reason,
	}
}

func passResult(req *proto.StageRequestV1, reason string, agentCalls int) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: reason,
		AgentCalls: agentCalls,
	}
}

// passResultWithReason wraps passResult so the dispatch site stays one-liner.
func passResultWithReason(req *proto.StageRequestV1, reason string, agentCalls int) *proto.StageResultV1 {
	return passResult(req, reason, agentCalls)
}

// blockResult returns a verdict=block result with HumanAction=true.
func blockResult(req *proto.StageRequestV1, reason string, agentCalls int) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictBlock,
		ExitReason:  reason,
		AgentCalls:  agentCalls,
		HumanAction: true,
	}
}
