#!/usr/bin/env bash
# =============================================================================
# tui_helpers.sh — JSON builders for the TUI sidecar status file.
#
# Sourced by lib/tui.sh. Emits a JSON object matching the schema documented in
# .claude/milestones/m97-tui-mode-rich-live-display.md.
# =============================================================================

set -euo pipefail
# shellcheck source=lib/tui.sh

# _tui_escape STRING — minimal JSON string escape. Delegates to the canonical
# implementation in lib/output_format.sh (sourced via lib/common.sh ahead of
# any tui.sh usage in the live pipeline).
_tui_escape() { _out_json_escape "$@"; }

# _tui_json_stage LABEL MODEL TURNS TIME VERDICT
# Emits one JSON object describing a completed stage (no surrounding comma).
_tui_json_stage() {
    local label="${1:-}"
    local model="${2:-}"
    local turns="${3:-}"
    local time_str="${4:-}"
    local verdict="${5:-}"
    local verdict_json="null"
    if [[ -n "$verdict" ]]; then
        verdict_json="\"$(_tui_escape "$verdict")\""
    fi
    printf '{"label":"%s","model":"%s","turns":"%s","time":"%s","verdict":%s}' \
        "$(_tui_escape "$label")" \
        "$(_tui_escape "$model")" \
        "$(_tui_escape "$turns")" \
        "$(_tui_escape "$time_str")" \
        "$verdict_json"
}

# _tui_recent_events_json — emit JSON array built from _TUI_RECENT_EVENTS.
# Each entry is "ts|level|msg"; split on the first two pipe characters.
_tui_recent_events_json() {
    printf '['
    local first=1 entry ts level msg rest
    for entry in "${_TUI_RECENT_EVENTS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        ts="${entry%%|*}"
        rest="${entry#*|}"
        level="${rest%%|*}"
        msg="${rest#*|}"
        if (( first )); then
            first=0
        else
            printf ','
        fi
        printf '{"ts":"%s","level":"%s","msg":"%s"}' \
            "$(_tui_escape "$ts")" \
            "$(_tui_escape "$level")" \
            "$(_tui_escape "$msg")"
    done
    printf ']'
}

# _tui_stages_json — emit JSON array of _TUI_STAGES_COMPLETE entries.
_tui_stages_json() {
    printf '['
    local first=1 entry
    for entry in "${_TUI_STAGES_COMPLETE[@]:-}"; do
        [[ -z "$entry" ]] && continue
        if (( first )); then
            first=0
        else
            printf ','
        fi
        printf '%s' "$entry"
    done
    printf ']'
}

# _tui_stage_order_json — emit JSON string array of stage-pill entries.
# Prefers _TUI_STAGE_ORDER (set by tui_set_context); falls back to the
# space-separated _OUT_CTX[stage_order] string when the array is empty so
# callers using the Output Bus alone still get a populated stage list.
_tui_stage_order_json() {
    local -a src=()
    local s
    # Use declare -p to detect _TUI_STAGE_ORDER safely under `set -u`;
    # direct ${#_TUI_STAGE_ORDER[@]} trips unbound-variable when the array
    # was never declared (e.g. tui_helpers.sh sourced without tui.sh).
    if declare -p _TUI_STAGE_ORDER &>/dev/null; then
        for s in "${_TUI_STAGE_ORDER[@]:-}"; do
            [[ -z "$s" ]] && continue
            src+=("$s")
        done
    fi
    if [[ "${#src[@]}" -eq 0 ]] && declare -p _OUT_CTX &>/dev/null; then
        local _fallback="${_OUT_CTX[stage_order]:-}"
        if [[ -n "$_fallback" ]]; then
            # shellcheck disable=SC2206
            src=($_fallback)
        fi
    fi
    printf '['
    local first=1
    for s in "${src[@]:-}"; do
        [[ -z "$s" ]] && continue
        if (( first )); then
            first=0
        else
            printf ','
        fi
        printf '"%s"' "$(_tui_escape "$s")"
    done
    printf ']'
}

# _tui_action_items_json — emit the JSON array of action items from the
# Output Bus. M102 routes out_action_item through _OUT_CTX[action_items],
# which already holds a serialised JSON array (built by _out_append_action_item).
# An empty/unset value maps to an empty array.
_tui_action_items_json() {
    if declare -p _OUT_CTX &>/dev/null; then
        local raw="${_OUT_CTX[action_items]:-}"
        if [[ -n "$raw" ]]; then
            printf '%s' "$raw"
            return 0
        fi
    fi
    printf '[]'
}

