#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_preflight.sh — Pre-finalization preflight fix retry
#
# Extracted from orchestrate_helpers.sh to stay under the 300-line ceiling.
# Sourced by orchestrate.sh after orchestrate_helpers.sh — do not run directly.
# =============================================================================

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
    local _pf_turns="${EFFECTIVE_JR_CODER_MAX_TURNS:-${PREFLIGHT_FIX_MAX_TURNS:-${JR_CODER_MAX_TURNS:-40}}}"
    local _pf_attempt=0

    # Gather changed files for context
    local _pf_changed_files=""
    if [[ -f "${CODER_SUMMARY_FILE}" ]]; then
        _pf_changed_files=$(sed -n '/^## Files/,/^## /p' "${CODER_SUMMARY_FILE}" | grep -E '^\s*[-*]' | head -30 || true)
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
