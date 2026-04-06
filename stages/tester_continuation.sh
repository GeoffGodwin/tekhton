#!/usr/bin/env bash
# =============================================================================
# stages/tester_continuation.sh — Tester turn-exhaustion continuation loop
#
# Sourced by tekhton.sh after tester.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, etc.)
# Provides: _tester_run_continuations()
# =============================================================================

set -euo pipefail

# _run_and_record_test_audit — Run test integrity audit and record timing.
# Shared by tester.sh (clean completion) and _tester_run_continuations (continuation success).
_run_and_record_test_audit() {
    local _audit_start="$SECONDS"
    run_test_audit || true
    if declare -p _STAGE_DURATION &>/dev/null; then
        _STAGE_DURATION["test_audit"]="$(( SECONDS - _audit_start ))"
        _STAGE_TURNS["test_audit"]="${LAST_AGENT_TURNS:-0}"
    fi
}

# _tester_run_continuations — Run tester continuation loop when tests remain.
# Args: $1 = resume_flag, $2 = _tester_stage_start timestamp
# Reads/writes: REMAINING (global), SKIP_FINAL_CHECKS
# Sets: _TESTER_CONTINUED (global) to "true" if all tests completed
_tester_run_continuations() {
    local resume_flag="$1"
    local _tester_stage_start="$2"
    _TESTER_CONTINUED=false

    if [[ "${CONTINUATION_ENABLED:-true}" != "true" ]]; then
        return
    fi

    # Check if substantive test files were created
    local _test_files_created=0
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        _test_files_created=$(git diff --stat HEAD 2>/dev/null | grep -c '|' || echo "0")
        _test_files_created=$(echo "$_test_files_created" | tr -d '[:space:]')
    fi

    if [[ "$_test_files_created" -lt 1 ]]; then
        return
    fi

    local _tcont_attempt=0
    local _tcont_max="${MAX_CONTINUATION_ATTEMPTS:-3}"
    local _tcumulative_turns="${LAST_AGENT_TURNS:-0}"
    log "[tester-diag] Entering continuation loop: ${REMAINING} tests remaining, max ${_tcont_max} continuations"

    while [[ "$_tcont_attempt" -lt "$_tcont_max" ]] && [[ "$REMAINING" -gt 0 ]]; do
        _tcont_attempt=$((_tcont_attempt + 1))
        local _tcont_start
        _tcont_start=$(date +%s)
        log_decision "Continuing tester" "turn limit hit, ${REMAINING} tests remaining (attempt ${_tcont_attempt}/${_tcont_max})" "CONTINUATION_ENABLED=true"

        local _tnext_budget="${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}"
        export CONTINUATION_CONTEXT
        CONTINUATION_CONTEXT=$(build_continuation_context "tester" "$_tcont_attempt" "$_tcont_max" "$_tcumulative_turns" "$_tnext_budget")

        TESTER_PROMPT=$(render_prompt "tester_resume")

        run_agent \
            "Tester (continuation ${_tcont_attempt})" \
            "$CLAUDE_TESTER_MODEL" \
            "$_tnext_budget" \
            "$TESTER_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_TESTER"

        _tcumulative_turns=$((_tcumulative_turns + ${LAST_AGENT_TURNS:-0}))

        # --- M62: Accumulate tester self-reported timing from continuation ---
        _parse_tester_timing "TESTER_REPORT.md" "accumulate"

        # --- Tester diagnostics: continuation timing ----------------
        local _tcont_end
        _tcont_end=$(date +%s)
        local _tcont_elapsed=$(( _tcont_end - _tcont_start ))
        local _tcont_mins=$(( _tcont_elapsed / 60 ))
        local _tcont_secs=$(( _tcont_elapsed % 60 ))
        log "[tester-diag] Continuation ${_tcont_attempt}: ${LAST_AGENT_TURNS:-0} turns, ${_tcont_mins}m${_tcont_secs}s, cumulative=${_tcumulative_turns} turns"

        # Check for API errors
        if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
            warn "Tester continuation hit API error. Saving state."
            export CONTINUATION_ATTEMPTS="${_tcont_attempt}"
            export CONTINUATION_CONTEXT=""
            write_pipeline_state \
                "tester" \
                "upstream_error" \
                "$resume_flag" \
                "${TASK}" \
                "API error during tester continuation ${_tcont_attempt}."
            export SKIP_FINAL_CHECKS=true
            return
        fi

        # Re-check remaining tests
        if [[ -f "TESTER_REPORT.md" ]]; then
            REMAINING=$(grep -c "^- \[ \]" TESTER_REPORT.md || true)
            REMAINING=$(echo "$REMAINING" | tr -d '[:space:]')
        fi
    done

    export CONTINUATION_ATTEMPTS="${_tcont_attempt}"
    export CONTINUATION_CONTEXT=""

    # --- Tester diagnostics: continuation loop summary ----------
    local _tcont_loop_end
    _tcont_loop_end=$(date +%s)
    local _tcont_loop_elapsed=$(( _tcont_loop_end - _tester_stage_start ))
    local _tcont_loop_mins=$(( _tcont_loop_elapsed / 60 ))
    local _tcont_loop_secs=$(( _tcont_loop_elapsed % 60 ))
    log "[tester-diag] Stage total so far: ${_tcumulative_turns} turns across $((1 + _tcont_attempt)) invocations, ${_tcont_loop_mins}m${_tcont_loop_secs}s wall-clock"

    if [[ "$REMAINING" -eq 0 ]]; then
        _TESTER_CONTINUED=true
        print_run_summary
        success "Tester completed after ${_tcont_attempt} continuation(s) — all planned tests written."
        clear_pipeline_state

        # --- Test integrity audit (M20) ---
        _run_and_record_test_audit
    else
        warn "Tester still has ${REMAINING} test(s) remaining after ${_tcont_attempt} continuation(s)."
    fi
}
