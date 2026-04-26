#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize.sh — Post-pipeline finalization hook registry and orchestrator
#
# Sourced by tekhton.sh — do not run directly.
# Expects: hooks.sh, notes.sh, drift_cleanup.sh, milestone_ops.sh,
#          milestone_archival.sh, metrics.sh, drift_artifacts.sh,
#          finalize_display.sh sourced first.
# Expects: LOG_DIR, TIMESTAMP, LOG_FILE, TASK, MILESTONE_MODE, AUTO_COMMIT,
#          _CURRENT_MILESTONE (set by caller/tekhton.sh)
#
# Provides:
#   register_finalize_hook — append a hook function to the finalization sequence
#   finalize_run           — execute all registered hooks in order
#
# Hook implementations are split across:
#   finalize_commit.sh            — _hook_commit + _do_git_commit helpers
#   finalize_dashboard_hooks.sh   — dashboard/causal-log/TUI/update hooks
#   finalize_summary.sh           — _hook_emit_run_summary
#   run_memory.sh                 — _hook_emit_run_memory
#   timing.sh                     — _hook_emit_timing_report
#   finalize_version.sh           — _hook_project_version_bump / _tag
#   changelog.sh                  — _hook_changelog_append
# =============================================================================

# Source display helper
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_display.sh"

# --- Hook registry -----------------------------------------------------------

declare -a FINALIZE_HOOKS=()

# register_finalize_hook FUNC_NAME
# Appends a function name to the finalization sequence.
# Hooks execute in registration order. Each receives pipeline_exit_code as $1.
register_finalize_hook() {
    local func_name="$1"
    FINALIZE_HOOKS+=("$func_name")
}

# --- Core hook implementations ----------------------------------------------

# a. Final checks (analyze + test)
_hook_final_checks() {
    local exit_code="$1"
    if [[ "${SKIP_FINAL_CHECKS:-false}" = true ]]; then
        warn "Skipping final checks — a stage had a null run."
        FINAL_CHECK_RESULT=1
        return 0
    fi
    # If the pre-finalization test gate in orchestrate.sh already verified
    # tests pass, skip the redundant re-run. The gate feeds failures back
    # into the retry loop; by the time we reach here, tests are known-good.
    if [[ "${_PREFLIGHT_TESTS_PASSED:-false}" = true ]]; then
        log "Pre-finalization test gate passed — skipping redundant final checks."
        FINAL_CHECK_RESULT=0
        return 0
    fi
    FINAL_CHECK_RESULT=0
    run_final_checks "$LOG_FILE" || FINAL_CHECK_RESULT=$?
    if [[ "$FINAL_CHECK_RESULT" -ne 0 ]]; then
        warn "Final checks had failures (exit ${FINAL_CHECK_RESULT}). Pipeline will continue to archiving and commit prompt."
    fi
}

# b. Drift artifact processing
_hook_drift_artifacts() {
    local exit_code="$1"
    process_drift_artifacts
    # M47: invalidate drift cache since process_drift_artifacts may have
    # appended new observations. Relevant when --complete loops re-run stages.
    if declare -f invalidate_drift_cache &>/dev/null; then
        invalidate_drift_cache
    fi
}

# c. Record run metrics
_hook_record_metrics() {
    local exit_code="$1"
    record_run_metrics
}

# e. Clear resolved non-blocking notes (success only)
_hook_cleanup_resolved() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    if command -v clear_resolved_nonblocking_notes >/dev/null 2>&1; then
        clear_resolved_nonblocking_notes
    fi
}

# f. Resolve human notes with exit code awareness
#    Unified path — resolves CLAIMED_NOTE_IDS (set during claiming).
#    Works for both --human single-note and batch modes because
#    claim_single_note() and claim_notes_batch() both register IDs
#    in CLAIMED_NOTE_IDS.
_hook_resolve_notes() {
    local exit_code="$1"
    if [[ ! -f "${HUMAN_NOTES_FILE}" ]]; then
        return 0
    fi

    if [[ -n "${CLAIMED_NOTE_IDS:-}" ]]; then
        log "Resolving claimed notes (exit_code=$exit_code): ${CLAIMED_NOTE_IDS}"
        _PIPELINE_EXIT_CODE="$exit_code"
        export _PIPELINE_EXIT_CODE
        resolve_notes_batch "$CLAIMED_NOTE_IDS" "$exit_code"
    fi

    # Safety net: resolve orphaned [~] notes (M33 Bug 6, M42 fix).
    # On success → mark [x]; on failure → reset to [ ] for next run.
    local orphan_count
    orphan_count=$(grep -c '^- \[~\]' "${HUMAN_NOTES_FILE}" 2>/dev/null || echo "0")
    orphan_count=$(echo "$orphan_count" | tr -d '[:space:]')
    if [[ "$orphan_count" -gt 0 ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            warn "Found ${orphan_count} orphaned in-progress note(s) — resolving as complete."
            sed -i 's/^- \[~\]/- [x]/' "${HUMAN_NOTES_FILE}"
        else
            warn "Found ${orphan_count} orphaned in-progress note(s) — resetting for next run."
            sed -i 's/^- \[~\]/- [ ]/' "${HUMAN_NOTES_FILE}"
        fi
    fi
}

# g. Archive reports
_hook_archive_reports() {
    local exit_code="$1"
    archive_reports "$LOG_DIR" "$TIMESTAMP"
}

# h. Mark milestone done (success + milestone mode + acceptance passed)
_hook_mark_done() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "$MILESTONE_MODE" != true ]] && return 0
    [[ -z "${_CURRENT_MILESTONE:-}" ]] && return 0

    local disposition
    disposition=$(get_milestone_disposition 2>/dev/null || echo "")
    if [[ "$disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$disposition" == COMPLETE_AND_WAIT ]]; then
        mark_milestone_done "$_CURRENT_MILESTONE" || true
    fi
}

