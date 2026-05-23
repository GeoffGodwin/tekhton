#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# finalize_core_hooks.sh — m21. The five bash hook bodies that used to live
# directly in lib/finalize.sh. Sourced by lib/finalize_shim.sh (and
# transitively by tekhton-legacy.sh through lib/finalize.sh) so the bash
# function names remain callable for the unmigrated 18-hook tail.
#
# Each hook will graduate to a pure-Go body as its underlying subsystem
# ports (m22..m25). When all five are gone, this file deletes.
# =============================================================================

_hook_final_checks() {
    local exit_code="$1"
    # Persist FINAL_CHECK_RESULT to a file because each finalize hook runs
    # in its own bash subprocess under the Go orchestrator's shim — locals
    # and exported variables don't propagate between hooks. _hook_commit
    # later reads this file (via _final_check_result_read in
    # finalize_commit.sh) and refuses to commit when failures are recorded.
    #
    # DO NOT clear the sentinel at hook entry. The synthesize-fallback paths
    # in stages/{coder,review,tester_validation}.sh call trip_commit_gate
    # DURING stages (well before this hook runs in the finalize chain), and
    # erasing those trips here would let hollow milestones commit again
    # (see git history: M23 ran and committed despite missing
    # CODER_SUMMARY.md because this hook wiped the stage trip). Cleanup of
    # stale sentinels from prior crashed runs happens at pipeline-start via
    # _hook_baseline_cleanup, not here.
    local _fcr_file="${TEKHTON_DIR:-.tekhton}/.final_check_result"

    if [[ "${SKIP_FINAL_CHECKS:-false}" = true ]]; then
        warn "Skipping final checks — a stage had a null run."
        FINAL_CHECK_RESULT=1
        printf '%s\n' "$FINAL_CHECK_RESULT" > "$_fcr_file" 2>/dev/null || true
        return 0
    fi
    if [[ "${_PREFLIGHT_TESTS_PASSED:-false}" = true ]]; then
        log "Pre-finalization test gate passed — skipping redundant final checks."
        FINAL_CHECK_RESULT=0
        return 0
    fi
    FINAL_CHECK_RESULT=0
    # LOG_FILE is expected to come from the Go finalize shim (LOG_DIR +
    # TIMESTAMP). Synthesize a fallback if missing so `set -u` does not crash
    # the hook before run_final_checks even runs.
    local _final_log="${LOG_FILE:-${LOG_DIR:-${TEKHTON_DIR:-.tekhton}}/${TIMESTAMP:-run}_finalize.log}"
    run_final_checks "$_final_log" || FINAL_CHECK_RESULT=$?
    if [[ "$FINAL_CHECK_RESULT" -ne 0 ]]; then
        printf '%s\n' "$FINAL_CHECK_RESULT" > "$_fcr_file" 2>/dev/null || true
        error "Final checks failed (exit ${FINAL_CHECK_RESULT}). Commit will be blocked; downstream hooks (archive/metrics) still run."
    fi
}

_hook_drift_artifacts() {
    # shellcheck disable=SC2034
    local exit_code="$1"
    process_drift_artifacts
    if declare -f invalidate_drift_cache &>/dev/null; then
        invalidate_drift_cache
    fi
}

_hook_record_metrics() {
    # shellcheck disable=SC2034
    local exit_code="$1"
    record_run_metrics
}

_hook_cleanup_resolved() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    if command -v clear_resolved_nonblocking_notes >/dev/null 2>&1; then
        clear_resolved_nonblocking_notes
    fi
}

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
