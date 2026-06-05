package stagerunner

import (
	"context"

	"github.com/geoffgodwin/tekhton/internal/proto"
	architectstage "github.com/geoffgodwin/tekhton/internal/stages/architect"
	"github.com/geoffgodwin/tekhton/internal/stages/cleanup"
	"github.com/geoffgodwin/tekhton/internal/stages/docs"
	intakestage "github.com/geoffgodwin/tekhton/internal/stages/intake"
	securitystage "github.com/geoffgodwin/tekhton/internal/stages/security"
)

// StageImpl is the entry-point signature every Go-native stage exports. The
// dispatcher in BashAdapter.Run prefers a non-nil StageDef.GoImpl over the
// bash Script path. Introduced in m34.1 alongside the docs-stage port; m35-m39
// stage ports reuse the same signature.
type StageImpl func(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error)

// StageDef describes how to invoke a single Tekhton stage. Helpers names the
// lib/*.sh files (relative to TekhtonHome) the stage's run_stage_<name>
// implementation calls into beyond DefaultLibHelpers. The BashAdapter sources
// DefaultLibHelpers first, then any per-stage Helpers, then lib/stage_envelope.sh,
// and finally Script before invoking run_stage_<name>.
//
// When GoImpl is non-nil (m34.1+), the dispatcher routes to it and skips the
// bash sourcing chain entirely. Script remains set on ported stages as an
// audit-trail signal — a missing-file delta from a Script that never resolves
// is how future audit tooling sees "stage ported" at a glance.
type StageDef struct {
	Script  string
	Helpers []string
	GoImpl  StageImpl
}