# i. Archive completed milestone (before commit so archive is included)
_hook_archive_milestone() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "$MILESTONE_MODE" != true ]] && return 0
    [[ -z "${_CURRENT_MILESTONE:-}" ]] && return 0

    local disposition
    disposition=$(get_milestone_disposition 2>/dev/null || echo "")
    if [[ "$disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$disposition" == COMPLETE_AND_WAIT ]]; then
        archive_completed_milestone "$_CURRENT_MILESTONE" "CLAUDE.md" || true
    fi
}

# j. Clear milestone state (before commit so cleared state is committed)
_hook_clear_state() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "$MILESTONE_MODE" != true ]] && return 0
    [[ -z "${_CURRENT_MILESTONE:-}" ]] && return 0

    local disposition
    disposition=$(get_milestone_disposition 2>/dev/null || echo "")
    if [[ "$disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$disposition" == COMPLETE_AND_WAIT ]]; then
        clear_milestone_state
    fi
}

# Express persist, note acceptance, baseline cleanup, and the M129
# failure-context reset live in finalize_aux.sh — extracted to keep this file
# under the 300-line ceiling.

# --- Source extension hooks (order matters for the registration list below) -

# Auxiliary hooks (M129 extraction): express persist, note acceptance,
# baseline cleanup, failure-context reset.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_aux.sh"

# Commit flow (_do_git_commit, _tag_milestone_if_complete, _hook_commit)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_commit.sh"

# Dashboard/causal/TUI/update hooks
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_dashboard_hooks.sh"

# l. Emit RUN_SUMMARY.json (M16)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_summary.sh"

# l1.5. Emit RUN_MEMORY.jsonl (M49)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/run_memory.sh"

# l2. Emit TIMING_REPORT.md (M46)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/timing.sh"

# l3. Project version bump + tag (M76)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_version.sh"

# l4. Changelog generation (M77)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/changelog.sh"

# --- Hook registration (source-time; order IS execution order) ---
# Archive, clear_state, and emit_run_summary run BEFORE commit so their
# output is captured in the commit and git state is clean afterward.
register_finalize_hook "_hook_baseline_cleanup"
register_finalize_hook "_hook_note_acceptance"
register_finalize_hook "_hook_final_checks"
register_finalize_hook "_hook_drift_artifacts"
register_finalize_hook "_hook_record_metrics"
register_finalize_hook "_hook_causal_log_finalize"
register_finalize_hook "_hook_cleanup_resolved"
register_finalize_hook "_hook_resolve_notes"
register_finalize_hook "_hook_archive_reports"
register_finalize_hook "_hook_mark_done"
register_finalize_hook "_hook_archive_milestone"
register_finalize_hook "_hook_clear_state"
register_finalize_hook "_hook_health_reassess"
register_finalize_hook "_hook_emit_run_summary"
register_finalize_hook "_hook_emit_run_memory"
register_finalize_hook "_hook_emit_timing_report"
register_finalize_hook "_hook_failure_context"
register_finalize_hook "_hook_express_persist"
register_finalize_hook "_hook_project_version_bump"
register_finalize_hook "_hook_changelog_append"
register_finalize_hook "_hook_commit"
register_finalize_hook "_hook_project_version_tag"
register_finalize_hook "_hook_update_check"
register_finalize_hook "_hook_final_dashboard_status"
register_finalize_hook "_hook_tui_complete"
register_finalize_hook "_hook_failure_context_reset"

# --- Orchestrator -----------------------------------------------------------

# finalize_run PIPELINE_EXIT_CODE
# Executes all registered hooks in order. Each hook receives the exit code
# as its first argument and decides internally whether to act on success/failure.
# A failing hook logs a warning but does not abort the sequence.
finalize_run() {
    local pipeline_exit_code="${1:-0}"

    # M107: notify TUI sidecar that the wrap-up stage has begun. This covers
    # every finalize_run call site with a single hook. The matching end call
    # lives in _hook_tui_complete.
    if declare -f tui_stage_begin &>/dev/null; then
        tui_stage_begin "wrap-up" "" 2>/dev/null || true
    fi

    # State shared between hooks
    FINAL_CHECK_RESULT=0
    _COMMIT_SUCCEEDED=false
    # Cache milestone disposition before hooks run — _hook_clear_state deletes
    # MILESTONE_STATE.md (so it's included in the commit), but _hook_commit and
    # _tag_milestone_if_complete still need the disposition value afterward.
    _CACHED_DISPOSITION=""
    if [[ "${MILESTONE_MODE:-false}" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        _CACHED_DISPOSITION=$(get_milestone_disposition 2>/dev/null || echo "")
    fi
    export FINAL_CHECK_RESULT _COMMIT_SUCCEEDED _CACHED_DISPOSITION

    _phase_start "finalization"
    for hook_fn in "${FINALIZE_HOOKS[@]}"; do
        if ! "$hook_fn" "$pipeline_exit_code"; then
            warn "Finalize hook '${hook_fn}' failed (continuing)."
        fi
    done
    _phase_end "finalization"
}
