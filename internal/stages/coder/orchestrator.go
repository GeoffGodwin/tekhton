package coder

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/coder/buildfix"
	"github.com/geoffgodwin/tekhton/internal/coder/scout"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// orchestrator owns the run_stage_coder body. Construction goes through
// newOrchestrator so the Config snapshot, sub-package configs, and Deps are
// resolved in one place.
type orchestrator struct {
	req  *proto.StageRequestV1
	cfg  Config
	log  staglog.Logger
	deps *Deps
}

// newOrchestrator constructs an orchestrator from the stage request. The
// production path resolves Config from env; tests inject a custom cfg via
// (*orchestrator).withConfig before calling Run.
func newOrchestrator(req *proto.StageRequestV1) *orchestrator {
	if req == nil {
		req = &proto.StageRequestV1{}
	}
	cfg := loadConfigFromEnv()
	if cfg.CurrentMilestone == "" {
		cfg.CurrentMilestone = req.Milestone
	}
	return &orchestrator{
		req:  req,
		cfg:  cfg,
		log:  staglog.New(req),
		deps: DefaultDeps(),
	}
}

// withConfig replaces the resolved Config. Test-only seam — production
// callers go through newOrchestrator + env.
func (o *orchestrator) withConfig(cfg Config) *orchestrator {
	o.cfg = cfg
	return o
}

// withDeps replaces the dependency injection seam. Test-only.
func (o *orchestrator) withDeps(d *Deps) *orchestrator {
	if d != nil {
		o.deps = d
	}
	return o
}

// Run executes the 15-step coder stage body. Steps map 1:1 to private methods
// so unit tests can drive sub-paths in isolation (verified by the
// `^func \(o \*orchestrator\)` grep predicate in the milestone's acceptance
// criteria).
//
//	 1. stageHeader        — print "[pos/count] Coder"
//	 2. resetBuildFixStats — write BUILD_FIX_* defaults so M132 sees a stable shape
//	 3. runPrerun          — prerun.Run wrapper (m39.1)
//	 4. decideScout        — should-scout predicate
//	 5. runScout           — scout.Run wrapper (m39.3)
//	 6. populateMilestone  — set_focused_milestone_block subprocess
//	 7. buildContextBlocks — 14 context blocks (context_blocks.go)
//	 8. selectTemplate     — selectCoderTemplate tag dispatch
//	 9. invokeCoderAgent   — render + RunAgent
//	10. validatePostCoder  — is_substantive_work + summary-file checks
//	11. handleNullRun      — null-run / turn-exhaustion / continuation escalation
//	12. postClarification  — tekhton clarify CLI integration
//	13. runContinuation    — M14 CONTINUATION_ENABLED loop
//	14. runCompletionGate  — completion gate + is_substantive_work fallback
//	15. runBuildGate       — build gate + buildfix.Run on failure
func (o *orchestrator) Run(ctx context.Context) (*proto.StageResultV1, error) {
	o.stageHeader()
	o.resetBuildFixStats()

	if err := o.runPrerun(ctx); err != nil {
		// Non-fatal — prerun warnings degrade gracefully; the stricter
		// post-run gates surface real breakage.
		o.warn("[coder/prerun] %v", err)
	}

	scoutDecision := o.decideScout()
	if scoutDecision {
		if _, err := o.runScout(ctx); err != nil {
			o.warn("[coder/scout] %v", err)
		}
	}

	o.populateMilestone(ctx)
	blocks := o.buildContextBlocks(ctx)
	tmpl := o.selectTemplate()

	if err := o.invokeCoderAgent(ctx, tmpl, blocks); err != nil {
		if errors.Is(err, errUpstream) {
			return o.upstreamResult(err), nil
		}
		o.warn("[coder] agent error: %v", err)
	}

	postState := o.validatePostCoder(ctx)
	if postState.escalate {
		res, err := o.handleNullRun(ctx, postState)
		if res != nil {
			return res, err
		}
	}

	if err := o.postClarification(ctx); err != nil {
		o.warn("[coder] clarification: %v", err)
	}

	if o.statusIs("IN PROGRESS") {
		if err := o.runContinuation(ctx); err != nil {
			if errors.Is(err, errUpstream) {
				return o.upstreamResult(err), nil
			}
			o.warn("[coder/continuation] %v", err)
		}
	}

	if ok, err := o.runCompletionGate(ctx); !ok {
		if err != nil {
			o.warn("[coder/completion] %v", err)
		}
	}

	if err := o.runBuildGate(ctx); err != nil {
		o.warn("[coder/build] %v", err)
	}

	o.recordTaskFileAssociation(ctx)
	return o.passResult(), nil
}

// stageHeader — Step 1. Prints the "[pos/count] Coder" banner.
func (o *orchestrator) stageHeader() {
	o.log.Header("Coder")
}

