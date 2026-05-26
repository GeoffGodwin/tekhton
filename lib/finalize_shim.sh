#!/usr/bin/env bash
# =============================================================================
# finalize_shim.sh — m21 single-hook bash dispatcher.
#
# Invoked by internal/finalize.BashShimHook (one process per hook). Sources
# the bash files that own the named hook, then calls it with the pipeline
# exit code passed via PIPELINE_EXIT_CODE.
#
# Usage:  bash lib/finalize_shim.sh _hook_resolve_notes
#
# Environment expected (set by the Go orchestrator):
#   TEKHTON_HOME           — absolute path to the tekhton repo
#   PROJECT_DIR            — absolute path to the target project
#   PIPELINE_EXIT_CODE     — 0 on success; non-zero on failure
#   TEKHTON_RUN_DISPOSITION — success | failure | stuck | timeout | agent_cap
#   TEKHTON_RUN_RESULT_FILE — path to RUN_RESULT.json (optional)
#   LOG_DIR                — log directory for the current run (optional)
#   TIMESTAMP              — YYYYMMDD_HHMMSS run timestamp (optional)
#   _CURRENT_MILESTONE     — active milestone id (optional)
#   MILESTONE_MODE         — true when --milestone (optional)
#   _CACHED_DISPOSITION    — milestone disposition (optional)
#
# Follow-up milestones (m22..m25) replace one case at a time with a pure-Go
# hook in internal/finalize/. When a case is deleted here AND a Go body
# lands, that milestone has finished porting that hook. When the case list
# is empty, this file deletes.
# =============================================================================
set -euo pipefail

HOOK_NAME="${1:?finalize_shim: hook name required}"
TEKHTON_HOME="${TEKHTON_HOME:?finalize_shim: TEKHTON_HOME required}"

if [[ ! -d "${TEKHTON_HOME}/lib" ]]; then
    echo "finalize_shim: lib/ not found under TEKHTON_HOME=${TEKHTON_HOME}" >&2
    exit 1
fi

# Common base: every hook needs log/warn/success helpers + the hook
# function bodies that live in finalize.sh + its satellites.
_shim_load_common() {
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
}

_shim_load_finalize_bodies() {
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/finalize_display.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/finalize.sh"
    # m24: lib/finalize_aux.sh deleted — its four hooks
    # (express_persist / note_acceptance / baseline_cleanup /
    # failure_context_reset) all ported to internal/finalize/.
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/finalize_commit.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/finalize_dashboard_hooks.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/finalize_version.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/changelog.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/hooks.sh"
}

# Subsystem sources per hook. Each case loads exactly what the named hook
# needs to function. Keep this list mechanical: one case per hook, sources
# in the same order tekhton-legacy.sh would have loaded them.
_shim_load_common

