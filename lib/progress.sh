#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# progress.sh — Progress transparency: status lines + decision logging (M50)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn() from common.sh
# Expects: _METRICS_FILE, _ensure_metrics_file from metrics.sh (optional)
# Expects: _STAGE_DURATION associative array from tekhton.sh
#
# Provides:
#   progress_status      — print status line before agent invocation
#   progress_outcome     — print outcome line after agent invocation
#   log_decision         — log a routing decision with reason
#   _estimate_stage_time — estimate stage duration from metrics history
#   _format_elapsed      — format seconds as Xm Ys
#   _get_decision_log    — return accumulated decision log entries
#   _get_timing_breakdown — return per-stage timing as JSON
# =============================================================================

# --- Decision log accumulator -------------------------------------------------
# Stores decisions as newline-separated entries: "DECISION|REASON|CONFIG_KEY"
_DECISION_LOG=""

# log_decision DECISION REASON [CONFIG_KEY]
# Logs a routing decision with its reason and the config key that triggered it.
# Also prints to stderr via log() for real-time visibility.
log_decision() {
    local decision="$1"
    local reason="$2"
    local config_key="${3:-}"

    log "${decision} — ${reason}${config_key:+ (${config_key})}"

    # Accumulate for RUN_SUMMARY.json
    local entry
    entry="${decision}|${reason}|${config_key}"
    if [[ -z "$_DECISION_LOG" ]]; then
        _DECISION_LOG="$entry"
    else
        _DECISION_LOG="${_DECISION_LOG}
${entry}"
    fi
}

