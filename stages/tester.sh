#!/usr/bin/env bash
# =============================================================================
# stages/tester.sh — Stage 3: Tester (write tests + verify)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, START_AT, etc.)
# =============================================================================

set -euo pipefail

# --- Tester timing globals (M62) ---
# These are accumulated across continuations and consumed by finalize_summary.sh.
_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1
_TESTER_TIMING_WRITING_S=-1

# _parse_tester_timing — Extract timing data from TESTER_REPORT.md.
# Reads the ## Timing section and populates _TESTER_TIMING_* globals.
# If section is missing or unparseable, values remain -1.
# Args: $1 = path to TESTER_REPORT.md (default: TESTER_REPORT.md)
#       $2 = "accumulate" to add to existing values (for continuations)
_parse_tester_timing() {
    local report="${1:-TESTER_REPORT.md}"
    local mode="${2:-replace}"

    [[ -f "$report" ]] || return 0

    # Extract the ## Timing section (must be at end of file per milestone spec)
    local timing_block
    timing_block=$(sed -n '/^## Timing$/,$ p' "$report" 2>/dev/null || true)
    [[ -n "$timing_block" ]] || return 0

    # Parse each field with defensive regex
    local _exec_count _exec_time _files_written
    _exec_count=$(echo "$timing_block" | grep -oiE 'Test executions:\s*([0-9]+)' | grep -oE '[0-9]+' | tail -1 || true)
    _exec_time=$(echo "$timing_block" | grep -oiE 'Approximate total test execution time:\s*~?([0-9]+)' | grep -oE '[0-9]+' | tail -1 || true)
    _files_written=$(echo "$timing_block" | grep -oiE 'Test files written:\s*([0-9]+)' | grep -oE '[0-9]+' | tail -1 || true)

    # Validate: must be numeric
    [[ "$_exec_count" =~ ^[0-9]+$ ]] || _exec_count=""
    [[ "$_exec_time" =~ ^[0-9]+$ ]] || _exec_time=""
    [[ "$_files_written" =~ ^[0-9]+$ ]] || _files_written=""

    if [[ "$mode" == "accumulate" ]]; then
        # Accumulate: add to running totals (only if current value is valid)
        if [[ -n "$_exec_count" ]]; then
            if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq -1 ]]; then
                _TESTER_TIMING_EXEC_COUNT="$_exec_count"
            else
                _TESTER_TIMING_EXEC_COUNT=$(( _TESTER_TIMING_EXEC_COUNT + _exec_count ))
            fi
        fi
        if [[ -n "$_exec_time" ]]; then
            if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq -1 ]]; then
                _TESTER_TIMING_EXEC_APPROX_S="$_exec_time"
            else
                _TESTER_TIMING_EXEC_APPROX_S=$(( _TESTER_TIMING_EXEC_APPROX_S + _exec_time ))
            fi
        fi
        if [[ -n "$_files_written" ]]; then
            if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq -1 ]]; then
                _TESTER_TIMING_FILES_WRITTEN="$_files_written"
            else
                _TESTER_TIMING_FILES_WRITTEN=$(( _TESTER_TIMING_FILES_WRITTEN + _files_written ))
            fi
        fi
    else
        # Replace mode: set values (or leave as -1 if unparseable)
        if [[ -n "$_exec_count" ]]; then _TESTER_TIMING_EXEC_COUNT="$_exec_count"; fi
        if [[ -n "$_exec_time" ]]; then _TESTER_TIMING_EXEC_APPROX_S="$_exec_time"; fi
        if [[ -n "$_files_written" ]]; then _TESTER_TIMING_FILES_WRITTEN="$_files_written"; fi
    fi
}

