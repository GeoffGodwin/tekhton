#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_helpers.sh — Helper functions for the orchestration loop
#
# Extracted from orchestrate.sh to stay under the 300-line ceiling.
# Sourced by orchestrate.sh — do not run directly.
# =============================================================================

# --- Auto-advance chain (reused from existing logic) --------------------------

_run_auto_advance_chain() {
    while should_auto_advance 2>/dev/null; do
        local next_ms
        next_ms=$(find_next_milestone "$_CURRENT_MILESTONE" "${PROJECT_RULES_FILE:-CLAUDE.md}")
        if [[ -z "$next_ms" ]]; then
            log "No more milestones to advance to."
            break
        fi

        local next_title
        next_title=$(get_milestone_title "$next_ms")

        if [[ "${AUTO_ADVANCE_CONFIRM:-true}" = "true" ]]; then
            if ! prompt_auto_advance_confirm "$next_ms" "$next_title"; then
                log "Auto-advance declined by user."
                break
            fi
        fi

        # Bump the in-memory session counter BEFORE the advance so the banner
        # and limit check see the correct count.
        _AA_SESSION_ADVANCES=$(( ${_AA_SESSION_ADVANCES:-0} + 1 ))
        export _AA_SESSION_ADVANCES

        # finalize_run already deleted MILESTONE_STATE_FILE; recreate it for the
        # new milestone before advance_milestone reads/writes it.
        local _total
        _total=$(get_milestone_count "${PROJECT_RULES_FILE:-CLAUDE.md}")
        init_milestone_state "$next_ms" "$_total"

        advance_milestone "$_CURRENT_MILESTONE" "$next_ms"
        _CURRENT_MILESTONE="$next_ms"
        TASK="Implement Milestone ${_CURRENT_MILESTONE}: ${next_title}"
        START_AT="coder"

        # M16: Reset per-milestone tracking — successful milestone is forward progress
        _ORCH_REVIEW_BUMPED=false
        _ORCH_ATTEMPT=0
        _ORCH_NO_PROGRESS_COUNT=0
        _ORCH_LAST_ACCEPTANCE_HASH=""
        _ORCH_IDENTICAL_ACCEPTANCE_COUNT=0

        emit_milestone_metadata "$_CURRENT_MILESTONE" "in_progress" || true
        # Refresh dashboard milestones so the "in_progress" status is visible.
        # Guard: always true under tekhton.sh (dashboard_emitters.sh is sourced),
        # but kept for safety if this function is ever sourced standalone.
        if command -v emit_dashboard_milestones &>/dev/null; then
            emit_dashboard_milestones 2>/dev/null || true
        fi

        # Clear per-milestone TUI completion data so the next milestone starts
        # with grey pills instead of inheriting the prior milestone's green row.
        if declare -f tui_reset_for_next_milestone &>/dev/null; then
            tui_reset_for_next_milestone
        fi

        # Re-enter the complete loop for the new milestone.
        # Recursion depth is bounded by AUTO_ADVANCE_LIMIT (default 3) — the
        # should_auto_advance() guard at the top of this while loop exits once
        # the in-memory _AA_SESSION_ADVANCES counter reaches the limit.
        run_complete_loop
        return $?
    done
}

# --- Adaptive turn escalation (Milestone 91) ----------------------------------
#
# When the orchestrator hits AGENT_SCOPE/max_turns consecutively on the same
# stage within a --complete run, escalate the effective turn budget for the
# next attempt. Counter is tracked by run_complete_loop in
# _ORCH_CONSECUTIVE_MAX_TURNS / _ORCH_MAX_TURNS_STAGE.

# _update_escalation_counter FAILED_STAGE ERROR_CATEGORY ERROR_SUBCATEGORY
# Updates _ORCH_CONSECUTIVE_MAX_TURNS and _ORCH_MAX_TURNS_STAGE based on the
# last iteration's outcome. Call once per iteration regardless of outcome.
# Returns 0 if counter was incremented (escalation should apply), 1 otherwise.
_update_escalation_counter() {
    local _stage="${1:-}"
    local _cat="${2:-}"
    local _sub="${3:-}"

    if [[ "${REWORK_TURN_ESCALATION_ENABLED:-true}" != "true" ]]; then
        _ORCH_CONSECUTIVE_MAX_TURNS=0
        _ORCH_MAX_TURNS_STAGE=""
        unset EFFECTIVE_CODER_MAX_TURNS EFFECTIVE_JR_CODER_MAX_TURNS
        unset EFFECTIVE_TESTER_MAX_TURNS
        return 1
    fi

    if [[ "$_cat" = "AGENT_SCOPE" ]] && [[ "$_sub" = "max_turns" ]]; then
        if [[ -n "$_stage" ]] && [[ "$_stage" = "$_ORCH_MAX_TURNS_STAGE" ]]; then
            _ORCH_CONSECUTIVE_MAX_TURNS=$(( _ORCH_CONSECUTIVE_MAX_TURNS + 1 ))
        else
            _ORCH_CONSECUTIVE_MAX_TURNS=1
            _ORCH_MAX_TURNS_STAGE="$_stage"
        fi
        return 0
    fi

    # Any other outcome (success or non-max_turns failure) resets the counter
    _ORCH_CONSECUTIVE_MAX_TURNS=0
    _ORCH_MAX_TURNS_STAGE=""
    unset EFFECTIVE_CODER_MAX_TURNS EFFECTIVE_JR_CODER_MAX_TURNS
    unset EFFECTIVE_TESTER_MAX_TURNS
    return 1
}

