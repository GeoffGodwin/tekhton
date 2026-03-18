#!/usr/bin/env bash
# =============================================================================
# agent_helpers.sh — Agent run summary, output validation, and null-run helpers
#
# Sourced by agent.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller)
# Expects: log(), success(), warn(), error() from common.sh
# Expects: AGENT_ERROR_* globals from agent.sh
# =============================================================================

# --- Run summary -------------------------------------------------------------

print_run_summary() {
    local total_mins=$(( TOTAL_TIME / 60 ))
    local total_secs=$(( TOTAL_TIME % 60 ))
    echo
    echo "══════════════════════════════════════"
    echo "  Run Summary"
    echo "══════════════════════════════════════"
    echo -e "$STAGE_SUMMARY"
    echo "  ──────────────────────────────────"
    echo "  Total turns: ${TOTAL_TURNS}"
    echo "  Total time:  ${total_mins}m${total_secs}s"
    # LAST_CONTEXT_TOKENS reflects the most recently completed stage only (by design).
    # Each stage calls log_context_report() which resets and re-exports LAST_CONTEXT_TOKENS.
    # The final summary therefore shows the tester's context, not the coder's (typically
    # largest). Per-stage context breakdowns are logged individually during each stage.
    # This is intentional: the run summary is a snapshot, not an aggregate. Detailed
    # per-stage context data is available in the run log output.
    if [[ -n "${LAST_CONTEXT_TOKENS:-}" ]] && [[ "${LAST_CONTEXT_TOKENS:-0}" -gt 0 ]]; then
        local ctx_k=$(( LAST_CONTEXT_TOKENS / 1000 ))
        echo "  Context:     ~${ctx_k}k tokens (${LAST_CONTEXT_PCT:-0}% of window)"
    fi
    echo "══════════════════════════════════════"
    echo
}

# --- Structured agent run summary (12.3) — appended to log file end ----------
_append_agent_summary() {
    local label="$1" model="$2" turns_used="$3" max_turns="$4"
    local mins="$5" secs="$6" exit_code="$7" files_changed="$8"
    local log_file="$9"

    # Detect Unicode for consistent rendering with report_error
    local _sep="═══"
    if ! _is_utf8_terminal; then
        _sep="==="
    fi

    local _class="SUCCESS"
    if [[ "$exit_code" -ne 0 ]]; then
        if [[ -n "$AGENT_ERROR_CATEGORY" ]]; then
            _class="${AGENT_ERROR_CATEGORY}/${AGENT_ERROR_SUBCATEGORY}"
        elif [[ "$LAST_AGENT_NULL_RUN" = true ]]; then
            _class="NULL_RUN"
        else
            _class="FAILED (exit ${exit_code})"
        fi
    fi

    # Count created files (heuristic: new untracked files since prerun marker)
    local _created=0
    local _modified="${files_changed}"
    if command -v git &>/dev/null; then
        _created=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d '[:space:]')
        _created="${_created:-0}"
    fi

    local _summary_block
    _summary_block=$(cat <<AGENTSUMMARY

${_sep} Agent Run Summary ${_sep}
Agent:     ${label} (${model})
Turns:     ${turns_used} / ${max_turns}
Duration:  ${mins}m ${secs}s
Exit Code: ${exit_code}
Class:     ${_class}
Files:     ${_modified} modified, ${_created} created
AGENTSUMMARY
)

    # Add error details on failure
    if [[ "$_class" != "SUCCESS" ]] && [[ -n "$AGENT_ERROR_CATEGORY" ]]; then
        local _recovery=""
        if command -v suggest_recovery &>/dev/null; then
            _recovery=$(suggest_recovery "$AGENT_ERROR_CATEGORY" "$AGENT_ERROR_SUBCATEGORY")
        fi
        _summary_block="${_summary_block}
Error:     ${AGENT_ERROR_MESSAGE}
Recovery:  ${_recovery}"
    fi

    _summary_block="${_summary_block}
${_sep}${_sep}${_sep}${_sep}${_sep}${_sep}"

    # Redact sensitive data before writing to log
    if command -v redact_sensitive &>/dev/null; then
        _summary_block=$(redact_sensitive "$_summary_block")
    fi

    echo "$_summary_block" >> "$log_file"
}

# --- Null run detection helpers (call after run_agent()) --------------------

# was_null_run — true if last agent died before accomplishing meaningful work.
was_null_run() {
    [ "$LAST_AGENT_NULL_RUN" = true ]
}

# check_agent_output FILE LABEL — returns 0 if agent produced meaningful work.
check_agent_output() {
    local expected_file="$1"
    local label="$2"

    if was_null_run; then
        warn "[$label] Agent was a null run — no output expected."
        return 1
    fi

    if [ ! -f "$expected_file" ]; then
        warn "[$label] Expected output file '${expected_file}' not found."
        return 1
    fi

    local line_count
    line_count=$(count_lines < "$expected_file")
    if [ "$line_count" -lt 3 ]; then
        warn "[$label] Output file '${expected_file}' has only ${line_count} line(s) — likely a stub."
        return 1
    fi

    local has_changes=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi

    if [ "$has_changes" = false ] && [ "$line_count" -lt 5 ]; then
        warn "[$label] No git changes and minimal output — agent may not have accomplished anything."
        return 1
    fi

    return 0
}
