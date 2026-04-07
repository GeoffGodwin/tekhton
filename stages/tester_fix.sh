#!/usr/bin/env bash
# =============================================================================
# stages/tester_fix.sh — Inline tester fix agent (M64)
#
# Sourced by tekhton.sh after tester.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, etc.)
# Provides: _smart_truncate_test_output(), _truncate_block(),
#           _run_tester_inline_fix()
# =============================================================================

set -euo pipefail

# _smart_truncate_test_output — Extract failure-relevant lines from test output.
# Prioritizes actual error messages over stack traces. Splits by failure markers,
# keeps first 5 and last 5 lines of each block, caps at char limit.
# Args: $1 = raw output, $2 = char limit (default: 4000)
# Stdout: truncated output
_smart_truncate_test_output() {
    local output="$1"
    local limit="${2:-4000}"

    [[ -z "$output" ]] && return 0

    # Split into failure blocks at common markers, keep error-relevant lines
    local result=""
    local block=""
    local in_block=false

    while IFS= read -r line; do
        # Detect failure block start
        if [[ "$line" =~ (FAIL|FAILED|ERROR|AssertionError|TypeError|ReferenceError|SyntaxError|CompilationError|assert|expected|unexpected) ]]; then
            if [[ "$in_block" == true ]] && [[ -n "$block" ]]; then
                # Emit previous block (first 5 + last 5 lines)
                result+=$(_truncate_block "$block")
                result+=$'\n---\n'
            fi
            block="$line"$'\n'
            in_block=true
        elif [[ "$in_block" == true ]]; then
            block+="$line"$'\n'
        fi
    done <<< "$output"

    # Emit final block
    if [[ -n "$block" ]]; then
        result+=$(_truncate_block "$block")
    fi

    # If no failure blocks found, fall back to tail
    if [[ -z "$result" ]]; then
        result=$(printf '%s' "$output" | tail -80)
    fi

    # Cap at char limit
    if [[ ${#result} -gt $limit ]]; then
        result="${result:0:$limit}
... [truncated at ${limit} chars]"
    fi

    printf '%s' "$result"
}

# _truncate_block — Keep first 5 and last 5 lines of a failure block.
# Args: $1 = block text
_truncate_block() {
    local block="$1"
    local line_count
    line_count=$(printf '%s' "$block" | wc -l | tr -d '[:space:]')

    if [[ "$line_count" -le 10 ]]; then
        printf '%s' "$block"
        return
    fi

    local head tail
    head=$(printf '%s' "$block" | head -5)
    tail=$(printf '%s' "$block" | tail -5)
    printf '%s\n  ... [%d lines omitted]\n%s' "$head" "$((line_count - 10))" "$tail"
}

# _run_tester_inline_fix — Inline fix agent loop for test failures (M64).
# Replaces the recursive pipeline spawn with a lightweight agent that
# fixes test code only. Follows the coder.sh build-fix pattern.
_run_tester_inline_fix() {
    local _fix_attempt=0
    local _max_attempts="${TESTER_FIX_MAX_DEPTH:-1}"
    local _output_limit="${TESTER_FIX_OUTPUT_LIMIT:-4000}"

    log_decision "Inline tester fix" \
        "${TEST_CMD} failures detected" \
        "TESTER_FIX_ENABLED=true, max_attempts=${_max_attempts}"

    while [[ "$_fix_attempt" -lt "$_max_attempts" ]]; do
        _fix_attempt=$((_fix_attempt + 1))

        # Extract failure output with smart truncation
        local _raw_output
        _raw_output=$(grep -E '(FAIL|ERROR|error|failure|assert|expected|unexpected)' \
            "$LOG_FILE" 2>/dev/null | tail -c "$((_output_limit * 2))" || true)
        if [[ -z "$_raw_output" ]]; then
            _raw_output=$(tail -100 "$LOG_FILE" | tail -c "$((_output_limit * 2))")
        fi

        local _failure_output
        _failure_output=$(_smart_truncate_test_output "$_raw_output" "$_output_limit")

        # Baseline-aware gating (M63): skip fix if all failures are pre-existing
        if [[ "${TEST_BASELINE_ENABLED:-true}" == "true" ]] \
           && declare -f has_test_baseline &>/dev/null \
           && declare -f compare_test_with_baseline &>/dev/null \
           && has_test_baseline 2>/dev/null; then
            local _tfix_comparison
            _tfix_comparison=$(compare_test_with_baseline "$_failure_output" "1")
            if [[ "$_tfix_comparison" == "pre_existing" ]]; then
                log "All test failures are pre-existing — skipping tester fix."
                return
            fi
        fi

        # Build scoped context for the fix agent
        export TESTER_FIX_OUTPUT="$_failure_output"

        # Extract test file paths from failure output
        export TESTER_FIX_TEST_FILES=""
        local _test_paths
        _test_paths=$(printf '%s' "$_failure_output" | \
            grep -oE '[a-zA-Z0-9_./-]+\.(test|spec)\.[a-zA-Z]+' | sort -u || true)
        if [[ -n "$_test_paths" ]]; then
            TESTER_FIX_TEST_FILES="$_test_paths"
        fi

        # Extract source files from CODER_SUMMARY.md
        export TESTER_FIX_SOURCE_FILES=""
        if [[ -f "CODER_SUMMARY.md" ]] \
           && declare -f extract_files_from_coder_summary &>/dev/null; then
            TESTER_FIX_SOURCE_FILES=$(extract_files_from_coder_summary "CODER_SUMMARY.md" 2>/dev/null || true)
        fi

        # Render scoped prompt and run inline agent
        _phase_start "tester_fix"
        local _fix_prompt
        _fix_prompt=$(render_prompt "tester_fix")
        log "[tester-fix] Attempt ${_fix_attempt}/${_max_attempts} (max ${TESTER_FIX_MAX_TURNS} turns)..."
        run_agent "Tester (fix ${_fix_attempt})" \
            "$CLAUDE_CODER_MODEL" \
            "${TESTER_FIX_MAX_TURNS}" \
            "$_fix_prompt" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_BUILD_FIX"
        _phase_end "tester_fix"

        # Log fix attempt in causal log
        if declare -f emit_event &>/dev/null; then
            emit_event "tester_fix_attempt" "tester" \
                "attempt=${_fix_attempt} exit=${LAST_AGENT_EXIT_CODE:-0} turns=${LAST_AGENT_TURNS:-0}"
        fi

        # Check if fix succeeded — re-run test command
        local _retest_exit=0
        if [[ -n "${TEST_CMD:-}" ]]; then
            log "[tester-fix] Re-running ${TEST_CMD} to verify fix..."
            eval "${TEST_CMD}" >> "$LOG_FILE" 2>&1 || _retest_exit=$?
            if [[ "$_retest_exit" -eq 0 ]]; then
                success "Tester fix attempt ${_fix_attempt} resolved all test failures."
                return
            fi
            warn "Tests still failing after fix attempt ${_fix_attempt} (exit ${_retest_exit})."
        else
            # No TEST_CMD — can't verify, break after single attempt
            break
        fi
    done

    if [[ "$_fix_attempt" -ge "$_max_attempts" ]]; then
        error "Tester fix exhausted ${_max_attempts} attempt(s). Test failures remain."
    fi
    warn "Resume with: $0 --start-at tester \"${TASK}\""
}