# _get_decision_log
# Returns the accumulated decision log as a JSON array of objects.
_get_decision_log() {
    if [[ -z "$_DECISION_LOG" ]]; then
        echo "[]"
        return
    fi

    local json="["
    local first=true
    while IFS='|' read -r decision reason config_key; do
        [[ -z "$decision" ]] && continue
        # Escape for JSON
        decision=$(printf '%s' "$decision" | sed 's/\\/\\\\/g; s/"/\\"/g')
        reason=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
        config_key=$(printf '%s' "$config_key" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [[ "$first" = true ]]; then
            first=false
        else
            json="${json},"
        fi
        json="${json}{\"decision\":\"${decision}\",\"reason\":\"${reason}\",\"config_key\":\"${config_key}\"}"
    done <<< "$_DECISION_LOG"
    json="${json}]"
    echo "$json"
}

# --- Timing estimation -------------------------------------------------------

# _estimate_stage_time STAGE_NAME
# Estimates duration for a stage based on metrics history (metrics.jsonl).
# Returns estimated seconds on stdout, or empty string if no history.
_estimate_stage_time() {
    local stage="$1"
    local metrics_file="${_METRICS_FILE:-}"

    # Try to locate metrics file if not set
    if [[ -z "$metrics_file" ]]; then
        local log_dir="${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}"
        metrics_file="${log_dir}/metrics.jsonl"
    fi

    [[ -f "$metrics_file" ]] || return 0

    # Extract recent stage durations (last 10 runs) using grep+awk
    # metrics.jsonl has "stages" field with per-stage data
    local durations
    durations=$(tail -20 "$metrics_file" 2>/dev/null \
        | grep -o "\"${stage}\":{[^}]*}" 2>/dev/null \
        | grep -o '"duration_s":[0-9]*' 2>/dev/null \
        | grep -o '[0-9]*$' 2>/dev/null \
        | tail -5 || true)

    [[ -z "$durations" ]] && return 0

    # Compute average
    local sum=0 count=0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        sum=$(( sum + d ))
        count=$(( count + 1 ))
    done <<< "$durations"

    if [[ "$count" -gt 0 ]]; then
        echo $(( sum / count ))
    fi
}

# _format_elapsed SECONDS
# Formats seconds as human-readable "Xm Ys" or "Ys" for short durations.
_format_elapsed() {
    local secs="${1:-0}"
    if [[ "$secs" -ge 60 ]]; then
        echo "$(( secs / 60 ))m $(( secs % 60 ))s"
    else
        echo "${secs}s"
    fi
}

# _format_estimate SECONDS
# Formats an estimate as a range (±30%) or "no estimate" if empty.
_format_estimate() {
    local est="${1:-}"
    if [[ -z "$est" ]] || [[ "$est" -eq 0 ]]; then
        echo "no estimate"
        return
    fi
    local low=$(( est * 7 / 10 ))
    local high=$(( est * 13 / 10 ))
    echo "estimated $(_format_elapsed "$low")-$(_format_elapsed "$high") based on history"
}

# --- Status lines -------------------------------------------------------------

# progress_status STAGE_POS STAGE_COUNT STAGE_NAME [EXTRA_INFO]
# Prints a human-readable status line before an agent invocation.
# Output goes to stderr via log() — never to stdout (agent FIFO).
progress_status() {
    local pos="$1"
    local count="$2"
    local name="$3"
    local extra="${4:-}"

    local est_secs
    est_secs=$(_estimate_stage_time "$name" 2>/dev/null || true)
    local est_str
    est_str=$(_format_estimate "${est_secs:-}")

    local line="Stage ${pos}/${count}: ${name}"
    [[ -n "$extra" ]] && line="${line} (${extra})"
    line="${line} — ${est_str}"

    log "$line"
}

# _format_estimate_compact SECONDS
# Compact estimate suitable for inline header use: "(est. 2m)" or "" when none.
_format_estimate_compact() {
    local est="${1:-}"
    if [[ -z "$est" ]] || [[ "$est" -eq 0 ]]; then
        printf ''
        return
    fi
    if [[ "$est" -ge 60 ]]; then
        printf '(est. %dm)' "$(( est / 60 ))"
    else
        printf '(est. %ds)' "$est"
    fi
}

# stage_header STAGE_POS STAGE_COUNT STAGE_NAME [SUFFIX]
# Renders the stage banner with the estimate folded into the header line.
# Replaces the prior pattern of `progress_status … ; header "Stage N/M — name"`.
# SUFFIX (e.g. "(skipped)") is appended after the stage name.
stage_header() {
    local pos="$1"
    local count="$2"
    local name="$3"
    local suffix="${4:-}"

    local title="Stage ${pos} / ${count} — ${name}"
    [[ -n "$suffix" ]] && title="${title} ${suffix}"

    local est_secs
    est_secs=$(_estimate_stage_time "$name" 2>/dev/null || true)
    local est_str
    est_str=$(_format_estimate_compact "${est_secs:-}")
    [[ -n "$est_str" ]] && title="${title}                ${est_str}"

    header "$title"
}

# progress_outcome STAGE_NAME RESULT ELAPSED_SECS [NEXT_ACTION]
# Prints a human-readable outcome line after an agent completes.
progress_outcome() {
    local name="$1"
    local result="$2"
    local elapsed="$3"
    local next="${4:-}"

    local elapsed_str
    elapsed_str=$(_format_elapsed "$elapsed")

    local line="${name}: ${result} — ${elapsed_str}"
    [[ -n "$next" ]] && line="${line} — ${next}"

    log "$line"
}

# --- Timing breakdown for RUN_SUMMARY.json ------------------------------------

# _get_timing_breakdown
# Returns per-stage timing as a JSON object from _STAGE_DURATION array.
_get_timing_breakdown() {
    # Guard: _STAGE_DURATION may not exist in all contexts
    if ! declare -p _STAGE_DURATION &>/dev/null; then
        echo "{}"
        return
    fi

    local json="{"
    local first=true
    local total=0
    local _stg
    for _stg in "${!_STAGE_DURATION[@]}"; do
        local dur="${_STAGE_DURATION[$_stg]:-0}"
        [[ "$dur" -eq 0 ]] && continue
        total=$(( total + dur ))
        if [[ "$first" = true ]]; then
            first=false
        else
            json="${json},"
        fi
        # Safe: _stg keys come exclusively from _STAGE_DURATION, set only by pipeline constants ("coder", "reviewer", "tester"), never from user input
        json="${json}\"${_stg}\":${dur}"
    done
    if [[ "$first" = true ]]; then
        echo "{}"
        return
    fi
    json="${json},\"total\":${total}}"
    echo "$json"
}
