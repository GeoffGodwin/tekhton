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
        next_ms=$(find_next_milestone "$_CURRENT_MILESTONE" "CLAUDE.md")
        if [[ -z "$next_ms" ]]; then
            log "No more milestones to advance to."
            write_milestone_disposition "COMPLETE_AND_WAIT"
            break
        fi

        local next_title
        next_title=$(get_milestone_title "$next_ms")

        if [[ "${AUTO_ADVANCE_CONFIRM:-true}" = "true" ]]; then
            if ! prompt_auto_advance_confirm "$next_ms" "$next_title"; then
                log "Auto-advance declined by user."
                write_milestone_disposition "COMPLETE_AND_WAIT"
                break
            fi
        fi

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

        # Re-enter the complete loop for the new milestone.
        # Recursion depth is bounded by AUTO_ADVANCE_LIMIT (default 3) — the
        # should_auto_advance() guard at the top of this while loop exits once
        # the session count reaches the limit.
        run_complete_loop
        return $?
    done
}

# --- Preflight fix helper (M44) -----------------------------------------------

# _try_preflight_fix PREFLIGHT_OUTPUT PREFLIGHT_EXIT
# Attempts a cheap Jr Coder fix before falling back to a full pipeline retry.
# The shell runs TEST_CMD independently after each fix attempt — the agent
# never sees its own test output.
# Returns 0 if tests pass after fix, 1 if fix attempts exhausted.
_try_preflight_fix() {
    local _pf_output="$1"
    local _pf_exit="$2"

    if [[ "${PREFLIGHT_FIX_ENABLED:-true}" != "true" ]]; then
        return 1
    fi

    local _pf_max="${PREFLIGHT_FIX_MAX_ATTEMPTS:-2}"
    local _pf_model="${PREFLIGHT_FIX_MODEL:-${CLAUDE_JR_CODER_MODEL:-claude-sonnet-4-6}}"
    local _pf_turns="${PREFLIGHT_FIX_MAX_TURNS:-${JR_CODER_MAX_TURNS:-40}}"
    local _pf_attempt=0

    # Gather changed files for context
    local _pf_changed_files=""
    if [[ -f "CODER_SUMMARY.md" ]]; then
        _pf_changed_files=$(sed -n '/^## Files/,/^## /p' CODER_SUMMARY.md | grep -E '^\s*[-*]' | head -30 || true)
    fi
    if [[ -z "$_pf_changed_files" ]]; then
        _pf_changed_files=$(git diff --name-only HEAD 2>/dev/null | head -30 || true)
    fi

    # Capture initial failure signature for regression detection
    # Note: grep pattern counts keyword occurrences and may over-count in test frameworks
    # that print "0 errors" or "no failures found" in passing output. This is accepted
    # because the heuristic uses exit codes for correctness; grep counts only throttle
    # early-abort decisions (see regression check below).
    local _pf_initial_fail_count
    _pf_initial_fail_count=$(printf '%s\n' "$_pf_output" | grep -ciE '(FAIL|ERROR|error|failure)' || echo "0")

    while [[ "$_pf_attempt" -lt "$_pf_max" ]]; do
        _pf_attempt=$(( _pf_attempt + 1 ))
        warn "Pre-finalization fix: Jr Coder attempt ${_pf_attempt}/${_pf_max}..."

        # Emit causal log event if available
        if declare -f emit_event &>/dev/null; then
            emit_event "preflight_fix_start" "preflight_fix" \
                "attempt ${_pf_attempt}/${_pf_max}" "" "" "" > /dev/null 2>&1 || true
        fi

        # Set template variables for prompt rendering
        export PREFLIGHT_TEST_OUTPUT
        PREFLIGHT_TEST_OUTPUT=$(printf '%s\n' "$_pf_output" | tail -120)
        export PREFLIGHT_CHANGED_FILES="$_pf_changed_files"

        local _pf_prompt
        _pf_prompt=$(render_prompt "preflight_fix")

        # Invoke Jr Coder with restricted tools (no Bash test execution)
        run_agent \
            "Preflight Fix (attempt ${_pf_attempt})" \
            "$_pf_model" \
            "$_pf_turns" \
            "$_pf_prompt" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_BUILD_FIX"

        # Shell independently runs TEST_CMD — agent never sees this output
        log "Pre-finalization fix: shell verifying with ${TEST_CMD}..."
        local _pf_verify_exit=0
        local _pf_verify_output=""
        _pf_verify_output=$(bash -c "${TEST_CMD}" 2>&1) || _pf_verify_exit=$?
        printf '%s\n' "$_pf_verify_output" >> "$LOG_FILE"

        if [[ "$_pf_verify_exit" -eq 0 ]]; then
            success "Pre-finalization fix: tests pass after attempt ${_pf_attempt}."
            if declare -f emit_event &>/dev/null; then
                emit_event "preflight_fix_end" "preflight_fix" \
                    "fixed on attempt ${_pf_attempt}" "" "" "" > /dev/null 2>&1 || true
            fi
            return 0
        fi

        # Regression detection: if fix introduced MORE failures, abort immediately
        local _pf_new_fail_count
        _pf_new_fail_count=$(printf '%s\n' "$_pf_verify_output" | grep -ciE '(FAIL|ERROR|error|failure)' || echo "0")
        # The +2 threshold accommodates slight variance in noisy grep counts. Frameworks
        # that print "0 errors" or "no failures found" can shift the count by 1–2 between
        # runs. This prevents aborting on measurement noise while still catching genuine
        # regressions (sustained growth in actual failures).
        if [[ "$_pf_new_fail_count" -gt "$(( _pf_initial_fail_count + 2 ))" ]]; then
            warn "Pre-finalization fix: attempt ${_pf_attempt} introduced new failures (${_pf_new_fail_count} vs ${_pf_initial_fail_count}). Aborting fix loop."
            break
        fi

        # Update output for next iteration
        _pf_output="$_pf_verify_output"
        warn "Pre-finalization fix: attempt ${_pf_attempt} did not resolve failures."
    done

    if declare -f emit_event &>/dev/null; then
        emit_event "preflight_fix_end" "preflight_fix" \
            "exhausted ${_pf_max} attempts" "" "" "" > /dev/null 2>&1 || true
    fi
    warn "Pre-finalization fix: exhausted ${_pf_max} attempts. Falling through to full retry."
    return 1
}

# --- State persistence helper -------------------------------------------------

_save_orchestration_state() {
    local outcome="$1"
    local detail="$2"

    _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

    # Run finalize hooks for failure path (metrics, archiving, but no commit)
    finalize_run 1

    # Build resume command with appropriate flags
    local resume_flags="--complete"
    if [[ "$MILESTONE_MODE" = true ]]; then
        resume_flags="--complete --milestone"
    fi
    resume_flags="${resume_flags} --start-at ${START_AT}"

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

    write_pipeline_state \
        "${START_AT}" \
        "complete_loop_${outcome}" \
        "$resume_flags" \
        "$TASK" \
        "Orchestration: ${detail} (attempt ${_saved_attempt}/${MAX_PIPELINE_ATTEMPTS:-5}, ${_ORCH_ELAPSED}s elapsed, ${_saved_calls} agent calls)" \
        "${_CURRENT_MILESTONE:-}"

    # Restore for metrics/logging if anything reads them after this
    _ORCH_ATTEMPT="$_saved_attempt"
    _ORCH_AGENT_CALLS="$_saved_calls"

    warn "State saved. Resume with: tekhton ${resume_flags} \"${TASK}\""
}
