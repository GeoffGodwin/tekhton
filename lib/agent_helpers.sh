#!/usr/bin/env bash
# =============================================================================
# agent_helpers.sh — Agent run summary, output validation, and null-run helpers
#
# Sourced by agent.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller)
# Expects: log(), success(), warn(), error() from common.sh
# Expects: AGENT_ERROR_* globals from agent.sh
#
# Note: Transient retry envelope functions are in lib/agent_retry.sh
# =============================================================================
set -euo pipefail

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

# =============================================================================
# build_continuation_context — Assemble context for a turn-exhaustion continuation
#
# Reads the prior summary file and git diff stat, then builds a prompt context
# block that tells the continuation agent what was already done and what remains.
#
# Arguments:
#   $1 — stage name ("coder" or "tester")
#   $2 — attempt number (1-based)
#   $3 — max attempts
#   $4 — cumulative turns used so far (across all continuations)
#   $5 — max turns for the upcoming continuation
#
# Outputs the context string to stdout.
# =============================================================================

build_continuation_context() {
    local stage="$1"
    local attempt_num="$2"
    local max_attempts="$3"
    local cumulative_turns="$4"
    local next_turn_budget="$5"

    local summary_file=""
    local stage_label=""
    case "$stage" in
        coder)
            summary_file="${CODER_SUMMARY_FILE}"
            stage_label="Coder"
            ;;
        tester)
            summary_file="${TESTER_REPORT_FILE}"
            stage_label="Tester"
            ;;
        *)
            echo ""
            return
            ;;
    esac

    local prior_summary=""
    if [[ -f "$summary_file" ]]; then
        prior_summary=$(cat "$summary_file")
    fi

    local git_diff_stat=""
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git_diff_stat=$(git diff --stat HEAD 2>/dev/null | tail -30)
    fi

    local context=""
    context="## Continuation Context (attempt ${attempt_num}/${max_attempts})
You are continuing from a previous ${stage_label} run that hit the turn limit.
Previous attempts used ${cumulative_turns} turns total. You have ${next_turn_budget} turns.
Focus on completing the remaining items efficiently.

### Prior ${stage_label} Summary
Read the modified files to understand current state. Do NOT redo completed work.

\`\`\`
${prior_summary}
\`\`\`
"

    if [[ -n "$git_diff_stat" ]]; then
        context="${context}
### Files Modified So Far
\`\`\`
${git_diff_stat}
\`\`\`
"
    fi

    if [[ "$stage" = "coder" ]]; then
        # Detect missing or placeholder-only summary
        local _summary_state="exists"
        if [[ ! -f "$summary_file" ]]; then
            _summary_state="missing"
        elif grep -q 'fill in as you go\|update as you go' "$summary_file" 2>/dev/null; then
            _summary_state="placeholder"
        fi

        context="${context}
### Instructions"
        if [[ "$_summary_state" != "exists" ]]; then
            context="${context}
1. ${CODER_SUMMARY_FILE} is ${_summary_state} — recreate it NOW with actual content from your work so far before doing anything else
2. Read the modified files listed above to understand current state
3. Continue implementing only the REMAINING items
4. Update ${CODER_SUMMARY_FILE} with your additional progress
5. Set Status to COMPLETE when all work is done, or IN PROGRESS if more remains"
        else
            context="${context}
1. Read ${CODER_SUMMARY_FILE} first to see what was already implemented
2. Read the modified files listed above to understand current state
3. Continue implementing only the REMAINING items
4. Update ${CODER_SUMMARY_FILE} with your additional progress
5. Set Status to COMPLETE when all work is done, or IN PROGRESS if more remains"
        fi
    elif [[ "$stage" = "tester" ]]; then
        context="${context}
### Instructions
1. Read ${TESTER_REPORT_FILE} first to see which tests are already written
2. Continue writing the remaining unchecked test items
3. Update ${TESTER_REPORT_FILE} as you complete each test
4. Run the test suite to verify all tests pass"
    fi

    echo "$context"
}

# =============================================================================
# is_substantive_work — Check if agent did meaningful work worth continuing
#
# Returns 0 (true) if substantive work was detected, 1 (false) otherwise.
# Heuristic: (files_changed >= 1) AND (summary_lines >= 20 OR total_lines >= 50)
# Counts both tracked modifications AND untracked new files (via git status).
# =============================================================================

is_substantive_work() {
    local files_changed=0
    local summary_lines=0
    local diff_lines=0
    local untracked_lines=0

    # Count tracked modified files (staged + unstaged)
    local tracked_modified=0
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        tracked_modified=$(git diff --stat HEAD 2>/dev/null | grep -c '|' || echo "0")
        tracked_modified=$(echo "$tracked_modified" | tr -d '[:space:]')
    fi

    # Count untracked new files (excluding logs and session dirs)
    local untracked_count=0
    local _session_base
    _session_base=$(basename "${TEKHTON_SESSION_DIR:-__nosession__}")
    untracked_count=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -v '^\.claude/logs/' \
        | grep -v "^${_session_base}/" \
        | grep -c '' || echo "0")
    untracked_count=$(echo "$untracked_count" | tr -d '[:space:]')
    untracked_count="${untracked_count:-0}"

    files_changed=$(( tracked_modified + untracked_count ))

    if [[ "$files_changed" -lt 1 ]]; then
        return 1
    fi

    # Check summary file lines
    if [[ -f "${CODER_SUMMARY_FILE}" ]]; then
        summary_lines=$(wc -l < "${CODER_SUMMARY_FILE}" 2>/dev/null | tr -d '[:space:]')
    fi

    # Check git diff size (tracked changes)
    diff_lines=$(git diff HEAD 2>/dev/null | wc -l | tr -d '[:space:]')
    diff_lines="${diff_lines:-0}"

    # Count lines in untracked files (new code written)
    if [[ "$untracked_count" -gt 0 ]]; then
        untracked_lines=$(git ls-files --others --exclude-standard 2>/dev/null \
            | grep -v '^\.claude/logs/' \
            | grep -v "^${_session_base}/" \
            | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
        untracked_lines="${untracked_lines:-0}"
    fi

    local total_lines=$(( diff_lines + untracked_lines ))

    if [[ "$summary_lines" -ge 20 ]] || [[ "$total_lines" -ge 50 ]]; then
        return 0
    fi

    return 1
}
