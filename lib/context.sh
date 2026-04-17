#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# context.sh — Token accounting and context budget measurement
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn() from common.sh
# Provides: measure_context_size(), log_context_report(), check_context_budget()
#
# Context compiler functions (extract_relevant_sections, build_context_packet,
# compress_context) live in lib/context_compiler.sh.
# =============================================================================

# --- Context budget globals --------------------------------------------------

# Accumulated context size (characters) for the current agent invocation.
# Reset by log_context_report() after each report.
_CONTEXT_TOTAL_CHARS=0
_CONTEXT_TOTAL_TOKENS=0
_CONTEXT_REPORT=""

# --- Model context window lookup table ---------------------------------------
# Maps model family prefixes to maximum context window sizes (in tokens).
# These are input token limits — the prompt + context must fit within this.
# Update this table when Anthropic releases new models or changes limits.

_get_model_window() {
    local model="$1"
    case "$model" in
        *opus*)   echo 200000 ;;
        *sonnet*) echo 200000 ;;
        *haiku*)  echo 200000 ;;
        *)        echo 200000 ;;  # Conservative default
    esac
}

# =============================================================================
# measure_context_size — Returns character count and estimated token count
#
# Usage: measure_context_size "some text content"
# Output: two lines — "chars: N" and "tokens: N"
#
# Token estimation uses CHARS_PER_TOKEN (default: 4). This is deliberately
# conservative — real tokenizers produce fewer tokens per character, so our
# estimates will slightly overcount. Good enough for budget checks.
# =============================================================================

measure_context_size() {
    local content="$1"
    local chars=${#content}
    local cpt="${CHARS_PER_TOKEN:-4}"
    local tokens=$(( (chars + cpt - 1) / cpt ))  # Round up
    echo "chars: ${chars}"
    echo "tokens: ${tokens}"
}

# =============================================================================
# log_context_report — Logs a structured breakdown of context components
#
# Called by each stage after assembling context blocks but before render_prompt.
# Each call to _add_context_component accumulates into the report. Then
# log_context_report finalizes and writes the summary.
#
# Usage:
#   _add_context_component "Architecture" "$ARCHITECTURE_BLOCK"
#   _add_context_component "Human Notes" "$HUMAN_NOTES_BLOCK"
#   log_context_report "coder" "$model"
# =============================================================================

_add_context_component() {
    local name="$1"
    local content="$2"

    local chars=${#content}
    if [[ "$chars" -eq 0 ]]; then
        return
    fi

    local cpt="${CHARS_PER_TOKEN:-4}"
    local tokens=$(( (chars + cpt - 1) / cpt ))

    _CONTEXT_TOTAL_CHARS=$(( _CONTEXT_TOTAL_CHARS + chars ))
    _CONTEXT_TOTAL_TOKENS=$(( _CONTEXT_TOTAL_TOKENS + tokens ))
    _CONTEXT_REPORT="${_CONTEXT_REPORT}    ${name}: ${chars} chars (~${tokens} tokens)"$'\n'
}

log_context_report() {
    local stage="$1"
    local model="$2"

    if [[ "${CONTEXT_BUDGET_ENABLED:-true}" != "true" ]]; then
        _CONTEXT_TOTAL_CHARS=0
        _CONTEXT_TOTAL_TOKENS=0
        _CONTEXT_REPORT=""
        return
    fi

    local window
    window=$(_get_model_window "$model")
    local budget_pct="${CONTEXT_BUDGET_PCT:-50}"
    local budget_tokens=$(( window * budget_pct / 100 ))

    local pct_used=0
    if [[ "$window" -gt 0 ]]; then
        pct_used=$(( _CONTEXT_TOTAL_TOKENS * 100 / window ))
    fi

    # M96 (NR3): per-row context breakdown suppressed from stdout. The total
    # tokens/pct are stored on LAST_CONTEXT_TOKENS / LAST_CONTEXT_PCT and
    # folded into the agent completion line by agent.sh. The full breakdown
    # still lands in the log file for post-mortem inspection.
    log_verbose "[context] ${stage} context breakdown:"
    if [[ -n "${_CONTEXT_REPORT}" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && log_verbose "$line"
        done <<< "${_CONTEXT_REPORT}"
    fi
    log_verbose "  Total: ${_CONTEXT_TOTAL_CHARS} chars (~${_CONTEXT_TOTAL_TOKENS} tokens, ${pct_used}% of ${window} window)"

    if [[ "$_CONTEXT_TOTAL_TOKENS" -gt "$budget_tokens" ]]; then
        warn "[context] Over budget: ${_CONTEXT_TOTAL_TOKENS} tokens > ${budget_tokens} budget (${budget_pct}% of ${window})"
    fi

    # Store for print_run_summary
    export LAST_CONTEXT_TOKENS="$_CONTEXT_TOTAL_TOKENS"
    export LAST_CONTEXT_PCT="$pct_used"

    # Reset for next stage
    _CONTEXT_TOTAL_CHARS=0
    _CONTEXT_TOTAL_TOKENS=0
    _CONTEXT_REPORT=""
}

# =============================================================================
# check_context_budget — Returns 0 if under budget, 1 if over budget
#
# Usage: check_context_budget "$total_tokens" "$model"
# =============================================================================

check_context_budget() {
    local total_tokens="$1"
    local model="$2"

    if [[ "${CONTEXT_BUDGET_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    local window
    window=$(_get_model_window "$model")
    local budget_pct="${CONTEXT_BUDGET_PCT:-50}"
    local budget_tokens=$(( window * budget_pct / 100 ))

    if [[ "$total_tokens" -gt "$budget_tokens" ]]; then
        return 1
    fi
    return 0
}
