#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# hooks_final_checks.sh — Final checks (analyze + test) with auto-fix loop
#
# Sourced by tekhton.sh after hooks.sh — do not run directly.
# Expects: ANALYZE_CMD, TEST_CMD, LOG_FILE, render_prompt(), run_agent(),
#          print_run_summary() from caller/libs.
# Provides: run_final_checks()
# =============================================================================

# --- Final checks (analyze + test) -------------------------------------------
#
# Usage:  run_final_checks "$LOG_FILE"
# Runs analyze, optionally spawns a cleanup agent, then runs the test suite.
# Returns: 0 if both clean, 1 if issues remain.
run_final_checks() {
    local log_file="$1"
    local final_result=0

    header "Final Checks"

    log "Running ${ANALYZE_CMD}..."
    set +e
    ANALYZE_OUTPUT=$(bash -c "${ANALYZE_CMD}" 2>&1)
    ANALYZE_EXIT=$?
    set -e
    echo "$ANALYZE_OUTPUT" >> "$log_file"

    if [ $ANALYZE_EXIT -eq 0 ] && ! echo "$ANALYZE_OUTPUT" | grep -qE "^  (warning|error|info)"; then
        print_run_summary
        success "${ANALYZE_CMD}: clean"
    else
        # Count errors vs warnings
        ERROR_COUNT=$(echo "$ANALYZE_OUTPUT" | grep -c "^  error" || true)
        WARN_COUNT=$(echo "$ANALYZE_OUTPUT" | grep -c "^  warning" || true)
        INFO_COUNT=$(echo "$ANALYZE_OUTPUT" | grep -c "^  info" || true)
        ERROR_COUNT=$(echo "$ERROR_COUNT" | tr -d '[:space:]')
        WARN_COUNT=$(echo "$WARN_COUNT" | tr -d '[:space:]')
        INFO_COUNT=$(echo "$INFO_COUNT" | tr -d '[:space:]')

        warn "${ANALYZE_CMD}: ${ERROR_COUNT} error(s), ${WARN_COUNT} warning(s), ${INFO_COUNT} info(s)"

        # Run a jr coder cleanup pass for warnings/infos — senior coder for errors
        CLEANUP_MODEL="$CLAUDE_JR_CODER_MODEL"
        CLEANUP_TURNS="$JR_CODER_MAX_TURNS"
        if [ "$ERROR_COUNT" -gt 0 ]; then
            warn "Errors found — escalating cleanup to senior coder."
            CLEANUP_MODEL="$CLAUDE_CODER_MODEL"
            CLEANUP_TURNS="$CODER_MAX_TURNS"
        fi

        warn "Running analyze cleanup pass (${CLEANUP_MODEL})..."

        export ANALYZE_ISSUES
        ANALYZE_ISSUES=$(echo "$ANALYZE_OUTPUT" | grep -E "^  (error|warning|info)" || true)
        CLEANUP_PROMPT=$(render_prompt "analyze_cleanup")

        local _acl_start="$SECONDS"
        run_agent \
            "Analyze Cleanup" \
            "$CLEANUP_MODEL" \
            "$CLEANUP_TURNS" \
            "$CLEANUP_PROMPT" \
            "$log_file" \
            "$AGENT_TOOLS_CLEANUP"
        # Record analyze_cleanup sub-step (M66)
        if declare -p _STAGE_DURATION &>/dev/null; then
            _STAGE_DURATION["analyze_cleanup"]="$(( SECONDS - _acl_start ))"
            _STAGE_TURNS["analyze_cleanup"]="${LAST_AGENT_TURNS:-0}"
        fi

        # Re-run analyze to confirm cleanup worked
        log "Re-running ${ANALYZE_CMD} after cleanup..."
        if bash -c "${ANALYZE_CMD}" 2>&1 | tee -a "$log_file" | grep -qE "^  (error|warning)"; then
            print_run_summary
            error "${ANALYZE_CMD}: warnings or errors remain after cleanup. Review before merging."
            final_result=1
        else
            print_run_summary
            success "${ANALYZE_CMD}: clean after cleanup pass."
        fi
    fi

    echo
    log "Running ${TEST_CMD}..."
    local test_output=""
    local test_exit=0
    set +e
    test_output=$(bash -c "${TEST_CMD}" 2>&1)
    test_exit=$?
    set -e
    printf '%s\n' "$test_output" | tee -a "$log_file"

    if [ $test_exit -eq 0 ]; then
        print_run_summary
        success "${TEST_CMD}: all passing"
    elif [[ "${FINAL_FIX_ENABLED:-true}" = "true" ]]; then
        # --- Auto-fix loop for test failures ---
        local max_fix_attempts="${FINAL_FIX_MAX_ATTEMPTS:-2}"
        local fix_attempt=0

        while [ $test_exit -ne 0 ] && [ "$fix_attempt" -lt "$max_fix_attempts" ]; do
            fix_attempt=$((fix_attempt + 1))
            warn "${TEST_CMD}: failures detected. Spawning test fix agent (attempt ${fix_attempt}/${max_fix_attempts})..."

            export TEST_FAILURES_CONTENT
            TEST_FAILURES_CONTENT=$(printf '%s' "$test_output" | tail -n 120)
            local test_fix_prompt
            test_fix_prompt=$(render_prompt "test_fix")

            local fix_model="${CLAUDE_CODER_MODEL:-claude-sonnet-4-6}"
            local fix_turns="${FINAL_FIX_MAX_TURNS:-$((CODER_MAX_TURNS / 3))}"

            run_agent \
                "Test Fix (attempt ${fix_attempt})" \
                "$fix_model" \
                "$fix_turns" \
                "$test_fix_prompt" \
                "$log_file" \
                "$AGENT_TOOLS_BUILD_FIX"
            log "Test fix agent finished (attempt ${fix_attempt})."

            # Re-run tests to check if fixes worked
            log "Re-running ${TEST_CMD} after test fix..."
            set +e
            test_output=$(bash -c "${TEST_CMD}" 2>&1)
            test_exit=$?
            set -e
            printf '%s\n' "$test_output" | tee -a "$log_file"
        done

        if [ $test_exit -eq 0 ]; then
            print_run_summary
            success "${TEST_CMD}: all passing after ${fix_attempt} fix attempt(s)."
        else
            print_run_summary
            error "${TEST_CMD}: failures remain after ${fix_attempt} fix attempt(s)."
            final_result=1
        fi
    else
        print_run_summary
        error "${TEST_CMD}: failures detected (see output above)."
        final_result=1
    fi

    return $final_result
}