# _compute_tester_writing_time — Compute approximate writing time.
# Returns: writing time in seconds, or -1 if unavailable.
# Uses total tester agent duration minus reported execution time.
_compute_tester_writing_time() {
    local agent_duration="${1:-0}"
    if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -gt 0 ]] && [[ "$agent_duration" -gt 0 ]]; then
        local writing_s=$(( agent_duration - _TESTER_TIMING_EXEC_APPROX_S ))
        # Clamp to zero — agent estimates can exceed actual wall time
        [[ "$writing_s" -lt 0 ]] && writing_s=0
        echo "$writing_s"
    else
        echo "-1"
    fi
}

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
        # M47: use cached architecture content
        export ARCHITECTURE_CONTENT
        ARCHITECTURE_CONTENT=$(_get_cached_architecture_content)
        if [[ -z "$ARCHITECTURE_CONTENT" ]]; then
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

        # --- UI test guidance (Milestone 28, M58 platform adapter override) ---
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

            # If platform adapter provided tester patterns (M58), skip legacy file.
            # UI_TESTER_PATTERNS is already injected via {{UI_TESTER_PATTERNS}}
            # in tester.prompt.md — only render legacy when adapter is absent.
            if [[ -n "${UI_TESTER_PATTERNS:-}" ]]; then
                TESTER_UI_GUIDANCE=""
            else
                # Fall back to legacy monolithic file
                TESTER_UI_GUIDANCE=$(render_prompt "tester_ui_guidance" 2>/dev/null || true)
            fi
        fi

        # --- Test baseline summary for tester context (M63) -------------------
        export TEST_BASELINE_SUMMARY=""
        if [[ "${TEST_BASELINE_ENABLED:-false}" == "true" ]] \
           && declare -f has_test_baseline &>/dev/null && has_test_baseline 2>/dev/null; then
            local _bl_json
            _bl_json=$(_test_baseline_json)
            local _bl_exit _bl_failures
            _bl_exit=$(grep -oP '"exit_code"\s*:\s*\K[0-9]+' "$_bl_json" 2>/dev/null || echo "")
            _bl_failures=$(grep -oP '"failure_count"\s*:\s*\K[0-9]+' "$_bl_json" 2>/dev/null || echo "0")
            if [[ -n "$_bl_exit" ]] && [[ "$_bl_exit" -ne 0 ]]; then
                TEST_BASELINE_SUMMARY="Pre-existing test failures detected before your changes.
${_bl_failures} failure line(s) at baseline (exit code ${_bl_exit}). These are NOT caused by your work."
                log "[test-baseline] Injecting baseline summary into tester context."
            fi
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

    # --- M62: Extract tester self-reported timing --------------------------------
    _parse_tester_timing "TESTER_REPORT.md" "replace"
    if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -gt -1 ]]; then
        log "[tester-diag] Agent self-reported: ${_TESTER_TIMING_EXEC_COUNT} test executions, ~${_TESTER_TIMING_EXEC_APPROX_S}s execution time, ${_TESTER_TIMING_FILES_WRITTEN} files written"
    fi

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
                log_decision "Seeding auto-fix run" "${TEST_CMD} failures detected (depth ${_fix_depth}/${_max_depth})" "TESTER_FIX_ENABLED=true"

                # Capture test failure output from log (truncate to limit)
                local _failure_output
                _failure_output=$(grep -E '(FAIL|ERROR|error|failure|assert)' "$LOG_FILE" | tail -c "$_output_limit" || true)
                if [[ -z "$_failure_output" ]]; then
                    _failure_output=$(tail -100 "$LOG_FILE" | tail -c "$_output_limit")
                fi

                # M63: Check baseline — skip fix if all failures are pre-existing
                if [[ "${TEST_BASELINE_ENABLED:-false}" == "true" ]] \
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
            # Extracted to stages/tester_continuation.sh
            _TESTER_CONTINUED=false
            _tester_run_continuations "$resume_flag" "$_tester_stage_start"

            if [[ "$_TESTER_CONTINUED" = false ]]; then
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
            _run_and_record_test_audit
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

    # --- M62: Compute writing time for RUN_SUMMARY.json ---
    local _tester_agent_dur="${_PHASE_TIMINGS[tester_agent]:-$_tester_total_elapsed}"
    _TESTER_TIMING_WRITING_S=$(_compute_tester_writing_time "$_tester_agent_dur")
    export _TESTER_TIMING_EXEC_COUNT _TESTER_TIMING_EXEC_APPROX_S _TESTER_TIMING_FILES_WRITTEN _TESTER_TIMING_WRITING_S
}

# Source extracted TDD helper
# shellcheck source=stages/tester_tdd.sh
source "${TEKHTON_HOME}/stages/tester_tdd.sh"