// resetBuildFixStats — Step 2. Writes BUILD_FIX_* defaults so M132's
// _collect_build_fix_stats_json sees a stable shape on every exit path.
func (o *orchestrator) resetBuildFixStats() {
	_ = os.Setenv("BUILD_FIX_ATTEMPTS", "0")
	_ = os.Setenv("BUILD_FIX_TURN_BUDGET_USED", "0")
	_ = os.Setenv("BUILD_FIX_PROGRESS_GATE_FAILURES", "0")
	_ = os.Setenv("BUILD_FIX_OUTCOME", string(buildfix.OutcomeNotRun))
}

// runPrerun — Step 3. Delegates to prerun.Run. Errors are non-fatal — the
// caller logs and proceeds.
func (o *orchestrator) runPrerun(ctx context.Context) error {
	if o.deps.PrerunRun == nil {
		return nil
	}
	res, err := o.deps.PrerunRun(ctx, o.cfg.PrerunConfig)
	if err != nil {
		return err
	}
	if res != nil {
		o.info("[coder/prerun] status=%s attempts=%d", res.Status, res.Attempts)
	}
	return nil
}

// decideScout — Step 4. The ShouldScout predicate against the env snapshot.
func (o *orchestrator) decideScout() bool {
	in := scout.ShouldScoutInput{
		NotesFilter:         o.cfg.NotesFilter,
		ScoutOnBug:          os.Getenv("SCOUT_ON_BUG"),
		ScoutOnFeat:         os.Getenv("SCOUT_ON_FEAT"),
		ScoutOnPolish:       os.Getenv("SCOUT_ON_POLISH"),
		DynamicTurnsEnabled: envBool("DYNAMIC_TURNS_ENABLED", true),
		HumanNoteCount:      envOrInt("HUMAN_NOTE_COUNT", 0),
		NotesShouldClaim:    envBool("NOTES_SHOULD_CLAIM", false),
		EstimatedTurns:      envOrInt("ESTIMATED_TURNS", 0),
		Task:                o.req.Task,
		ScoutCached:         envBool("SCOUT_CACHED", false),
	}
	return scout.ShouldScout(in)
}

// runScout — Step 5. Delegates to scout.Run and applies the result to the
// orchestrator's adjusted-turn estimate.
func (o *orchestrator) runScout(ctx context.Context) (*scout.Result, error) {
	if o.deps.ScoutRun == nil {
		return nil, nil
	}
	return o.deps.ScoutRun(ctx, o.cfg.ScoutConfig)
}

// populateMilestone — Step 6. Calls `tekhton manifest get` (or the legacy
// set_focused_milestone_block shim) to populate MILESTONE_BLOCK. Best-effort —
// failures degrade to the downstream hollow-run gates.
func (o *orchestrator) populateMilestone(_ context.Context) {
	if o.deps.PopulateMilestoneBlock == nil {
		return
	}
	if err := o.deps.PopulateMilestoneBlock(o.cfg.CurrentMilestone); err != nil {
		o.warn("[coder] MILESTONE_BLOCK could not be populated for %s: %v",
			o.cfg.CurrentMilestone, err)
	}
}

// buildContextBlocks — Step 7. Assembles the 14 context blocks into a
// ContextBlocks value. The renderer's IF-block short-circuits handle empty
// fields, matching the bash version's silent-on-empty semantics.
func (o *orchestrator) buildContextBlocks(ctx context.Context) *ContextBlocks {
	return Build(ctx, &Env{
		ProjectDir:     o.cfg.ProjectDir,
		TekhtonHome:    o.cfg.TekhtonHome,
		StartAt:        envOr("START_AT", "coder"),
		MilestoneMode:  o.cfg.MilestoneMode,
		PipelineOrder:  o.cfg.PipelineOrder,
		FixNonblockers: envBool("FIX_NONBLOCKERS_MODE", false),
	}, o.deps)
}

// selectTemplate — Step 8. Returns the prompt template name. Tag-specific
// templates take precedence over the default "coder".
func (o *orchestrator) selectTemplate() string {
	return selectCoderTemplate(o.cfg.NotesFilter, o.cfg.NoteTemplateName)
}

// invokeCoderAgent — Step 9. Renders the prompt and dispatches the senior
// coder agent. Returns errUpstream when the agent reports an UPSTREAM error
// so the caller can short-circuit and save state.
func (o *orchestrator) invokeCoderAgent(ctx context.Context, template string, blocks *ContextBlocks) error {
	if o.deps.RunAgent == nil {
		return nil
	}
	vars := blocks.AsTemplateVars()
	prompt := ""
	if o.deps.RenderPrompt != nil {
		p, err := o.deps.RenderPrompt(template, vars)
		if err != nil {
			return fmt.Errorf("render prompt %s: %w", template, err)
		}
		prompt = p
	}
	req := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        "Coder",
		Model:        o.cfg.CoderModel,
		MaxTurns:     o.cfg.effectiveCoderTurns(),
		PromptFile:   prompt,
		AllowedTools: o.cfg.AgentToolsCoder,
	}
	res, err := o.deps.RunAgent(ctx, req)
	if err != nil {
		return err
	}
	if res != nil && res.ErrorCategory == "UPSTREAM" {
		return fmt.Errorf("%w: %s", errUpstream, res.ErrorMessage)
	}
	return nil
}

