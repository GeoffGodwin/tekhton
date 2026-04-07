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
#   _do_git_commit         — stage, commit, and log output
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

# --- Git commit helper (moved from tekhton.sh) ------------------------------

# _do_git_commit MSG
# Stages all changes, runs gitignore safety check, commits with MSG.
# M40: Drains pending inbox before commit so mid-run notes are persisted.
_do_git_commit() {
    local msg="$1"
    # Drain any pending watchtower inbox notes before committing
    if command -v drain_pending_inbox &>/dev/null; then
        drain_pending_inbox 2>/dev/null || true
    fi
    _check_gitignore_safety
    git add -A > /dev/null 2>&1
    local git_output
    git_output=$(git commit -m "$msg" 2>&1) || true
    # Show only the summary line (e.g. "[branch abc1234] feat: message")
    local summary
    summary=$(echo "$git_output" | head -1)
    log "$summary"
}

# --- Hook implementations ---------------------------------------------------

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
    if [[ ! -f "HUMAN_NOTES.md" ]]; then
        return 0
    fi

    # Bulk resolution via CLAIMED_NOTE_IDS (runs on success AND failure)
    if [[ -n "${CLAIMED_NOTE_IDS:-}" ]]; then
        log "Resolving claimed notes (exit_code=$exit_code): ${CLAIMED_NOTE_IDS}"
        _PIPELINE_EXIT_CODE="$exit_code"
        export _PIPELINE_EXIT_CODE
        resolve_notes_batch "$CLAIMED_NOTE_IDS" "$exit_code"
    fi

    # Safety net: resolve orphaned [~] notes (M33 Bug 6, M42 fix).
    # On success → mark [x]; on failure → reset to [ ] for next run.
    local orphan_count
    orphan_count=$(grep -c '^- \[~\]' HUMAN_NOTES.md 2>/dev/null || echo "0")
    orphan_count=$(echo "$orphan_count" | tr -d '[:space:]')
    if [[ "$orphan_count" -gt 0 ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            warn "Found ${orphan_count} orphaned in-progress note(s) — resolving as complete."
            sed -i 's/^- \[~\]/- [x]/' HUMAN_NOTES.md
        else
            warn "Found ${orphan_count} orphaned in-progress note(s) — resetting for next run."
            sed -i 's/^- \[~\]/- [ ]/' HUMAN_NOTES.md
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

# (Helper function — not registered in finalization sequence)
#    Tags milestone-complete (post-commit) if milestone is done.

_tag_milestone_if_complete() {
    [[ "$MILESTONE_MODE" != true ]] && return 0
    [[ -z "${_CURRENT_MILESTONE:-}" ]] && return 0
    local disposition="${_CACHED_DISPOSITION:-}"
    if [[ "$disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$disposition" == COMPLETE_AND_WAIT ]]; then
        tag_milestone_complete "$_CURRENT_MILESTONE"
    fi
}

# o. Express mode: persist auto-detected config on success
_hook_express_persist() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "${EXPRESS_MODE_ACTIVE:-false}" != "true" ]] && return 0

    if [[ "${EXPRESS_PERSIST_CONFIG:-true}" == "true" ]]; then
        persist_express_config "${PROJECT_DIR}"
    fi
    if [[ "${EXPRESS_PERSIST_ROLES:-false}" == "true" ]]; then
        persist_express_roles "${PROJECT_DIR}"
        log "Built-in role templates copied to .claude/agents/."
    fi
}

