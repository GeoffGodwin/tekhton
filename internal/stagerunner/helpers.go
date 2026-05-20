package stagerunner

import "github.com/geoffgodwin/tekhton/internal/proto"

// StageDef describes how to invoke a single Tekhton stage. Helpers names the
// lib/*.sh files (relative to TekhtonHome) the stage's run_stage_<name>
// implementation calls into beyond DefaultLibHelpers. The BashAdapter sources
// DefaultLibHelpers first, then any per-stage Helpers, then lib/stage_envelope.sh,
// and finally Script before invoking run_stage_<name>.
type StageDef struct {
	Script  string
	Helpers []string
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
	"lib/notes_core_normalize.sh",
	"lib/notes_core.sh",
	"lib/notes_rollback.sh",
	"lib/notes.sh",
	"lib/notes_single.sh",
	"lib/notes_triage.sh",
	"lib/notes_triage_flow.sh",
	"lib/notes_triage_report.sh",
	"lib/notes_cleanup.sh",
	"lib/notes_cli.sh",
	"lib/notes_cli_write.sh",
	"lib/notes_migrate.sh",
	"lib/notes_acceptance.sh",
	"lib/notes_acceptance_helpers.sh",
	"lib/agent.sh",
	"lib/state.sh",
	"lib/dry_run.sh",
	"lib/quota.sh",
	"lib/prompts.sh",
	"lib/errors.sh",
	"lib/remediation.sh",
	// m22: preflight subsystem ported to internal/preflight; six bash files
	// deleted. The legacy `run_preflight_checks` function in
	// tekhton-legacy.sh now execs `tekhton preflight` directly.
	"lib/gates.sh",
	"lib/gates_phases.sh",
	"lib/gates_ui_helpers.sh",
	"lib/gates_ui.sh",
	"lib/gates_completion.sh",
	"lib/test_dedup.sh",
	"lib/ui_validate.sh",
	"lib/ui_validate_report.sh",
	"lib/hooks.sh",
	"lib/hooks_final_checks.sh",
	"lib/drift.sh",
	"lib/drift_cleanup.sh",
	"lib/drift_prune.sh",
	"lib/drift_artifacts.sh",
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
	"lib/clarify.sh",
	"lib/replan.sh",
	"lib/detect.sh",
	"lib/detect_commands.sh",
	"lib/detect_report.sh",
	"lib/detect_workspaces.sh",
	"lib/detect_services.sh",
	"lib/detect_ci.sh",
	"lib/detect_infrastructure.sh",
	"lib/detect_test_frameworks.sh",
	"lib/detect_doc_quality.sh",
	"platforms/_base.sh",
	"lib/crawler.sh",
	"lib/index_reader.sh",
	"lib/index_view.sh",
	"lib/rescan_helpers.sh",
	"lib/specialists.sh",
	"lib/specialists_helpers.sh",
	"lib/metrics.sh",
	"lib/metrics_extended.sh",
	"lib/metrics_calibration.sh",
	"lib/metrics_dashboard.sh",
	"lib/progress.sh",
	"lib/causality.sh",
	"lib/causality_query.sh",
	"lib/dashboard.sh",
	"lib/tui.sh",
	"lib/inbox.sh",
	"lib/report.sh",
	"lib/failure_context.sh",
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
	proto.StageIntake: {
		Script: "stages/intake.sh",
		Helpers: []string{
			"lib/intake_helpers.sh",
			"lib/intake_verdict_handlers.sh",
		},
	},
	proto.StageCoder: {
		Script: "stages/coder.sh",
	},
	proto.StageSecurity: {
		Script:  "stages/security.sh",
		Helpers: []string{"lib/security_helpers.sh"},
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
	proto.StageCleanup: {
		Script: "stages/cleanup.sh",
	},
	proto.StageDocs: {
		Script:  "stages/docs.sh",
		Helpers: []string{"lib/docs_agent.sh"},
	},
}
