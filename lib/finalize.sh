#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize.sh — Post-pipeline finalization hook registry and orchestrator
#
# Sourced by tekhton.sh — do not run directly.
# Expects: hooks.sh, notes.sh, drift_cleanup.sh, milestone_ops.sh,
#          milestone_archival.sh, metrics.sh, drift_artifacts.sh sourced first.
# Expects: LOG_DIR, TIMESTAMP, LOG_FILE, TASK, MILESTONE_MODE, AUTO_COMMIT,
#          _CURRENT_MILESTONE (set by caller/tekhton.sh)
#
# Provides:
#   register_finalize_hook — append a hook function to the finalization sequence
#   finalize_run           — execute all registered hooks in order
#   _do_git_commit         — stage, commit, and log output
# =============================================================================

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
_do_git_commit() {
    local msg="$1"
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
}

# c. Record run metrics
_hook_record_metrics() {
    local exit_code="$1"
    record_run_metrics
}

# d. Clear resolved non-blocking notes (success only)
_hook_cleanup_resolved() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    if command -v clear_resolved_nonblocking_notes >/dev/null 2>&1; then
        clear_resolved_nonblocking_notes
    fi
}

# e. Resolve human notes with exit code awareness
_hook_resolve_notes() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    if [[ ! -f "HUMAN_NOTES.md" ]]; then
        return 0
    fi
    local remaining_claimed
    remaining_claimed=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
    if [[ "$remaining_claimed" -gt 0 ]]; then
        # Set _PIPELINE_EXIT_CODE so resolve_human_notes can use it
        # for the fallback path when CODER_SUMMARY.md is missing
        _PIPELINE_EXIT_CODE="$exit_code"
        export _PIPELINE_EXIT_CODE
        resolve_human_notes
    fi
}

# f. Archive reports
_hook_archive_reports() {
    local exit_code="$1"
    archive_reports "$LOG_DIR" "$TIMESTAMP"
}

# g. Mark milestone done (success + milestone mode + acceptance passed)
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

# h. Auto-commit or interactive commit prompt
_hook_commit() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]] && return 0

    # Milestone disposition for commit signatures
    local ms_num=""
    local ms_disposition=""
    if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        ms_num="$_CURRENT_MILESTONE"
        ms_disposition=$(get_milestone_disposition 2>/dev/null || echo "")
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

# i. Archive completed milestone (after commit, milestone mode only)
_hook_archive_milestone() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "$MILESTONE_MODE" != true ]] && return 0
    [[ -z "${_CURRENT_MILESTONE:-}" ]] && return 0
    [[ "${_COMMIT_SUCCEEDED:-false}" != true ]] && return 0

    local disposition
    disposition=$(get_milestone_disposition 2>/dev/null || echo "")
    if [[ "$disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$disposition" == COMPLETE_AND_WAIT ]]; then
        tag_milestone_complete "$_CURRENT_MILESTONE"
        archive_completed_milestone "$_CURRENT_MILESTONE" "CLAUDE.md" || true
    fi
}

# j. Clear milestone state (after successful archival)
_hook_clear_state() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "$MILESTONE_MODE" != true ]] && return 0
    [[ -z "${_CURRENT_MILESTONE:-}" ]] && return 0
    [[ "${_COMMIT_SUCCEEDED:-false}" != true ]] && return 0

    local disposition
    disposition=$(get_milestone_disposition 2>/dev/null || echo "")
    if [[ "$disposition" == COMPLETE_AND_CONTINUE ]] || [[ "$disposition" == COMPLETE_AND_WAIT ]]; then
        clear_milestone_state
    fi
}

# --- Action items summary (extracted from tekhton.sh) ------------------------