// validatePostCoder — Step 10. Inspects post-agent state and returns a
// postCoderState that names the escalation path (if any).
func (o *orchestrator) validatePostCoder(_ context.Context) postCoderState {
	summaryPath := o.summaryPath()
	exists := fileExists(summaryPath)
	substantive := o.isSubstantiveWork()

	switch {
	case o.wasNullRun():
		return postCoderState{escalate: true, kind: EscalationNullRun}
	case !exists && substantive:
		// Reconstruct + trip commit gate (handled by handleNullRun).
		return postCoderState{escalate: true, kind: EscalationMissingButSubstantive}
	case !exists && !substantive:
		return postCoderState{escalate: true, kind: EscalationTurnExhaustion}
	}
	return postCoderState{}
}

// handleNullRun — Step 11. Dispatches to the null-run handler, which owns the
// 3 escalation paths.
func (o *orchestrator) handleNullRun(ctx context.Context, state postCoderState) (*proto.StageResultV1, error) {
	h := newNullRunHandler(o)
	res, err := h.Handle(ctx, state.kind, EscalationInfo{
		Milestone: o.cfg.CurrentMilestone,
	})
	if err != nil {
		return o.failResult("null_run", err.Error()), err
	}
	if res.ShouldRetry {
		// Recurse into the orchestrator's Run; bounded by MaxSplitDepth.
		return o.Run(ctx)
	}
	if res.ShouldExit {
		return o.failResult(res.ExitReason, res.StateNotes), nil
	}
	// Reconstruction path — proceed to review.
	return nil, nil
}

// postClarification — Step 12. Drives the m25 `tekhton clarify` CLI to detect
// and handle blocking clarification items the coder wrote into the summary.
// Best-effort; failures degrade to the next stage.
func (o *orchestrator) postClarification(ctx context.Context) error {
	if o.deps.ClarifyDetect == nil {
		return nil
	}
	if !o.deps.ClarifyDetect(ctx, o.summaryPath()) {
		return nil
	}
	if o.deps.ClarifyHandle == nil {
		return nil
	}
	if err := o.deps.ClarifyHandle(ctx, o.summaryPath(), o.cfg.ProjectDir); err != nil {
		return err
	}
	// Re-invoke the coder with the clarification answers in context.
	tmpl := selectCoderTemplate(o.cfg.NotesFilter, "")
	return o.invokeCoderAgent(ctx, tmpl, o.buildContextBlocks(ctx))
}

// runContinuation — Step 13. Drives the M14 CONTINUATION_ENABLED loop when
// the post-coder summary status is IN PROGRESS AND substantive work exists.
func (o *orchestrator) runContinuation(ctx context.Context) error {
	if !o.cfg.ContinuationEnabled {
		return nil
	}
	if !o.isSubstantiveWork() {
		return nil
	}
	cfg := &ContinuationConfig{
		Enabled:     o.cfg.ContinuationEnabled,
		MaxAttempts: o.cfg.MaxContinuationAttempts,
		Budget:      o.cfg.effectiveCoderTurns(),
		Template:    "coder",
		Model:       o.cfg.CoderModel,
		AgentTools:  o.cfg.AgentToolsCoder,
	}
	res, err := RunContinuation(ctx, cfg, o.deps)
	if err != nil {
		return err
	}
	if res != nil && res.Outcome == OutcomeUpstreamError {
		return errUpstream
	}
	return nil
}

// runCompletionGate — Step 14. Calls the completion gate via the subprocess
// shim. Returns (false, nil) when the gate fails but substantive work exists
// — the orchestrator falls through to the build gate in that case.
func (o *orchestrator) runCompletionGate(ctx context.Context) (bool, error) {
	if o.deps.RunCompletionGate == nil {
		return true, nil
	}
	if err := o.deps.RunCompletionGate(ctx); err == nil {
		return true, nil
	}
	if o.isSubstantiveWork() {
		if !fileExists(o.summaryPath()) {
			_ = o.reconstructSummary("COMPLETE")
		}
		if o.deps.TripCommitGate != nil {
			o.deps.TripCommitGate("completion_gate_failed_substantive_work_only")
		}
		return false, nil
	}
	if !fileExists(o.summaryPath()) {
		_ = o.reconstructSummary("INCOMPLETE")
	}
	return false, fmt.Errorf("completion gate failed; no substantive work")
}

