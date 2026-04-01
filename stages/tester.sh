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
    local _stage_count="${PIPELINE_STAGE_COUNT:-4}"
    local _stage_pos="${PIPELINE_STAGE_POS:-$_stage_count}"
    header "Stage ${_stage_pos} / ${_stage_count} — Tester${TESTER_MODE:+ (${TESTER_MODE})}"

    # --- TDD write_failing mode (Milestone 27) --------------------------------
    # In test_first pipeline order, the first tester pass writes failing tests.
    # Uses a dedicated prompt and outputs TESTER_PREFLIGHT.md instead of
    # TESTER_REPORT.md. Skips the test pass gate (tests are expected to fail).
    if [[ "${TESTER_MODE:-verify_passing}" == "write_failing" ]]; then
        _run_tester_write_failing
        return
    fi

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

        # Repo map slice: changed files + test counterparts
        export REPO_MAP_CONTENT=""
        if [[ "${INDEXER_AVAILABLE:-false}" == "true" ]] && [[ "${REPO_MAP_ENABLED:-false}" == "true" ]]; then
            local _tester_files
            _tester_files=$(extract_files_from_coder_summary "CODER_SUMMARY.md")
            if [[ -n "$_tester_files" ]]; then
                # Augment with inferred test file counterparts
                _tester_files=$(infer_test_counterparts "$_tester_files")
                # Ensure we have a map to slice from
                if [[ -z "${REPO_MAP_CONTENT:-}" ]]; then
                    run_repo_map "$TASK" || true
                fi
                if [[ -n "$REPO_MAP_CONTENT" ]]; then
                    local _tester_slice
                    if _tester_slice=$(get_repo_map_slice "$_tester_files"); then
                        REPO_MAP_CONTENT="$_tester_slice"
                        log "[indexer] Repo map sliced for tester (changed files + test counterparts)."
                    fi
                fi
            fi
        fi

        # --- Context compiler (task-scoped filtering) ------------------------
        build_context_packet "tester" "$TASK" "$CLAUDE_TESTER_MODEL"

        # --- UI test guidance (Milestone 28) ----------------------------------
        export TESTER_UI_GUIDANCE=""
        if [[ "${UI_PROJECT_DETECTED:-false}" == "true" ]]; then
            # Set framework-specific conditional flags for the sub-template
            export UI_FRAMEWORK_IS_PLAYWRIGHT="" UI_FRAMEWORK_IS_CYPRESS=""
            export UI_FRAMEWORK_IS_SELENIUM="" UI_FRAMEWORK_IS_PUPPETEER=""
            export UI_FRAMEWORK_IS_TESTING_LIBRARY="" UI_FRAMEWORK_IS_DETOX=""
            export UI_FRAMEWORK_IS_GENERIC=""
            case "${UI_FRAMEWORK:-}" in
                playwright)       UI_FRAMEWORK_IS_PLAYWRIGHT="true" ;;
                cypress)          UI_FRAMEWORK_IS_CYPRESS="true" ;;
                selenium)         UI_FRAMEWORK_IS_SELENIUM="true" ;;
                puppeteer)        UI_FRAMEWORK_IS_PUPPETEER="true" ;;
                testing-library)  UI_FRAMEWORK_IS_TESTING_LIBRARY="true" ;;
                detox)            UI_FRAMEWORK_IS_DETOX="true" ;;
                *)                UI_FRAMEWORK_IS_GENERIC="true" ;;
            esac
            TESTER_UI_GUIDANCE=$(render_prompt "tester_ui_guidance" 2>/dev/null || true)
        fi

        # --- Context budget reporting ----------------------------------------
        _add_context_component "Architecture" "$ARCHITECTURE_CONTENT"
        _add_context_component "Repo Map" "${REPO_MAP_CONTENT:-}"
        log_context_report "tester" "$CLAUDE_TESTER_MODEL"

        _phase_start "tester_prompt"
        TESTER_PROMPT=$(render_prompt "tester")
        _phase_end "tester_prompt"
    fi

    # --- Tester diagnostics: pre-invocation snapshot ----------------------------
    local _tester_stage_start
    _tester_stage_start=$(date +%s)
    local _tester_prompt_chars=${#TESTER_PROMPT}
    local _tester_prompt_tokens=$(( (_tester_prompt_chars + 3) / 4 ))
    local _tester_turn_budget="${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}"
    log "[tester-diag] Prompt: ${_tester_prompt_chars} chars (~${_tester_prompt_tokens} tokens)"
    log "[tester-diag] Turn budget: ${_tester_turn_budget} | Model: ${CLAUDE_TESTER_MODEL}"
    if [[ "$START_AT" = "tester" ]]; then
        log "[tester-diag] Mode: RESUME (tester_resume prompt)"
    else
        log "[tester-diag] Mode: FRESH (full tester prompt)"
    fi

    log "Invoking tester agent (max ${_tester_turn_budget} turns)..."
    _phase_start "tester_agent"
    run_agent \
        "Tester" \
        "$CLAUDE_TESTER_MODEL" \
        "$_tester_turn_budget" \
        "$TESTER_PROMPT" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_TESTER"
    _phase_end "tester_agent"
    export TESTER_EXIT=$?

    # --- Tester diagnostics: post-invocation summary ----------------------------
    local _tester_agent_end
    _tester_agent_end=$(date +%s)
    local _tester_agent_elapsed=$(( _tester_agent_end - _tester_stage_start ))
    local _tester_agent_mins=$(( _tester_agent_elapsed / 60 ))
    local _tester_agent_secs=$(( _tester_agent_elapsed % 60 ))
    log "[tester-diag] Primary invocation: ${LAST_AGENT_TURNS}/${_tester_turn_budget} turns, ${_tester_agent_mins}m${_tester_agent_secs}s, exit=${LAST_AGENT_EXIT_CODE}"

    # --- UPSTREAM error detection (12.2) ----------------------------------------

    local resume_flag
    resume_flag="$(_build_resume_flag test)"

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
        # Check if test files were created despite missing report
        local _test_file_count=0
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            _test_file_count=$(git diff --name-only HEAD 2>/dev/null | grep -ciE 'test|spec' || echo "0")
        fi
        if [[ "$_test_file_count" -gt 0 ]]; then
            warn "Tester created ${_test_file_count} test file(s) but no report — synthesizing minimal TESTER_REPORT.md."
            local _test_files
            _test_files=$(git diff --name-only HEAD 2>/dev/null | grep -iE 'test|spec' | head -20 || true)
            cat > TESTER_REPORT.md <<TESTER_EOF
## Test Summary
TESTER_REPORT.md was synthesized by the pipeline. The tester agent created
test files but did not produce a report. Review the test files directly.

## Test Files Created
$(echo "$_test_files" | sed 's/^/- [x] `/' | sed 's/$/`/')

## Bugs Found
- None reported (tester did not produce a structured report)
TESTER_EOF
        else
            warn "Check the log: ${LOG_FILE}"
            warn "Re-run with: $0 --start-at test \"${TASK}\""
        fi
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
            # --- Auto-fix on test failure (opt-in) --------------------------------
            if [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] \
               && [[ "${TEKHTON_FIX_DEPTH:-0}" -lt "${TESTER_FIX_MAX_DEPTH:-1}" ]]; then
                local _fix_depth="${TEKHTON_FIX_DEPTH:-0}"
                local _max_depth="${TESTER_FIX_MAX_DEPTH:-1}"
                local _output_limit="${TESTER_FIX_OUTPUT_LIMIT:-4000}"
                warn "${TEST_CMD} reported failures. Auto-fix enabled (depth ${_fix_depth}/${_max_depth}) — seeding fix run."

                # Capture test failure output from log (truncate to limit)
                local _failure_output
                _failure_output=$(grep -E '(FAIL|ERROR|error|failure|assert)' "$LOG_FILE" | tail -c "$_output_limit" || true)
                if [[ -z "$_failure_output" ]]; then
                    _failure_output=$(tail -100 "$LOG_FILE" | tail -c "$_output_limit")
                fi

                # Spawn fix run with incremented depth
                local _fix_task
                _fix_task="Fix failing tests from previous pipeline run:
${_failure_output}"
                log "[auto-fix] Invoking fix run (depth $((_fix_depth + 1))/${_max_depth})..."
                local _fix_exit=0
                TEKHTON_FIX_DEPTH=$((_fix_depth + 1)) \
                    bash "${TEKHTON_HOME}/tekhton.sh" "$_fix_task" || _fix_exit=$?

                if [[ "$_fix_exit" -eq 0 ]]; then
                    success "Auto-fix run succeeded — test failures resolved."
                    # Prevent duplicate finalization: child pipeline already ran its
                    # own finalize phase (archive reports, commit prompt, etc.).
                    export SKIP_FINAL_CHECKS=true
                    clear_pipeline_state
                else
                    error "Auto-fix run failed (exit ${_fix_exit}). Original test failures remain."
                    warn "Resume with: $0 --start-at tester \"${TASK}\""
                fi
            else
                error "${TEST_CMD} reported failures. Review TESTER_REPORT.md and the log."
                if [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]]; then
                    warn "Auto-fix depth limit reached (${TEKHTON_FIX_DEPTH:-0}/${TESTER_FIX_MAX_DEPTH:-1}). No further recursion."
                fi
                warn "Resume with: $0 --start-at tester \"${TASK}\""
            fi
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
                    log "[tester-diag] Entering continuation loop: ${REMAINING} tests remaining, max ${_tcont_max} continuations"

                    while [[ "$_tcont_attempt" -lt "$_tcont_max" ]] && [[ "$REMAINING" -gt 0 ]]; do
                        _tcont_attempt=$((_tcont_attempt + 1))
                        local _tcont_start
                        _tcont_start=$(date +%s)
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
                        _tester_continued=true
                        print_run_summary
                        success "Tester completed after ${_tcont_attempt} continuation(s) — all planned tests written."
                        clear_pipeline_state

                        # --- Test integrity audit (M20) ---
                        run_test_audit || true
                    else
                        warn "Tester still has ${REMAINING} test(s) remaining after ${_tcont_attempt} continuation(s)."
                    fi
                fi
            fi

            if [[ "$_tester_continued" = false ]]; then
                local resume_tester_flag
                resume_tester_flag="$(_build_resume_flag tester)"

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

            # --- Test integrity audit (M20) ---
            run_test_audit || true
        fi
    fi

    # --- Tester diagnostics: final stage summary --------------------------------
    local _tester_stage_end
    _tester_stage_end=$(date +%s)
    local _tester_total_elapsed=$(( _tester_stage_end - _tester_stage_start ))
    local _tester_total_mins=$(( _tester_total_elapsed / 60 ))
    local _tester_total_secs=$(( _tester_total_elapsed % 60 ))
    local _tester_test_count=0
    if [[ -f "TESTER_REPORT.md" ]]; then
        _tester_test_count=$(grep -c '^- \[' TESTER_REPORT.md || true)
    fi
    log "[tester-diag] === Stage Complete ==="
    log "[tester-diag] Total wall-clock: ${_tester_total_mins}m${_tester_total_secs}s"
    log "[tester-diag] Test items in report: ${_tester_test_count}"
    log "[tester-diag] Prompt size: ${_tester_prompt_chars:-0} chars (~${_tester_prompt_tokens:-0} tokens)"
    log "[tester-diag] Turn budget: ${_tester_turn_budget:-?} | Turns used (primary): ${LAST_AGENT_TURNS:-?}"
}