// DefaultLibHelpers mirrors the global lib/*.sh source block in
// tekhton-legacy.sh (lines 846-959). Stage scripts were authored to run inside
// that environment; the BashAdapter must recreate it before sourcing the stage
// script or any function call into a lib/ helper bash will print
// "command not found" and exit 127. Order is preserved from legacy because a
// few helpers depend on others being present at source-time (e.g. failure_context.sh
// must precede diagnose_output.sh).
var DefaultLibHelpers = []string{
	"lib/config.sh",
	// m24: lib/notes*.sh family (14 files) deleted — notes subsystem
	// ported to internal/notes/. The bash residue (helpers used by the
	// --human mode loop) lives in lib/human_mode_notes.sh.
	"lib/human_mode_notes.sh",
	"lib/agent.sh",
	// run_summary_reconstruct.sh provides
	// _reconstruct_run_summary_from_stage_results, called by
	// print_run_summary (in lib/agent_helpers.sh, sourced by agent.sh)
	// when in-process accumulators are zero — the V4 finalize-subprocess
	// case. Sourced after agent.sh so the helper is visible when
	// print_run_summary is invoked at any later point.
	"lib/run_summary_reconstruct.sh",
	// drift_compat.sh restores `count_open_nonblocking_notes` —
	// m25 deleted lib/drift_cleanup.sh which owned that function but
	// left six bash callers (stages/coder.sh, tekhton-legacy.sh,
	// finalize_display.sh, dashboard_emitters.sh) referencing it. The
	// shim delegates to `tekhton drift nonblocking count`. Sourced
	// here so every stage subprocess (including coder, which hit the
	// "command not found" on the M28.1 run) has the function visible
	// before the stage script runs.
	"lib/drift_compat.sh",
	// gates_compat.sh restores `run_build_gate` + `run_completion_gate`
	// — m31 ported lib/gates*.sh to internal/gates + internal/pipeline
	// and exposed `tekhton gate build|completion`, but left six bash
	// callsites (stages/coder_buildfix.sh, stages/architect.sh,
	// stages/cleanup.sh, stages/review.sh, lib/milestone_acceptance.sh,
	// lib/stage_envelope.sh) referencing the deleted functions. The
	// orphan surfaced as a build-fix loop halting after 2 no-progress
	// attempts on the m34.1 auto-advance run when the underlying code
	// change was actually fine.
	"lib/gates_compat.sh",
	"lib/state.sh",
	"lib/dry_run.sh",
	"lib/quota.sh",
	"lib/prompts.sh",
	"lib/errors.sh",
	"lib/remediation.sh",
	// m22: preflight subsystem ported to internal/preflight; six bash files
	// deleted. The legacy `run_preflight_checks` function in
	// tekhton-legacy.sh now execs `tekhton preflight` directly.
	// m31.1: lib/gates.sh + lib/gates_phases.sh + lib/gates_completion.sh
	// ported to internal/gates/. The shims that replace `run_build_gate`
	// and `run_completion_gate` live inline in tekhton-legacy.sh and exec
	// `tekhton gate {build,completion}`.
	// m31.2: lib/gates_ui.sh + lib/gates_ui_helpers.sh ported to
	// internal/gates/ui.go + ui_helpers.go. Five gates*.sh files now zero.
	"lib/test_dedup.sh",
	"lib/ui_validate.sh",
	"lib/ui_validate_report.sh",
	"lib/hooks.sh",
	"lib/hooks_final_checks.sh",
	// m24: markdown_helpers.sh holds the previously notes-prefixed
	// _normalize_markdown_blank_runs.
	"lib/markdown_helpers.sh",
	// m25: lib/drift*.sh (4 files) deleted; ported to internal/drift/.
	// Bash callers reach the Go subsystem via `tekhton drift <sub>`.
	"lib/turns.sh",
	"lib/context.sh",
	"lib/context_compiler.sh",
	"lib/milestones.sh",
	"lib/milestone_dag.sh",
	"lib/milestone_query.sh",
	"lib/milestone_ops.sh",
	"lib/milestone_acceptance_lint.sh",
	"lib/milestone_split.sh",
	"lib/milestone_window.sh",
	"lib/draft_milestones.sh",
	"lib/milestone_progress_helpers.sh",
	"lib/milestone_progress.sh",
	"lib/context_cache.sh",
	"lib/indexer.sh",
	"lib/indexer_audit.sh",
	"lib/indexer_helpers.sh",
	"lib/indexer_cache.sh",
	"lib/indexer_history.sh",
	"lib/mcp.sh",
	// m25: lib/clarify.sh deleted; ported to internal/clarify/.
	// Bash stages reach the Go subsystem via `tekhton clarify <sub>`.
	"lib/replan.sh",
	// m29.2: lib/detect*.sh (ten files) deleted; ported to internal/detect/.
	// Bash stages reach the Go subsystem via `_tk_detect_*` wrappers from
	// lib/common_detect.sh (sourced from common.sh).
	"platforms/_base.sh",
	// m30.1: lib/crawler*.sh (six files) deleted; ported to internal/crawler/.
	// Bash callers reach the Go crawler via `tekhton crawler crawl`.
	// lib/rescan_helpers.sh deleted alongside — rescan.sh now delegates
	// to the Go binary until m30.2 ports the incremental path.
	"lib/index_reader.sh",
	"lib/index_view.sh",
	"lib/specialists.sh",
	"lib/specialists_helpers.sh",
	"lib/metrics.sh",
	"lib/metrics_extended.sh",
	"lib/metrics_calibration.sh",
	"lib/metrics_dashboard.sh",
	"lib/progress.sh",
	"lib/causality.sh",
	"lib/causality_query.sh",
	// m33.1: lib/dashboard.sh + lib/dashboard_emitters.sh deleted (dashboard
	// emitter subsystem ported to internal/dashboard/). The compatibility shim
	// at lib/dashboard_shim.sh provides the legacy function names (init_dashboard,
	// emit_dashboard_*) that exec `tekhton dashboard <subcommand>`.
	"lib/dashboard_shim.sh",
	// m23: lib/tui.sh deleted (TUI writer subsystem ported to internal/tui/).
	// The remaining bash residue (Python sidecar lifecycle + _tui_call) lives
	// in lib/sidecar_lifecycle.sh, sourced transitively from lib/output.sh —
	// which is itself sourced from lib/common.sh by the BashAdapter entry
	// point, so it is not listed here.
	"lib/inbox.sh",
	"lib/report.sh",
	// m25: lib/failure_context.sh deleted; slot helpers ported to
	// internal/failure_context/. Bash diagnose writer falls back to
	// defensive `command -v` checks when the helpers are absent.
	"lib/diagnose.sh",
	"lib/health.sh",
	"lib/validate_config.sh",
	"lib/update_check.sh",
	"lib/migrate.sh",
	"lib/migrate_cli.sh",
	"lib/checkpoint.sh",
	"lib/checkpoint_display.sh",
	"lib/pipeline_order.sh",
	"lib/express.sh",
	"lib/express_persist.sh",
	"lib/project_version.sh",
	"lib/project_version_bump.sh",
	"lib/project_version_bump_helpers.sh",
	"lib/project_version_verify.sh",
	"lib/finalize.sh",
	"lib/milestone_metadata.sh",
	"lib/orchestrate.sh",
}

