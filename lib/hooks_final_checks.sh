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

    # ANALYZE_CMD / TEST_CMD live in the target project's pipeline.conf. When
    # the Go bridge runs hooks without loading that config (e.g. on bare
    # directories or partial setups), skip rather than crash on unbound vars.
    if [[ -z "${ANALYZE_CMD:-}" && -z "${TEST_CMD:-}" ]]; then
        warn "Final checks: no ANALYZE_CMD or TEST_CMD configured — skipping."
        return 0
    fi
    if [[ -z "${ANALYZE_CMD:-}" ]]; then
        log "Final checks: no ANALYZE_CMD configured — skipping analyze pass."
        ANALYZE_EXIT=0
        ANALYZE_OUTPUT=""
    else
    log "Running ${ANALYZE_CMD}..."
    set +e
    ANALYZE_OUTPUT=$(run_op "Running final static analysis" bash -c "${ANALYZE_CMD}" 2>&1)
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

        # Re-run analyze to confirm cleanup worked. Capture first so run_op
        # can wrap the long-running analyze command; then filter into the log.
        log "Re-running ${ANALYZE_CMD} after cleanup..."
        local _analyze_recheck
        _analyze_recheck=$(run_op "Re-running static analysis" bash -c "${ANALYZE_CMD}" 2>&1)
        printf '%s\n' "$_analyze_recheck" >> "$log_file"
        if printf '%s\n' "$_analyze_recheck" | grep -qE "^  (error|warning)"; then
            print_run_summary
            error "${ANALYZE_CMD}: warnings or errors remain after cleanup. Review before merging."
            final_result=1
        else
            print_run_summary
            success "${ANALYZE_CMD}: clean after cleanup pass."
        fi
    fi
    fi  # /ANALYZE_CMD configured

    if [[ -z "${TEST_CMD:-}" ]]; then
        log "Final checks: no TEST_CMD configured — skipping test pass."
        return "$final_result"
    fi

    echo
    log "Running ${TEST_CMD}..."
    local test_output=""
    local test_exit=0
    if declare -f test_dedup_can_skip &>/dev/null && test_dedup_can_skip; then
        log "[dedup] Tests passed with no file changes since last run — skipping"
        if command -v emit_event &>/dev/null; then
            emit_event "test_dedup_skip" "${_CURRENT_STAGE:-final_checks}" \
                "fingerprint_match=true" "" "" "" >/dev/null 2>&1 || true
        fi
        test_output="[dedup] Cached pass — no files changed since last successful test run"
        test_exit=0
    else
        set +e
        test_output=$(run_op "Running final test check" bash -c "${TEST_CMD}" 2>&1)
        test_exit=$?
        set -e
        if [[ "$test_exit" -eq 0 ]] && declare -f test_dedup_record_pass &>/dev/null; then
            test_dedup_record_pass
        fi
    fi
    printf '%s\n' "$test_output" | tee -a "$log_file"

    if [ $test_exit -eq 0 ]; then
        print_run_summary
        success "${TEST_CMD}: all passing"
    elif [[ "${FINAL_FIX_ENABLED:-true}" = "true" ]]; then
        # --- Auto-fix loop for test failures ---
        local max_fix_attempts="${FINAL_FIX_MAX_ATTEMPTS:-2}"
        local fix_attempt=0

        # Capture failing test names from the initial run so the fix-loop
        # re-runs ONLY them instead of the full suite (task #40). Matches the
        # ANSI-colored output run_test() emits: "\033[0;31mFAIL\033[0m test_X.sh".
        # Strips trailing notes like "— TIMED OUT after 60s" so just the
        # filename survives.
        local failing_tests=""
        if [[ "${TEST_FIX_FOCUS_ENABLED:-true}" = "true" ]]; then
            failing_tests=$(printf '%s\n' "$test_output" \
                | sed 's/\x1b\[[0-9;]*m//g' \
                | grep -oE '^FAIL[[:space:]]+test_[A-Za-z0-9_]+\.sh' \
                | awk '{print $2}' \
                | sort -u \
                | tr '\n' ' ')
            failing_tests="${failing_tests% }"
            if [[ -n "$failing_tests" ]]; then
                log "[test-fix-focus] Captured failing tests: ${failing_tests}"
            fi
        fi

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

            # Re-run tests to check if fixes worked. When we know the failing
            # set, run only those (TEST_FILES is consumed by run_tests.sh:212).
            # If they all pass, do one full-suite verification below to catch
            # regressions the fix agent might have introduced elsewhere.
            local rerun_label="Re-running final test check"
            if [[ -n "$failing_tests" ]]; then
                rerun_label="Re-running ${failing_tests} (focused)"
                log "Re-running focused tests after test fix: ${failing_tests}"
            else
                log "Re-running ${TEST_CMD} after test fix..."
            fi
            set +e
            test_output=$(TEST_FILES="$failing_tests" run_op "$rerun_label" \
                bash -c "${TEST_CMD}" 2>&1)
            test_exit=$?
            set -e
            printf '%s\n' "$test_output" | tee -a "$log_file"

            # Per #40 step 4: if a focused re-run surfaces new failure names,
            # fold them into the focused set so the next iteration covers
            # everything still red.
            if [[ -n "$failing_tests" ]] && [[ "$test_exit" -ne 0 ]]; then
                local new_failures
                new_failures=$(printf '%s\n' "$test_output" \
                    | grep -oE 'FAIL[^A-Za-z]+test_[A-Za-z0-9_]+\.sh' \
                    | grep -oE 'test_[A-Za-z0-9_]+\.sh' \
                    | sort -u \
                    | tr '\n' ' ')
                new_failures="${new_failures% }"
                if [[ -n "$new_failures" ]] && [[ "$new_failures" != "$failing_tests" ]]; then
                    log "[test-fix-focus] Focused set updated: ${new_failures}"
                    failing_tests="$new_failures"
                fi
            fi
        done

        # Per #40 step 3: when the focused set finally passes, run the full
        # suite ONCE more to catch regressions the fix agent introduced in
        # tests we weren't watching. If that full-suite run fails, the
        # operator sees the new breakage but we don't re-enter the fix loop
        # — that's a deliberate stopping point.
        if [ $test_exit -eq 0 ] && [[ -n "$failing_tests" ]]; then
            log "[test-fix-focus] Focused tests pass — verifying full suite once."
            set +e
            test_output=$(run_op "Full-suite regression check" bash -c "${TEST_CMD}" 2>&1)
            test_exit=$?
            set -e
            printf '%s\n' "$test_output" | tee -a "$log_file"
            if [[ "$test_exit" -ne 0 ]]; then
                warn "[test-fix-focus] Full suite surfaced new failures after focused fixes; stopping."
            fi
        fi

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