# _run_tester_write_failing — TDD pre-flight: write tests that should fail.
# Uses tester_write_failing.prompt.md. Outputs TESTER_PREFLIGHT.md.
# Does NOT enforce test pass gate — tests are expected to fail.
_run_tester_write_failing() {
    local _preflight_file="${TDD_PREFLIGHT_FILE:-TESTER_PREFLIGHT.md}"
    local _max_turns="${TESTER_WRITE_FAILING_MAX_TURNS:-10}"

    # Architecture content for the prompt
    export ARCHITECTURE_CONTENT
    if [[ -f "${ARCHITECTURE_FILE:-}" ]]; then
        ARCHITECTURE_CONTENT=$(_wrap_file_content "ARCHITECTURE" "$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")")
    else
        ARCHITECTURE_CONTENT="(${ARCHITECTURE_FILE:-ARCHITECTURE.md} not found)"
    fi

    # Repo map for TDD tester (scout-identified files)
    export REPO_MAP_CONTENT="${REPO_MAP_CONTENT:-}"
    if [[ "${INDEXER_AVAILABLE:-false}" == "true" ]] && [[ "${REPO_MAP_ENABLED:-false}" == "true" ]]; then
        if [[ -z "$REPO_MAP_CONTENT" ]]; then
            run_repo_map "$TASK" || true
        fi
    fi

    # Milestone context for acceptance criteria
    export MILESTONE_BLOCK="${MILESTONE_BLOCK:-}"

    # Context budget reporting
    build_context_packet "tester_write_failing" "$TASK" "$CLAUDE_TESTER_MODEL"
    _add_context_component "Architecture" "$ARCHITECTURE_CONTENT"
    _add_context_component "Repo Map" "${REPO_MAP_CONTENT:-}"
    _add_context_component "Milestone" "${MILESTONE_BLOCK:-}"
    log_context_report "tester_write_failing" "$CLAUDE_TESTER_MODEL"

    local _tdd_prompt
    _tdd_prompt=$(render_prompt "tester_write_failing")

    # --- TDD diagnostics: pre-invocation snapshot ---
    local _tdd_stage_start
    _tdd_stage_start=$(date +%s)
    local _tdd_prompt_chars=${#_tdd_prompt}
    local _tdd_prompt_tokens=$(( (_tdd_prompt_chars + 3) / 4 ))
    log "[tester-diag] Prompt: ${_tdd_prompt_chars} chars (~${_tdd_prompt_tokens} tokens)"
    log "[tester-diag] Turn budget: ${_max_turns} | Model: ${CLAUDE_TESTER_MODEL}"

    log "Invoking TDD tester agent (write failing tests, max ${_max_turns} turns)..."
    run_agent \
        "Tester (TDD pre-flight)" \
        "$CLAUDE_TESTER_MODEL" \
        "$_max_turns" \
        "$_tdd_prompt" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_TESTER"
    print_run_summary

    # --- TDD diagnostics: post-invocation summary ---
    local _tdd_agent_end
    _tdd_agent_end=$(date +%s)
    local _tdd_agent_elapsed=$(( _tdd_agent_end - _tdd_stage_start ))
    local _tdd_agent_mins=$(( _tdd_agent_elapsed / 60 ))
    local _tdd_agent_secs=$(( _tdd_agent_elapsed % 60 ))
    log "[tester-diag] TDD invocation: ${LAST_AGENT_TURNS}/${_max_turns} turns, ${_tdd_agent_mins}m${_tdd_agent_secs}s, exit=${LAST_AGENT_EXIT_CODE}"

    # --- UPSTREAM error check (API failures) ---
    if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
        warn "TDD tester hit an API error (${AGENT_ERROR_SUBCATEGORY:-unknown}): ${AGENT_ERROR_MESSAGE:-unknown}"
        local _tdd_resume_flag
        _tdd_resume_flag="$(_build_resume_flag test)"
        write_pipeline_state \
            "tester" \
            "TDD pre-flight API error: ${AGENT_ERROR_SUBCATEGORY:-unknown}" \
            "$_tdd_resume_flag" \
            "$TASK" \
            "UPSTREAM error during TDD write-failing phase"
        export SKIP_FINAL_CHECKS=true
        return
    fi

    # --- Null run detection ---
    if was_null_run; then
        warn "TDD tester was a null run — falling back. Coder will proceed without pre-written tests."
        return
    fi

    # --- Validate output ---
    if [[ -f "$_preflight_file" ]]; then
        success "TDD pre-flight complete — ${_preflight_file} written."
        # Archive for the run log
        cp "$_preflight_file" "${LOG_DIR}/${TIMESTAMP}_TESTER_PREFLIGHT.md"
    else
        warn "TDD tester did not produce ${_preflight_file}. Coder will proceed without pre-written tests."
    fi

    # --- TDD stage complete summary ---
    local _tdd_stage_end
    _tdd_stage_end=$(date +%s)
    local _tdd_total_elapsed=$(( _tdd_stage_end - _tdd_stage_start ))
    local _tdd_total_mins=$(( _tdd_total_elapsed / 60 ))
    local _tdd_total_secs=$(( _tdd_total_elapsed % 60 ))
    log "[tester-diag] TDD write-failing stage complete: ${_tdd_total_mins}m${_tdd_total_secs}s, model=${CLAUDE_TESTER_MODEL}, turns=${LAST_AGENT_TURNS}"
}
