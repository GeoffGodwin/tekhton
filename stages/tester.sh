#!/usr/bin/env bash
# =============================================================================
# stages/tester.sh — Stage 3: Tester (write tests + verify)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, START_AT, etc.)
# =============================================================================

# run_stage_tester — Runs the tester stage:
#   1. Select prompt (fresh vs resume)
#   2. Invoke tester agent
#   3. Handle compilation errors, test failures, partial runs
#   4. Save state for resume if incomplete
#
# On success, TESTER_REPORT.md exists with all items checked.
# Saves state and warns (but does not exit 1) on partial completion.
run_stage_tester() {
    header "Stage 3 / 3 — Tester"

    # Build the tester prompt based on whether we are starting fresh or resuming
    if [ "$START_AT" = "tester" ]; then
        TESTER_PROMPT=$(render_prompt "tester_resume")
    else
        export ARCHITECTURE_CONTENT
        if [ -f "${ARCHITECTURE_FILE}" ]; then
            ARCHITECTURE_CONTENT=$(_wrap_file_content "ARCHITECTURE" "$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")")
        else
            ARCHITECTURE_CONTENT="(${ARCHITECTURE_FILE} not found)"
        fi

        # --- Context compiler (task-scoped filtering) ------------------------
        build_context_packet "tester" "$TASK" "$CLAUDE_TESTER_MODEL"

        # --- Context budget reporting ----------------------------------------
        _add_context_component "Architecture" "$ARCHITECTURE_CONTENT"
        log_context_report "tester" "$CLAUDE_TESTER_MODEL"

        TESTER_PROMPT=$(render_prompt "tester")
    fi

    log "Invoking tester agent (max ${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS} turns)..."
    run_agent \
        "Tester" \
        "$CLAUDE_TESTER_MODEL" \
        "${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}" \
        "$TESTER_PROMPT" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_TESTER"
    export TESTER_EXIT=$?

    # --- UPSTREAM error detection (12.2) ----------------------------------------

    local resume_flag="--start-at test"
    [ "$MILESTONE_MODE" = true ] && resume_flag="--milestone --start-at test"

    if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
        warn "Tester hit an API error (${AGENT_ERROR_SUBCATEGORY}): ${AGENT_ERROR_MESSAGE}"
        write_pipeline_state \
            "tester" \
            "upstream_error" \
            "$resume_flag" \
            "${TASK}" \
            "API error (${AGENT_ERROR_SUBCATEGORY}): ${AGENT_ERROR_MESSAGE}. Re-run the same command."
        warn "State saved — this was an API failure, not a scope issue. Re-run."
        export SKIP_FINAL_CHECKS=true
        return
    fi

    # --- Null run detection ---------------------------------------------------

    if was_null_run; then
        warn "Tester was a null run (${LAST_AGENT_TURNS} turns, exit ${LAST_AGENT_EXIT_CODE})."
        warn "The tester agent died before writing any tests."
        write_pipeline_state \
            "tester" \
            "null_run" \
            "$resume_flag" \
            "${TASK}" \
            "Tester agent used ${LAST_AGENT_TURNS} turn(s) and exited ${LAST_AGENT_EXIT_CODE}. Likely died during discovery. Check logs: ${LOG_FILE}"
        warn "State saved — re-run with: $0 ${resume_flag} \"${TASK}\""
        # Signal to pipeline to skip final checks — no point running cleanup
        # agents or test suites when the tester itself couldn't even start.
        export SKIP_FINAL_CHECKS=true
        return
    fi

    # --- Post-tester validation ----------------------------------------------

    if [ ! -f "TESTER_REPORT.md" ]; then
        warn "Tester did not produce TESTER_REPORT.md."
        warn "Check the log: ${LOG_FILE}"
        warn "Re-run with: $0 --start-at test \"${TASK}\""
    else
        REMAINING=$(grep -c "^- \[ \]" TESTER_REPORT.md || true)
        REMAINING=$(echo "$REMAINING" | tr -d '[:space:]')

        # Check for compilation errors or test failures in the log
        if grep -q "Compilation failed" "$LOG_FILE" || grep -q "Failed to load" "$LOG_FILE"; then
            error "One or more test files failed to compile. The tester report may be inaccurate."
            error "Compilation errors detected in:"
            _failed_paths=$(grep "Compilation failed for testPath=" "$LOG_FILE" | sed 's/.*testPath=/  /' | sed 's/:.*//' | sort -u)
            echo "$_failed_paths"
            warn "Fix the failing test files, then resume with: $0 --start-at tester \"${TASK}\""
            # Mark affected test files as unchecked in TESTER_REPORT.md so resume picks them up
            FAILED_FILES=$(grep "Compilation failed for testPath=" "$LOG_FILE" | sed 's/.*testPath=//' | sed 's/:.*//' | sort -u)
            for FAILED in $FAILED_FILES; do
                BASENAME=$(basename "$FAILED")
                # Flip [x] back to [ ] for the failed file in the report
                sed -i "s|\[x\] \`.*${BASENAME}.*\`|- [ ] \`${BASENAME}\` — COMPILATION FAILED: re-read source models before rewriting|g" TESTER_REPORT.md
            done
            warn "TESTER_REPORT.md updated — failed files reset to unchecked for resume."
        elif grep -qE "^\s+-[0-9]+:" "$LOG_FILE" || grep -q " -[1-9][0-9]*:" "$LOG_FILE"; then
            error "${TEST_CMD} reported failures. Review TESTER_REPORT.md and the log."
            warn "Resume with: $0 --start-at tester \"${TASK}\""
        elif [ "$REMAINING" -gt 0 ]; then
            warn "Tester completed partial run — ${REMAINING} planned test(s) not yet written."

            # --- Turn exhaustion continuation for tester (Milestone 14) ---
            local _tester_continued=false
            if [[ "${CONTINUATION_ENABLED:-true}" = "true" ]]; then
                # Check if substantive test files were created
                local _test_files_created=0
                if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
                    _test_files_created=$(git diff --stat HEAD 2>/dev/null | grep -c '|' || echo "0")
                    _test_files_created=$(echo "$_test_files_created" | tr -d '[:space:]')
                fi

                if [[ "$_test_files_created" -ge 1 ]]; then
                    local _tcont_attempt=0
                    local _tcont_max="${MAX_CONTINUATION_ATTEMPTS:-3}"
                    local _tcumulative_turns="${LAST_AGENT_TURNS:-0}"

                    while [[ "$_tcont_attempt" -lt "$_tcont_max" ]] && [[ "$REMAINING" -gt 0 ]]; do
                        _tcont_attempt=$((_tcont_attempt + 1))
                        log "Tester hit turn limit with ${REMAINING} tests remaining (attempt ${_tcont_attempt}/${_tcont_max}). Continuing..."

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

                    if [[ "$REMAINING" -eq 0 ]]; then
                        _tester_continued=true
                        print_run_summary
                        success "Tester completed after ${_tcont_attempt} continuation(s) — all planned tests written."
                        clear_pipeline_state
                    else
                        warn "Tester still has ${REMAINING} test(s) remaining after ${_tcont_attempt} continuation(s)."
                    fi
                fi
            fi

            if [[ "$_tester_continued" = false ]]; then
                local resume_tester_flag="--start-at tester"
                [ "$MILESTONE_MODE" = true ] && resume_tester_flag="--milestone --start-at tester"

                write_pipeline_state \
                    "tester" \
                    "partial_tests" \
                    "$resume_tester_flag" \
                    "${TASK}" \
                    "${REMAINING} test(s) remaining — TESTER_REPORT.md has the checklist"

                warn "State saved — re-run with no arguments to resume."
            fi
        else
            print_run_summary
            success "Tester agent finished — all planned tests written and passing."
            # Clean run — clear any stale state
            clear_pipeline_state
        fi
    fi
}