# _tui_json_build_status ELAPSED_SECS — emit full status JSON to stdout.
# Reads state from _TUI_* globals set by lib/tui.sh.
_tui_json_build_status() {
    local elapsed="${1:-0}"
    local run_id="${_CURRENT_RUN_ID:-${TIMESTAMP:-unknown}}"
    local milestone="${_CURRENT_MILESTONE:-}"
    local milestone_title="${MILESTONE_TITLE:-}"
    local task="${TASK:-}"
    # M99: Output Bus owns the attempt counter. Fall back to "1" if the bus
    # hasn't been initialised yet (standalone TUI tests source this file
    # without common.sh/output.sh). M103: max_attempts follows the same path
    # for symmetry, with MAX_PIPELINE_ATTEMPTS as the ultimate fallback so
    # production (which seeds both) behaves identically to pre-M103.
    local attempt="1"
    local max_attempts="${MAX_PIPELINE_ATTEMPTS:-1}"
    if declare -p _OUT_CTX &>/dev/null; then
        attempt="${_OUT_CTX[attempt]:-1}"
        max_attempts="${_OUT_CTX[max_attempts]:-${max_attempts}}"
    fi
    local stage_label="${_TUI_CURRENT_STAGE_LABEL:-}"
    local stage_num="${_TUI_CURRENT_STAGE_NUM:-0}"
    local stage_total="${_TUI_CURRENT_STAGE_TOTAL:-0}"
    local stage_model="${_TUI_CURRENT_STAGE_MODEL:-}"
    local turns_used="${_TUI_AGENT_TURNS_USED:-0}"
    local turns_max="${_TUI_AGENT_TURNS_MAX:-0}"
    local agent_elapsed="${_TUI_AGENT_ELAPSED_SECS:-0}"
    local stage_start_ts="${_TUI_STAGE_START_TS:-0}"
    local agent_status="${_TUI_AGENT_STATUS:-idle}"
    local op_label="${_TUI_OPERATION_LABEL:-}"
    local complete="${_TUI_COMPLETE:-false}"
    local verdict_json="null"
    if [[ -n "${_TUI_VERDICT:-}" ]]; then
        verdict_json="\"$(_tui_escape "$_TUI_VERDICT")\""
    fi
    local run_mode="${_TUI_RUN_MODE:-task}"
    local cli_flags="${_TUI_CLI_FLAGS:-}"

    local last_event=""
    local n="${#_TUI_RECENT_EVENTS[@]}"
    if (( n > 0 )); then
        local raw="${_TUI_RECENT_EVENTS[$((n-1))]}"
        last_event="${raw#*|}"
        last_event="${last_event#*|}"
    fi

    printf '{'
    printf '"version":1,'
    printf '"run_id":"%s",' "$(_tui_escape "$run_id")"
    printf '"milestone":"%s",' "$(_tui_escape "$milestone")"
    printf '"milestone_title":"%s",' "$(_tui_escape "$milestone_title")"
    printf '"task":"%s",' "$(_tui_escape "$task")"
    printf '"attempt":%s,' "$attempt"
    printf '"max_attempts":%s,' "$max_attempts"
    printf '"stage_num":%s,' "$stage_num"
    printf '"stage_total":%s,' "$stage_total"
    printf '"stage_label":"%s",' "$(_tui_escape "$stage_label")"
    printf '"agent_turns_used":%s,' "$turns_used"
    printf '"agent_turns_max":%s,' "$turns_max"
    printf '"agent_elapsed_secs":%s,' "$agent_elapsed"
    printf '"stage_start_ts":%s,' "$stage_start_ts"
    printf '"agent_model":"%s",' "$(_tui_escape "$stage_model")"
    printf '"pipeline_elapsed_secs":%s,' "$elapsed"
    printf '"stages_complete":%s,' "$(_tui_stages_json)"
    printf '"current_agent_status":"%s",' "$(_tui_escape "$agent_status")"
    printf '"current_operation":"%s",' "$(_tui_escape "$op_label")"
    printf '"run_mode":"%s",' "$(_tui_escape "$run_mode")"
    printf '"cli_flags":"%s",' "$(_tui_escape "$cli_flags")"
    printf '"stage_order":%s,' "$(_tui_stage_order_json)"
    printf '"last_event":"%s",' "$(_tui_escape "$last_event")"
    printf '"recent_events":%s,' "$(_tui_recent_events_json)"
    printf '"action_items":%s,' "$(_tui_action_items_json)"
    printf '"verdict":%s,' "$verdict_json"
    printf '"complete":%s' "$complete"
    printf '}'
}