// DefaultStageDefs is the canonical name → definition mapping. Helpers lists
// stage-specific lib/*.sh files beyond DefaultLibHelpers. For stages with a
// non-empty Helpers list (intake, security, tester, docs) those files are
// functionally required: the stage scripts call functions defined in them
// (e.g. _intake_get_milestone_content from lib/intake_helpers.sh) and the
// subprocess will exit 127 if they are not sourced. Stages with empty
// Helpers (coder, review, cleanup) run entirely off DefaultLibHelpers.
var DefaultStageDefs = map[string]StageDef{
	// m36.3: intake is the fifth Go-native stage. GoImpl takes the
	// dispatch; Script and Helpers are dropped because the bash files
	// (stages/intake.sh + lib/intake_helpers.sh + lib/intake_verdict_handlers.sh)
	// are deleted in the same milestone. The verdict-handler dependencies
	// (clarify, manifest split) reach back into bash via the operator CLI
	// when invoked; a follow-up milestone may replace those seams in-process.
	proto.StageIntake: {
		GoImpl: intakestage.RunStage,
	},
	proto.StageCoder: {
		Script: "stages/coder.sh",
	},
	// m35.2: security is the third Go-native stage (after docs in m34.1 and
	// cleanup in m34.2). GoImpl takes the dispatch; Script and Helpers are
	// dropped because the bash files (stages/security.sh +
	// lib/security_helpers.sh) are deleted in the same milestone.
	proto.StageSecurity: {
		GoImpl: securitystage.RunStage,
	},
	proto.StageReview: {
		Script:  "stages/review.sh",
		Helpers: []string{"stages/review_helpers.sh"},
	},
	proto.StageTester: {
		Script: "stages/tester.sh",
		Helpers: []string{
			"lib/test_audit_helpers.sh",
			"lib/test_audit_detection.sh",
			"lib/test_audit_verdict.sh",
			"lib/test_audit.sh",
			"lib/test_audit_symbols.sh",
			"lib/test_audit_sampler.sh",
		},
	},
	// m34.2: cleanup is the second Go-native stage (after docs in m34.1).
	// Script stays set as the audit-trail signal — the dispatcher prefers
	// GoImpl and never resolves the script path. Helpers is empty because
	// cleanup never had per-stage bash helpers.
	proto.StageCleanup: {
		Script: "stages/cleanup.sh",
		GoImpl: cleanup.RunStage,
	},
	// m34.1: docs is the first Go-native stage. Script stays set as an
	// audit-trail signal (m34 parent Goal 5) — the dispatcher prefers
	// GoImpl and never resolves the script path. Helpers is intentionally
	// empty: lib/docs_agent.sh was deleted alongside the port.
	proto.StageDocs: {
		Script: "stages/docs.sh",
		GoImpl: docs.RunStage,
	},
	// m36.1: architect is the fourth Go-native stage. GoImpl takes the
	// dispatch; Script and Helpers are dropped because the bash file
	// (stages/architect.sh) is deleted in the same milestone. The
	// pre-stage gate (drift threshold + --force-audit) stays in the bash
	// dispatcher (tekhton-legacy.sh) — architect.RunStage assumes the
	// dispatcher already decided. The four prompt templates
	// (prompts/architect*.prompt.md) are untouched per the milestone
	// Watch For block.
	proto.StageArchitect: {
		GoImpl: architectstage.RunStage,
	},
}