// runBuildGate — Step 15. Calls the build gate via the subprocess shim. On
// failure, delegates to buildfix.Run.
func (o *orchestrator) runBuildGate(ctx context.Context) error {
	if o.deps.RunBuildGate == nil {
		return nil
	}
	if err := o.deps.RunBuildGate(ctx, "post-coder"); err == nil {
		return nil
	}
	if o.deps.BuildFixRun == nil {
		return nil
	}
	_, err := o.deps.BuildFixRun(ctx, o.cfg.BuildFixConfig, &buildfix.Paths{
		BuildRawErrorsFile:   envOr("BUILD_RAW_ERRORS_FILE", ".tekhton/BUILD_RAW_ERRORS.txt"),
		BuildErrorsFile:      envOr("BUILD_ERRORS_FILE", ".tekhton/BUILD_ERRORS.md"),
		BuildRoutingDiagFile: envOr("BUILD_ROUTING_DIAGNOSIS_FILE", ".tekhton/BUILD_ROUTING_DIAGNOSIS.md"),
		BuildFixReportFile:   envOr("BUILD_FIX_REPORT_FILE", ".tekhton/BUILD_FIX_REPORT.md"),
		CoderModel:           o.cfg.CoderModel,
		AgentTools:           o.cfg.AgentToolsCoder,
		LogFile:              o.cfg.LogFile,
		Task:                 o.req.Task,
	})
	return err
}

// recordTaskFileAssociation — post-stage: record the task↔file association
// for the indexer's personalized ranking.
func (o *orchestrator) recordTaskFileAssociation(ctx context.Context) {
	if o.deps.RecordTaskFileAssociation == nil {
		return
	}
	_ = o.deps.RecordTaskFileAssociation(ctx, o.req.Task, o.summaryPath())
}

// --- helpers ---

func (o *orchestrator) summaryPath() string {
	if filepath.IsAbs(o.cfg.CoderSummaryFile) {
		return o.cfg.CoderSummaryFile
	}
	return filepath.Join(o.cfg.ProjectDir, o.cfg.CoderSummaryFile)
}

func (o *orchestrator) isSubstantiveWork() bool {
	if o.deps.IsSubstantiveWork != nil {
		return o.deps.IsSubstantiveWork()
	}
	return false
}

func (o *orchestrator) wasNullRun() bool {
	if o.deps.WasNullRun != nil {
		return o.deps.WasNullRun()
	}
	return false
}

func (o *orchestrator) statusIs(needle string) bool {
	b, err := os.ReadFile(o.summaryPath())
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "## Status") && strings.Contains(line, needle) {
			return true
		}
	}
	return false
}

func (o *orchestrator) reconstructSummary(status string) error {
	return ReconstructSummary(context.Background(), o.summaryPath(), status, o.deps)
}

func (o *orchestrator) info(format string, args ...any) {
	o.log.Info(fmt.Sprintf(format, args...))
}

func (o *orchestrator) warn(format string, args ...any) {
	o.log.Warn(fmt.Sprintf(format, args...))
}

func (o *orchestrator) passResult() *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      o.req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: "complete",
	}
}

func (o *orchestrator) failResult(reason, errMsg string) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      o.req.Stage,
		Verdict:    proto.VerdictFail,
		ExitReason: reason,
		Error:      errMsg,
	}
}

func (o *orchestrator) upstreamResult(err error) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      o.req.Stage,
		Verdict:    proto.VerdictFail,
		ExitReason: "upstream_error",
		Error:      err.Error(),
	}
}

// errUpstream is the sentinel returned by invokeCoderAgent / RunContinuation
// when the agent reports an UPSTREAM error. The orchestrator short-circuits
// to upstreamResult on this path.
var errUpstream = errors.New("coder: upstream agent error")

// postCoderState captures the post-coder validation outcome.
type postCoderState struct {
	escalate bool
	kind     EscalationKind
}

// fileExists returns true when path resolves to a regular file.
func fileExists(path string) bool {
	if path == "" {
		return false
	}
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

// selectCoderTemplate ports the bash dispatch at stages/coder.sh:712. The
// tag-specific override (coder_note_bug / coder_note_feat / coder_note_polish)
// wins when set; otherwise the default "coder" template renders.
//
// Important: this function NEVER returns "coder_rework". The rework template
// is rendered inside the review stage (m37), not by the coder stage. A unit
// test asserts this invariant across the 5-row table.
func selectCoderTemplate(notesFilter, noteTemplateName string) string {
	if noteTemplateName != "" {
		return noteTemplateName
	}
	_ = notesFilter // intentionally unused — bash sets NoteTemplateName upstream
	return "coder"
}