_print_action_items() {
    local action_items=()

    # Check for tester bugs
    if [[ -f "TESTER_REPORT.md" ]] && \
       awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^[Nn]one/{exit 1} f && /^- /{found=1} END{exit !found}' TESTER_REPORT.md 2>/dev/null; then
        local bug_count
        bug_count=$(awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^[Nn]one/{print 0; exit} f && /^- /{c++} END{print c+0}' TESTER_REPORT.md)
        action_items+=("$(echo -e "${YELLOW}  ⚠ TESTER_REPORT.md — ${bug_count} bug(s) found (see ## Bugs Found)${NC}")")
    fi

    # Check for test failures from final checks
    if [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]]; then
        action_items+=("$(echo -e "${YELLOW}  ⚠ Test suite — final checks failed (see output above)${NC}")")
    fi

    # Check for human action items
    if has_human_actions 2>/dev/null; then
        local ha_count
        ha_count=$(count_human_actions)
        action_items+=("$(echo -e "${YELLOW}  ⚠ ${HUMAN_ACTION_FILE} — ${ha_count} item(s) needing manual work${NC}")")
    fi

    # Check for non-blocking notes (info only)
    if [[ -f "${NON_BLOCKING_LOG_FILE:-}" ]] && [[ -s "${NON_BLOCKING_LOG_FILE:-}" ]]; then
        local nb_count
        nb_count=$(count_open_nonblocking_notes 2>/dev/null || echo 0)
        if [[ "$nb_count" -gt 0 ]]; then
            action_items+=("$(echo -e "${CYAN}  ℹ ${NON_BLOCKING_LOG_FILE} — ${nb_count} accumulated observation(s)${NC}")")
        fi
    fi

    # Check for drift observations (info only)
    if [[ -f "${DRIFT_LOG_FILE:-}" ]] && [[ -s "${DRIFT_LOG_FILE:-}" ]]; then
        local drift_count
        drift_count=$(count_drift_observations 2>/dev/null || echo 0)
        if [[ "$drift_count" -gt 0 ]]; then
            action_items+=("$(echo -e "${CYAN}  ℹ ${DRIFT_LOG_FILE} — ${drift_count} unresolved drift observation(s)${NC}")")
        fi
    fi

    if [[ ${#action_items[@]} -gt 0 ]]; then
        echo -e "${BOLD}══════════════════════════════════════${NC}"
        echo -e "${BOLD}  Action Items${NC}"
        echo -e "${BOLD}══════════════════════════════════════${NC}"
        for item in "${action_items[@]}"; do
            echo -e "$item"
        done
        echo -e "${BOLD}══════════════════════════════════════${NC}"
        echo
    else
        success "No action items — clean run."
        echo
    fi
}

# --- Hook registration (at source-time) -------------------------------------
# Registration order IS execution order. V3 modules register additional hooks
# after this file is sourced — no modification to the core sequence required.

register_finalize_hook "_hook_final_checks"
register_finalize_hook "_hook_drift_artifacts"
register_finalize_hook "_hook_record_metrics"
register_finalize_hook "_hook_cleanup_resolved"
register_finalize_hook "_hook_resolve_notes"
register_finalize_hook "_hook_archive_reports"
register_finalize_hook "_hook_mark_done"
register_finalize_hook "_hook_commit"
register_finalize_hook "_hook_archive_milestone"
register_finalize_hook "_hook_clear_state"

# --- Orchestrator ------------------------------------------------------------

# finalize_run PIPELINE_EXIT_CODE
# Executes all registered hooks in order. Each hook receives the exit code
# as its first argument and decides internally whether to act on success/failure.
# A failing hook logs a warning but does not abort the sequence.
finalize_run() {
    local pipeline_exit_code="${1:-0}"

    # State shared between hooks
    FINAL_CHECK_RESULT=0
    _COMMIT_SUCCEEDED=false
    export FINAL_CHECK_RESULT _COMMIT_SUCCEEDED

    for hook_fn in "${FINALIZE_HOOKS[@]}"; do
        if ! "$hook_fn" "$pipeline_exit_code"; then
            warn "Finalize hook '${hook_fn}' failed (continuing)."
        fi
    done
}
