#!/usr/bin/env bash
# =============================================================================
# stages/tester_tdd.sh — TDD write-failing tester sub-stage
#
# Sourced by tekhton.sh after tester.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, etc.)
# Provides: _run_tester_write_failing()
# =============================================================================

set -euo pipefail

# _run_tester_write_failing — TDD pre-flight: write tests that should fail.
# Uses tester_write_failing.prompt.md. Outputs ${TDD_PREFLIGHT_FILE}.
# Does NOT enforce test pass gate — tests are expected to fail.
_run_tester_write_failing() {
    local _preflight_file="${TDD_PREFLIGHT_FILE:-}"
    local _max_turns="${TESTER_WRITE_FAILING_MAX_TURNS:-10}"

    # Architecture content for the prompt (M47: use cache)
    export ARCHITECTURE_CONTENT
    ARCHITECTURE_CONTENT=$(_get_cached_architecture_content)
    if [[ -z "$ARCHITECTURE_CONTENT" ]]; then
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
        cp "$_preflight_file" "${LOG_DIR}/${TIMESTAMP}_$(basename "${TDD_PREFLIGHT_FILE}")"
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
