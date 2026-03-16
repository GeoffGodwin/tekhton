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

    # --- SIGKILL retry --------------------------------------------------------
    # Exit 137 (SIGKILL) is typically OOM in WSL2. Retry once after a cooldown
    # to give the system time to reclaim memory.

    if was_null_run && [ "$LAST_AGENT_EXIT_CODE" -eq 137 ]; then
        warn "SIGKILL detected — retrying tester in 15 seconds..."
        sleep 15
        run_agent \
            "Tester (retry)" \
            "$CLAUDE_TESTER_MODEL" \
            "${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}" \
            "$TESTER_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_TESTER"
        TESTER_EXIT=$?  # exported above
    fi

    # --- Null run detection ---------------------------------------------------

    local resume_flag="--start-at test"
    [ "$MILESTONE_MODE" = true ] && resume_flag="--milestone --start-at test"

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
            grep "Compilation failed for testPath=" "$LOG_FILE" | sed 's/.*testPath=/  /' | sed 's/:.*//' | sort -u | tee -a "$LOG_FILE"
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

            local resume_tester_flag="--start-at tester"
            [ "$MILESTONE_MODE" = true ] && resume_tester_flag="--milestone --start-at tester"

            write_pipeline_state \
                "tester" \
                "partial_tests" \
                "$resume_tester_flag" \
                "${TASK}" \
                "${REMAINING} test(s) remaining — TESTER_REPORT.md has the checklist"

            warn "State saved — re-run with no arguments to resume."
        else
            print_run_summary
            success "Tester agent finished — all planned tests written and passing."
            # Clean run — clear any stale state
            clear_pipeline_state
        fi
    fi
}
