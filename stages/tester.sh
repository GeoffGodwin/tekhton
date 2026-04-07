#!/usr/bin/env bash
# =============================================================================
# stages/tester.sh — Stage 3: Tester (write tests + verify)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, START_AT, etc.)
# =============================================================================

set -euo pipefail

# Source extracted tester timing globals and parsing (M62 → M65 SIM-1)
# shellcheck source=stages/tester_timing.sh
source "${TEKHTON_HOME}/stages/tester_timing.sh"

# Source extracted post-tester validation and routing
# shellcheck source=stages/tester_validation.sh
source "${TEKHTON_HOME}/stages/tester_validation.sh"

# Source extracted TDD helper
# shellcheck source=stages/tester_tdd.sh
source "${TEKHTON_HOME}/stages/tester_tdd.sh"

# Source extracted turn-exhaustion continuation loop
# shellcheck source=stages/tester_continuation.sh
source "${TEKHTON_HOME}/stages/tester_continuation.sh"

# Source extracted inline tester fix (M64)
# shellcheck source=stages/tester_fix.sh
source "${TEKHTON_HOME}/stages/tester_fix.sh"

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
        if [[ "${TEST_BASELINE_ENABLED:-true}" == "true" ]] \
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

    # --- Post-tester validation (extracted to tester_validation.sh) -----------
    _validate_tester_output "$resume_flag" "$_tester_stage_start"

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

