#!/usr/bin/env bash
# =============================================================================
# finalize_dashboard_hooks.sh — Dashboard, causal-log, diagnosis, TUI, and
# update-check finalize hooks.
#
# Sourced by lib/finalize.sh — do not run directly. Hooks are small,
# idempotent wrappers around optional subsystems (causal log, dashboard,
# health, TUI) that may or may not be loaded depending on config.
#
# Provides:
#   _hook_causal_log_finalize      — pipeline_end event + dashboard refresh
#   _hook_health_reassess          — optional health re-score on success
#   _hook_failure_context          — LAST_FAILURE_CONTEXT.json on failure
#   _hook_update_check             — non-intrusive update check
#   _hook_final_dashboard_status   — last-chance dashboard run_state write
#   _hook_tui_complete             — out_complete() for the TUI sidecar
# =============================================================================
set -euo pipefail

# d. Emit pipeline_end event and archive causal log (Milestone 13)
_hook_causal_log_finalize() {
    local exit_code="$1"
    local status="success"
    [[ "$exit_code" -ne 0 ]] && status="failed"

    # Emit pipeline_end event
    if command -v emit_event &>/dev/null; then
        emit_event "pipeline_end" "pipeline" "exit_code=${exit_code}" \
            "${_PIPELINE_START_EVT:-}" \
            "" \
            "{\"status\":\"${status}\",\"total_turns\":${TOTAL_TURNS:-0},\"total_time\":${TOTAL_TIME:-0}}" \
            >/dev/null 2>&1 || true
    fi

    # Update dashboard with final state
    if command -v emit_dashboard_run_state &>/dev/null; then
        # shellcheck disable=SC2034  # Used by emit_dashboard_run_state
        PIPELINE_STATUS="$status"
        # shellcheck disable=SC2034  # Used by emit_dashboard_run_state
        CURRENT_STAGE="complete"
        # shellcheck disable=SC2034  # Explicit: waiting_for: null in final state
        WAITING_FOR=""
        emit_dashboard_run_state 2>/dev/null || true
    fi
    if command -v emit_dashboard_metrics &>/dev/null; then
        emit_dashboard_metrics 2>/dev/null || true
    fi
    if command -v emit_dashboard_milestones &>/dev/null; then
        emit_dashboard_milestones 2>/dev/null || true
    fi
    if command -v emit_dashboard_health &>/dev/null; then
        emit_dashboard_health 2>/dev/null || true
    fi
    if command -v emit_dashboard_action_items &>/dev/null; then
        emit_dashboard_action_items 2>/dev/null || true
    fi
    # M40: Emit notes data for dashboard Notes tab
    if command -v emit_dashboard_notes &>/dev/null; then
        emit_dashboard_notes 2>/dev/null || true
    fi

    # Archive causal log
    if command -v archive_causal_log &>/dev/null; then
        archive_causal_log 2>/dev/null || true
    fi
}

# k. Health re-assessment (Milestone 15) — optional, on success only
_hook_health_reassess() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "${HEALTH_ENABLED:-true}" != "true" ]] && return 0
    [[ "${HEALTH_REASSESS_ON_COMPLETE:-false}" != "true" ]] && return 0
    if ! command -v reassess_project_health &>/dev/null; then
        return 0
    fi
    local prev_score=0
    local baseline_file="${PROJECT_DIR:-.}/${HEALTH_BASELINE_FILE:-.claude/HEALTH_BASELINE.json}"
    if [[ -f "$baseline_file" ]]; then
        prev_score=$(_read_json_int "$baseline_file" "composite")
    fi
    local new_score
    new_score=$(reassess_project_health "${PROJECT_DIR:-.}" 2>/dev/null || echo "0")
    export HEALTH_SCORE="$new_score"
    export HEALTH_PREV_SCORE="$prev_score"
    # Re-emit dashboard health data (causal_log_finalize emitted stale data)
    if command -v emit_dashboard_health &>/dev/null; then
        emit_dashboard_health 2>/dev/null || true
    fi
}

# m. Write LAST_FAILURE_CONTEXT.json and emit diagnose hint (M17, failure only)
_hook_failure_context() {
    # Runs AFTER _hook_causal_log_finalize (hook d) archives the causal log.
    # The live CAUSAL_LOG.jsonl is still present (archive_causal_log copies,
    # does not move), so _read_diagnostic_context still reads the live file.
    local exit_code="$1"
    [[ "$exit_code" -eq 0 ]] && return 0

    if command -v write_last_failure_context &>/dev/null; then
        local stage="${CURRENT_STAGE:-unknown}"
        local classification="UNKNOWN"
        if command -v classify_failure_diag &>/dev/null; then
            _read_diagnostic_context 2>/dev/null || true
            classify_failure_diag 2>/dev/null || true
            classification="${DIAG_CLASSIFICATION:-UNKNOWN}"
        fi
        write_last_failure_context "$classification" "$stage" "failure" 2>/dev/null || true
    fi

    if command -v emit_dashboard_diagnosis &>/dev/null; then
        emit_dashboard_diagnosis 2>/dev/null || true
    fi
}

# n. Update check — non-intrusive, runs at the very end of output
_hook_update_check() {
    # shellcheck disable=SC2034  # exit_code assigned for hook interface consistency
    local exit_code="$1"
    if command -v check_for_updates &>/dev/null; then
        check_for_updates 2>/dev/null || true
    fi
}

# p. Final dashboard status (M34 §3) — highest priority (runs last).
# Guarantees run_state.js reflects completion even if earlier hooks failed.
_hook_final_dashboard_status() {
    local exit_code="$1"
    if ! command -v emit_dashboard_run_state &>/dev/null; then
        return 0
    fi
    local status="success"
    [[ "$exit_code" -ne 0 ]] && status="failed"
    # shellcheck disable=SC2034  # Used by emit_dashboard_run_state
    PIPELINE_STATUS="$status"
    # shellcheck disable=SC2034  # Used by emit_dashboard_run_state
    CURRENT_STAGE="complete"
    # shellcheck disable=SC2034  # Explicit: waiting_for: null in final state
    WAITING_FOR=""
    emit_dashboard_run_state 2>/dev/null || true
}

# Must run last: calls out_complete, which reads action_items populated by
# _hook_commit. If it runs earlier, those items are absent from the status
# JSON the TUI sidecar reads.
_hook_tui_complete() {
    local exit_code="${1:-0}"
    local verdict="SUCCESS"
    [[ "$exit_code" -ne 0 ]] && verdict="FAIL"
    # M107: close the wrap-up pill before out_complete flips the sidecar into
    # hold-on-complete. All commit, archive, and version-bump hooks have
    # already run by this point, so finalization really is done.
    if declare -f tui_stage_end &>/dev/null; then
        tui_stage_end "wrap-up" "" "" "" "$verdict" 2>/dev/null || true
    fi
    out_complete "$verdict" 2>/dev/null || true
}