case "$HOOK_NAME" in
    # m24: baseline_cleanup / express_persist / note_acceptance /
    # failure_context_reset ported to Go. internal/finalize/{baseline_cleanup,
    # express_persist,note_acceptance,failure_context_reset}.go own the
    # hook bodies; the notes-side logic is pure Go and the residual
    # cross-subsystem work (express_persist, test_baseline, failure_context)
    # is delegated by the Go hook to a narrow `bash -c "source X.sh; FN"`
    # so this shim case arm is no longer reachable.
    _hook_final_checks)
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/hooks_final_checks.sh"
        # hooks_final_checks.sh's run_final_checks expects four externals
        # that the V3 in-process pipeline always had loaded:
        #   - print_run_summary  → lib/agent_helpers.sh
        #   - render_prompt      → lib/prompts.sh (build-fix template)
        #   - run_agent          → lib/agent.sh   (test-fix agent spawn)
        #   - AGENT_TOOLS_BUILD_FIX → lib/agent_shim.sh exports it
        # Sourcing lib/agent.sh transitively brings agent_shim + helpers;
        # lib/prompts.sh stays explicit because nothing else in the chain
        # would re-source it.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/agent.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/prompts.sh"
        _shim_load_finalize_bodies
        ;;
    # m25: _hook_drift_artifacts ported to Go
    # (internal/finalize/drift_artifacts.go). The drift bash files
    # delete in m25; the shim no longer matches the hook name.
    _hook_record_metrics)
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/metrics.sh"
        # metrics.sh:record_run_metrics → _collect_extended_stage_vars,
        # _sanitize_numeric (defined in lib/metrics_extended.sh). Without
        # this the hook prints "command not found" to stderr on every run.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/metrics_extended.sh"
        _shim_load_finalize_bodies
        ;;
    # m24: cleanup_resolved + resolve_notes ported to Go. See
    # internal/finalize/{cleanup_resolved,resolve_notes}.go.
    _hook_health_reassess)
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/health.sh"
        _shim_load_finalize_bodies
        ;;
    _hook_failure_context)
        # m25: lib/failure_context.sh ported to internal/failure_context;
        # bash diagnose writer degrades gracefully when slot helpers are
        # absent.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/diagnose.sh"
        _shim_load_finalize_bodies
        ;;
    _hook_project_version_bump|_hook_project_version_tag)
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/project_version.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/project_version_bump.sh"
        _shim_load_finalize_bodies
        ;;
    _hook_changelog_append)
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/changelog.sh"
        _shim_load_finalize_bodies
        ;;
    _hook_commit)
        # finalize_commit_prompt.sh provides _prompt_commit_choice. Sourced
        # before hooks.sh so the helper is defined when _hook_commit's
        # body (in lib/finalize_commit.sh, loaded by _shim_load_finalize_bodies
        # below) calls it. Without this source the prompt falls back to
        # the inline read which has the M25 autoskip-on-empty regression.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/finalize_commit_prompt.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/hooks.sh"
        # hooks.sh:117/185 calls get_milestone_commit_prefix /
        # get_milestone_commit_body; both live in milestone_ops.sh.
        # Without this source the commit hook trips "command not found"
        # whenever MILESTONE_MODE=true.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/milestone_ops.sh"
        # hooks.sh:generate_commit_message also calls get_milestone_title
        # (lib/milestone_query.sh) when TASK is empty, so the commit subject
        # falls back to the milestone title instead of just "feat:".
        # get_milestone_title delegates to dag_get_title when has_milestone_manifest
        # is defined; otherwise it falls through to inline CLAUDE.md mode, which
        # has been deprecated since the V3→V4 manifest port and returns empty.
        # Sourcing milestone_dag.sh (transitively brings milestone_dag_io.sh)
        # gives the function the DAG accessors it needs.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/milestone_dag.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/milestone_query.sh"
        # finalize_commit.sh calls print_run_summary after a successful
        # commit (lines 148 + 166). Sourcing agent.sh transitively brings
        # agent_helpers.sh where that function is defined; without it the
        # hook exits 127 and the run-summary line never prints.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/agent.sh"
        # run_summary_reconstruct.sh provides the reconstruct helper that
        # print_run_summary calls when TOTAL_TURNS/TOTAL_TIME are zero
        # (the finalize-subprocess case — bash globals from the V3
        # in-process pipeline don't propagate across the stagerunner
        # subprocess boundary). Without this source the final Run Summary
        # prints "Total turns: 0, Total time: 0m0s" instead of cumulative
        # totals reconstructed from .tekhton/stage_results/.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/run_summary_reconstruct.sh"
        _shim_load_finalize_bodies
        ;;
    _hook_update_check)
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/update_check.sh"
        _shim_load_finalize_bodies
        ;;
    _hook_final_dashboard_status)
        # m23: _hook_tui_complete removed from this arm — ported to Go
        # (internal/finalize/tui_complete.go). Dashboard arm stays; it
        # ports in m26 alongside the dashboard subsystem.
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/dashboard.sh"
        _shim_load_finalize_bodies
        ;;
    *)
        echo "finalize_shim: unknown hook ${HOOK_NAME}" >&2
        exit 1
        ;;
esac

if ! declare -f "$HOOK_NAME" >/dev/null 2>&1; then
    echo "finalize_shim: hook function ${HOOK_NAME} not loaded" >&2
    exit 1
fi

"$HOOK_NAME" "${PIPELINE_EXIT_CODE:-0}"
