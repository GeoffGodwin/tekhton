#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_helpers.sh — Internal helper functions for the diagnostic engine
#
# Sourced by lib/diagnose.sh — do not run directly.
# Expects: _DIAG_* module state variables declared in diagnose.sh
# Expects: DIAG_CLASSIFICATION set by classify_failure_diag (for
#          _detect_recurring_failures)
# Expects: PROJECT_DIR (set by caller)
#
# Provides:
#   _collapse_cause_chain      — collapse _DIAG_CAUSE_CHAIN to max 5 links
#   _detect_recurring_failures — detect and annotate recurring failure patterns
#   _collect_agent_log_tails   — gather last 20 lines of each stage agent log
# =============================================================================

# _collapse_cause_chain
# Collapses the cause chain to max 5 links for terminal summary.
# Groups consecutive events of the same type.
_collapse_cause_chain() {
    [[ -n "$_DIAG_CAUSE_CHAIN" ]] || return 0

    # Parse chain: "id1 <- id2.type <- id3.type ..."
    local links=()
    local IFS=' '
    read -ra parts <<< "$_DIAG_CAUSE_CHAIN"

    local prev_type=""
    local type_count=0
    for part in "${parts[@]}"; do
        [[ "$part" = "<-" ]] && continue
        # Extract type from id.type format
        local etype="${part##*.}"
        if [[ "$etype" = "$part" ]]; then
            etype="event"
        fi

        if [[ "$etype" = "$prev_type" ]]; then
            type_count=$(( type_count + 1 ))
        else
            if [[ -n "$prev_type" ]] && [[ "$type_count" -gt 1 ]]; then
                links[-1]="${type_count}x ${prev_type}"
            fi
            links+=("$etype")
            prev_type="$etype"
            type_count=1
        fi
    done
    # Final group
    if [[ "$type_count" -gt 1 ]] && [[ ${#links[@]} -gt 0 ]]; then
        links[-1]="${type_count}x ${prev_type}"
    fi

    # Take max 5 links
    local max=5
    local result=""
    local count=0
    for link in "${links[@]}"; do
        [[ "$count" -ge "$max" ]] && break
        if [[ -n "$result" ]]; then
            result="${result} -> ${link}"
        else
            result="$link"
        fi
        count=$(( count + 1 ))
    done

    if [[ ${#links[@]} -gt "$max" ]]; then
        result="${result} -> ... (${#links[@]} total)"
    fi

    _DIAG_CAUSE_CHAIN_SHORT="$result"
}

# _detect_recurring_failures
# Uses recurring_pattern() from causality.sh when available.
# Falls back to LAST_FAILURE_CONTEXT.json files.
_detect_recurring_failures() {
    _DIAG_RECURRING_COUNT=0
    _DIAG_RECURRING_NOTE=""

    # Primary: causal log recurring_pattern()
    if command -v recurring_pattern &>/dev/null && [[ -n "$DIAG_CLASSIFICATION" ]]; then
        local pattern_type=""
        case "$DIAG_CLASSIFICATION" in
            BUILD_FAILURE)      pattern_type="build_gate" ;;
            REVIEW_REJECTION_LOOP) pattern_type="verdict" ;;
            TRANSIENT_ERROR)    pattern_type="error" ;;
            TURN_EXHAUSTION)    pattern_type="stage_end" ;;
            *)                  pattern_type="" ;;
        esac

        if [[ -n "$pattern_type" ]]; then
            local result
            result=$(recurring_pattern "$pattern_type" 5 2>/dev/null || echo "0")
            local count="${result%% *}"
            count="${count//[!0-9]/}"
            : "${count:=0}"
            _DIAG_RECURRING_COUNT="$count"
        fi
    fi

    # Fallback: count LAST_FAILURE_CONTEXT.json with matching classification
    if [[ "$_DIAG_RECURRING_COUNT" -eq 0 ]]; then
        local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
        if [[ -f "$failure_ctx" ]] && [[ -n "$DIAG_CLASSIFICATION" ]]; then
            local prev_class
            prev_class=$(grep -oP '"classification"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
            if [[ "$prev_class" = "$DIAG_CLASSIFICATION" ]]; then
                local prev_count
                prev_count=$(grep -oP '"consecutive_count"\s*:\s*\K[0-9]+' "$failure_ctx" 2>/dev/null || true)
                prev_count="${prev_count//[!0-9]/}"
                : "${prev_count:=0}"
                _DIAG_RECURRING_COUNT=$(( prev_count + 1 ))
            fi
        fi
    fi

    if [[ "$_DIAG_RECURRING_COUNT" -ge 3 ]]; then
        _DIAG_RECURRING_NOTE="This is the ${_DIAG_RECURRING_COUNT}th consecutive ${DIAG_CLASSIFICATION} — consider manual intervention."
    fi
}

# _collect_agent_log_tails
# Reads last 20 lines of each stage's agent log.
_collect_agent_log_tails() {
    _DIAG_AGENT_LOG_TAILS=""
    local log_dir="${PROJECT_DIR:-.}/.claude/logs"
    [[ -d "$log_dir" ]] || return 0

    local latest_logs
    latest_logs=$(find "$log_dir" -maxdepth 1 -name '*.log' -type f 2>/dev/null | head -5 || true)
    [[ -n "$latest_logs" ]] || return 0

    while IFS= read -r logfile; do
        [[ -z "$logfile" ]] && continue
        local basename
        basename=$(basename "$logfile")
        _DIAG_AGENT_LOG_TAILS="${_DIAG_AGENT_LOG_TAILS}--- ${basename} (last 20 lines) ---"$'\n'
        _DIAG_AGENT_LOG_TAILS="${_DIAG_AGENT_LOG_TAILS}$(tail -20 "$logfile" 2>/dev/null || true)"$'\n'
    done <<< "$latest_logs"
}