# _escalate_turn_budget BASE_TURNS FACTOR COUNT CAP
# Echoes the escalated integer budget clamped to CAP. Uses awk when available,
# falls back to integer shell arithmetic (multiplying factor by 100).
_escalate_turn_budget() {
    local _base="$1"
    local _factor="$2"
    local _count="$3"
    local _cap="$4"
    local _multiplied

    if command -v awk &>/dev/null && _multiplied=$(awk "BEGIN { printf \"%d\", int(${_base} * (1 + (${_factor} * ${_count}))) }" 2>/dev/null); then
        :  # awk succeeded, _multiplied is set
    else
        # Fallback: parse factor as X or X.Y[Z] with pure shell arithmetic,
        # scaled to hundredths so the multiplication stays integer.
        local _factor_x100=150
        if [[ "$_factor" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
            local _int_part="${BASH_REMATCH[1]}"
            local _frac_part="${BASH_REMATCH[3]:-}"
            _frac_part="${_frac_part}00"
            _frac_part="${_frac_part:0:2}"
            _factor_x100=$(( 10#$_int_part * 100 + 10#$_frac_part ))
        fi
        _multiplied=$(( _base + (_base * _factor_x100 * _count) / 100 ))
    fi

    [[ "$_multiplied" =~ ^[0-9]+$ ]] || _multiplied="$_base"
    if [[ "$_multiplied" -gt "$_cap" ]]; then
        _multiplied="$_cap"
    fi
    printf '%s\n' "$_multiplied"
}

# _apply_turn_escalation COUNT
# Computes and exports EFFECTIVE_CODER_MAX_TURNS, EFFECTIVE_JR_CODER_MAX_TURNS,
# and EFFECTIVE_TESTER_MAX_TURNS based on the current consecutive-max-turns
# count. Emits a warn line describing the new budget.
_apply_turn_escalation() {
    local _count="${1:-1}"
    local _factor="${REWORK_TURN_ESCALATION_FACTOR:-1.5}"
    local _cap="${REWORK_TURN_MAX_CAP:-${CODER_MAX_TURNS_CAP:-200}}"

    EFFECTIVE_CODER_MAX_TURNS=$(_escalate_turn_budget "${CODER_MAX_TURNS:-80}" "$_factor" "$_count" "$_cap")
    EFFECTIVE_JR_CODER_MAX_TURNS=$(_escalate_turn_budget "${JR_CODER_MAX_TURNS:-40}" "$_factor" "$_count" "$_cap")
    EFFECTIVE_TESTER_MAX_TURNS=$(_escalate_turn_budget "${TESTER_MAX_TURNS:-50}" "$_factor" "$_count" "$_cap")
    export EFFECTIVE_CODER_MAX_TURNS EFFECTIVE_JR_CODER_MAX_TURNS EFFECTIVE_TESTER_MAX_TURNS

    local _stage="${_ORCH_MAX_TURNS_STAGE:-unknown}"
    if [[ "$EFFECTIVE_CODER_MAX_TURNS" -ge "$_cap" ]]; then
        warn "[orchestrate] max_turns hit ${_count}x for ${_stage} — escalated to cap (${_cap}). Further failures will not escalate; consider --split-milestone."
    else
        warn "[orchestrate] max_turns hit ${_count}x for ${_stage} — escalating coder to ${EFFECTIVE_CODER_MAX_TURNS} turns (jr=${EFFECTIVE_JR_CODER_MAX_TURNS}, tester=${EFFECTIVE_TESTER_MAX_TURNS})."
    fi
}

# _can_escalate_further
# Returns 0 when escalation is enabled AND the current budget has not hit the cap.
# Used by the recovery branch to decide whether to retry with escalated budget
# instead of falling through to save_exit.
_can_escalate_further() {
    [[ "${REWORK_TURN_ESCALATION_ENABLED:-true}" = "true" ]] || return 1
    local _cap="${REWORK_TURN_MAX_CAP:-${CODER_MAX_TURNS_CAP:-200}}"
    [[ "${EFFECTIVE_CODER_MAX_TURNS:-0}" -lt "$_cap" ]]
}

# --- Smart resume routing (M93) -----------------------------------------------
#
# When the orchestrator hits a save-and-exit, the dumbest possible Resume
# Command is "--start-at coder" — it forces the user to redo work that may
# already have produced a usable artifact. _choose_resume_start_at inspects
# what's on disk (or what was archived at startup) and picks the smartest
# resume point. Side effects: may restore an archived report into place; sets
# _RESUME_NEW_START_AT and (if applicable) _RESUME_RESTORED_ARTIFACT as globals.
# Sets globals (not echo) so file-system + variable side effects share the
# same shell scope as the caller.
_choose_resume_start_at() {
    _RESUME_NEW_START_AT="${START_AT:-coder}"
    _RESUME_RESTORED_ARTIFACT=""

    if [[ -f "${REVIEWER_REPORT_FILE:-/dev/null}" ]]; then
        _RESUME_NEW_START_AT="test"
        return 0
    fi
    if [[ -n "${_ARCHIVED_REVIEWER_REPORT_PATH:-}" ]] && \
       [[ -f "${_ARCHIVED_REVIEWER_REPORT_PATH}" ]] && \
       [[ -n "${REVIEWER_REPORT_FILE:-}" ]]; then
        if cp "${_ARCHIVED_REVIEWER_REPORT_PATH}" "${REVIEWER_REPORT_FILE}" 2>/dev/null; then
            log "[orchestrate] Restored archived REVIEWER_REPORT.md — resume with --start-at test."
            _RESUME_RESTORED_ARTIFACT="REVIEWER_REPORT.md from ${_ARCHIVED_REVIEWER_REPORT_PATH}"
            _RESUME_NEW_START_AT="test"
            return 0
        fi
    fi
    if [[ -f "${TESTER_REPORT_FILE:-/dev/null}" ]]; then
        _RESUME_NEW_START_AT="tester"
        return 0
    fi
    if [[ -n "${_ARCHIVED_TESTER_REPORT_PATH:-}" ]] && \
       [[ -f "${_ARCHIVED_TESTER_REPORT_PATH}" ]] && \
       [[ -n "${TESTER_REPORT_FILE:-}" ]]; then
        if cp "${_ARCHIVED_TESTER_REPORT_PATH}" "${TESTER_REPORT_FILE}" 2>/dev/null; then
            log "[orchestrate] Restored archived TESTER_REPORT.md — resume with --start-at tester."
            _RESUME_RESTORED_ARTIFACT="TESTER_REPORT.md from ${_ARCHIVED_TESTER_REPORT_PATH}"
            _RESUME_NEW_START_AT="tester"
            return 0
        fi
    fi
    return 0
}

# --- State persistence helper -------------------------------------------------

_save_orchestration_state() {
    local outcome="$1"
    local detail="$2"

    _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

    # Run finalize hooks for failure path (metrics, archiving, but no commit)
    finalize_run 1

    # M93: Pick the smartest --start-at given what's on disk / archived.
    # _choose_resume_start_at sets _RESUME_NEW_START_AT and may also set
    # _RESUME_RESTORED_ARTIFACT after copying an archived report back into place.
    _choose_resume_start_at

    # Build resume command with appropriate flags
    local resume_flags="--complete"
    if [[ "$MILESTONE_MODE" = true ]]; then
        resume_flags="--complete --milestone"
    fi
    resume_flags="${resume_flags} --start-at ${_RESUME_NEW_START_AT}"

    # Safety-bound exits (max_attempts, timeout, agent_cap) should write zeroed
    # counters so the next invocation starts with a fresh budget. The counter in
    # the state file is what gets restored on resume — if we write the exhausted
    # value, the next run would immediately re-hit the same bound.
    local _saved_attempt="$_ORCH_ATTEMPT"
    local _saved_calls="$_ORCH_AGENT_CALLS"
    case "$outcome" in
        max_attempts|timeout|agent_cap)
            _ORCH_ATTEMPT=0
            _ORCH_AGENT_CALLS=0
            ;;
    esac

    local _state_notes="Orchestration: ${detail} (attempt ${_saved_attempt}/${MAX_PIPELINE_ATTEMPTS:-5}, ${_ORCH_ELAPSED}s elapsed, ${_saved_calls} agent calls)"
    if [[ -n "${_RESUME_RESTORED_ARTIFACT:-}" ]]; then
        _state_notes="${_state_notes} | Restored ${_RESUME_RESTORED_ARTIFACT}"
    fi

    write_pipeline_state \
        "${START_AT}" \
        "complete_loop_${outcome}" \
        "$resume_flags" \
        "$TASK" \
        "$_state_notes" \
        "${_CURRENT_MILESTONE:-}"

    # Restore for metrics/logging if anything reads them after this
    _ORCH_ATTEMPT="$_saved_attempt"
    _ORCH_AGENT_CALLS="$_saved_calls"

    warn "State saved. Resume with: tekhton ${resume_flags} \"${TASK}\""

    # M94: inline recovery block — always present, zero dependencies.
    if command -v _print_recovery_block &>/dev/null; then
        _print_recovery_block "$outcome" "$detail" \
            "tekhton ${resume_flags} \"${TASK}\"" "$TASK"
    fi
}