# n. Auto-commit or interactive commit prompt
_hook_commit() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]] && return 0

    # Milestone disposition for commit signatures (read from cache —
    # _hook_clear_state may have already deleted MILESTONE_STATE.md)
    local ms_num=""
    local ms_disposition=""
    if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        ms_num="$_CURRENT_MILESTONE"
        ms_disposition="${_CACHED_DISPOSITION:-}"
    fi

    # Remove lock file before staging so it isn't committed
    if [[ -n "${_TEKHTON_LOCK_FILE:-}" ]] && [[ -f "${_TEKHTON_LOCK_FILE}" ]]; then
        rm -f "${_TEKHTON_LOCK_FILE}" 2>/dev/null || true
    fi

    # Generate commit message
    COMMIT_MSG=$(generate_commit_message "$TASK" "$ms_num" "$ms_disposition" || echo "feat: ${TASK}")

    # Print completion banner
    header "Tekhton — Pipeline Complete"
    echo -e "  Task:      ${BOLD}${TASK}${NC}"
    echo -e "  Started:   ${BOLD}${START_AT}${NC}"
    echo -e "  Verdict:   ${GREEN}${BOLD}${VERDICT}${NC}"
    echo -e "  Log:       ${LOG_FILE}"
    if [[ -n "$ms_num" ]]; then
        if [[ "$ms_disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$ms_disposition" == COMPLETE_AND_WAIT ]]; then
            echo -e "  Milestone: ${GREEN}${BOLD}${ms_num} — COMPLETE${NC}"
        else
            echo -e "  Milestone: ${YELLOW}${BOLD}${ms_num} — PARTIAL${NC}"
        fi
    fi
    # Health score delta (Milestone 15)
    if [[ -n "${HEALTH_SCORE:-}" ]] && command -v display_health_score &>/dev/null; then
        display_health_score "$HEALTH_SCORE" "${HEALTH_PREV_SCORE:-}"
    fi
    # Top-3 time consumers (M46)
    if command -v _format_timing_banner &>/dev/null && [[ ${#_PHASE_TIMINGS[@]} -gt 0 ]]; then
        local _timing_banner
        _timing_banner=$(_format_timing_banner)
        if [[ -n "$_timing_banner" ]]; then
            echo -e "  ${BOLD}Time breakdown (top 3):${NC}"
            echo "$_timing_banner"
        fi
    fi
    echo
    # Print action items summary
    _print_action_items

    log "Suggested commit message:"
    echo "────────────────────────────────────────"
    echo "$COMMIT_MSG"
    echo "────────────────────────────────────────"
    echo

    local commit_choice
    if [[ "${AUTO_COMMIT:-false}" = "true" ]]; then
        log "AUTO_COMMIT enabled — committing automatically."
        commit_choice="y"
    else
        log "Commit with suggested message? [y/e/n]"
        echo "  y = commit now with this message"
        echo "  e = open message in \$EDITOR first"
        echo "  n = skip (commit manually later)"
        if [[ -t 0 ]]; then
            read -r commit_choice
        else
            read -r commit_choice < /dev/tty 2>/dev/null || commit_choice="y"
            log "(read from /dev/tty — stdin was piped)"
        fi
    fi

    case "$commit_choice" in
        y|Y)
            _do_git_commit "$COMMIT_MSG"
            _COMMIT_SUCCEEDED=true
            # Update checkpoint with commit sha (Milestone 24)
            if command -v update_checkpoint_commit &>/dev/null; then
                update_checkpoint_commit "$(git rev-parse HEAD 2>/dev/null || echo "")"
            fi
            _tag_milestone_if_complete
            print_run_summary
            success "Committed. Open a PR and squash-merge to main when ready."
            ;;
        e|E)
            local tmpfile
            tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/tekhton-commit-XXXXXX.txt")
            echo "$COMMIT_MSG" > "$tmpfile"
            ${EDITOR:-nano} "$tmpfile"
            local edited_msg
            edited_msg=$(cat "$tmpfile")
            rm "$tmpfile"
            _do_git_commit "$edited_msg"
            _COMMIT_SUCCEEDED=true
            # Update checkpoint with commit sha (Milestone 24)
            if command -v update_checkpoint_commit &>/dev/null; then
                update_checkpoint_commit "$(git rev-parse HEAD 2>/dev/null || echo "")"
            fi
            _tag_milestone_if_complete
            print_run_summary
            success "Committed. Open a PR and squash-merge to main when ready."
            ;;
        *)
            log "Skipped commit. When ready:"
            echo "  git add -A && git commit -m '${COMMIT_MSG%%$'\n'*}'"
            _COMMIT_SUCCEEDED=false
            ;;
    esac
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
            2>/dev/null || true
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

# l. Emit RUN_SUMMARY.json (M16)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_summary.sh"

# l1.5. Emit RUN_MEMORY.jsonl (M49)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/run_memory.sh"

# l2. Emit TIMING_REPORT.md (M46)
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/timing.sh"

# m. Write LAST_FAILURE_CONTEXT.json and emit diagnose hint (M17, failure only)
# NOTE: This hook runs AFTER _hook_causal_log_finalize (hook d), which archives
# the causal log. The live CAUSAL_LOG.jsonl is still present (archive_causal_log
# copies, does not move), but _read_diagnostic_context reads from the live file.
_hook_failure_context() {
    local exit_code="$1"
    [[ "$exit_code" -eq 0 ]] && return 0

    # Runs after causal log archive (hook d) — live CAUSAL_LOG.jsonl still present
    # Write failure context for fast --diagnose startup
    if command -v write_last_failure_context &>/dev/null; then
        local stage="${CURRENT_STAGE:-unknown}"
        # Classify failure inline if diagnose_rules.sh is loaded
        local classification="UNKNOWN"
        if command -v classify_failure_diag &>/dev/null; then
            _read_diagnostic_context 2>/dev/null || true
            classify_failure_diag 2>/dev/null || true
            classification="${DIAG_CLASSIFICATION:-UNKNOWN}"
        fi
        write_last_failure_context "$classification" "$stage" "failure" 2>/dev/null || true
    fi

    # Emit dashboard diagnosis data
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

# --- Hook registration (at source-time) ---
# Registration order IS execution order.
# Archive, clear_state, and emit_run_summary run BEFORE commit so their
# output is captured in the commit and git state is clean afterward.
# o2. Note acceptance checks (M42) — before final checks
_hook_note_acceptance() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    if command -v run_note_acceptance &>/dev/null; then
        run_note_acceptance || true
    fi
}

# q. Baseline cleanup (M63) — remove stale baselines from prior runs
_hook_baseline_cleanup() {
    # shellcheck disable=SC2034  # exit_code used for hook interface
    local exit_code="$1"
    if command -v cleanup_stale_baselines &>/dev/null; then
        cleanup_stale_baselines 2>/dev/null || true
    fi
}

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
register_finalize_hook "_hook_commit"
register_finalize_hook "_hook_update_check"
register_finalize_hook "_hook_final_dashboard_status"
# --- Orchestrator ---
# finalize_run PIPELINE_EXIT_CODE
# Executes all registered hooks in order. Each hook receives the exit code
# as its first argument and decides internally whether to act on success/failure.
# A failing hook logs a warning but does not abort the sequence.
finalize_run() {
    local pipeline_exit_code="${1:-0}"

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
