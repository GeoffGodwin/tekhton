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
# M110: embeds the lifecycle id recorded in _TUI_CURRENT_LIFECYCLE_ID at
# time-of-call so timings rows key off lifecycle id, not label, and repeated
# cycles of the same label (e.g. rework#1 vs rework#2) remain distinguishable.
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
    local lifecycle_id="${_TUI_CURRENT_LIFECYCLE_ID:-}"
    printf '{"label":"%s","lifecycle_id":"%s","model":"%s","turns":"%s","time":"%s","verdict":%s}' \
        "$(_tui_escape "$label")" \
        "$(_tui_escape "$lifecycle_id")" \
        "$(_tui_escape "$model")" \
        "$(_tui_escape "$turns")" \
        "$(_tui_escape "$time_str")" \
        "$verdict_json"
}

# _tui_recent_events_json — emit JSON array built from _TUI_RECENT_EVENTS.
# Each entry is "ts|level|type|source|msg" (M117 5-field shape). Backward
# compatible with earlier shapes:
#   - M110 4-field "ts|level|type|msg" — source defaults to empty
#   - Pre-M110 3-field "ts|level|msg" — type defaults to "runtime"
# M110: type ∈ runtime | summary. Summary entries carry run-epilogue metadata
# (task, started, verdict, log, version, timing breakdown) and must be
# rendered in a dedicated block by the hold view — never interleaved with
# runtime chronology.
# M117: source is a TUI-only attribution breadcrumb ("stage » substage" or
# "stage") produced by _tui_compute_source(); empty string means no
# attribution. Serialised as the "source" JSON field; absent in JSON when empty.
_tui_recent_events_json() {
    printf '['
    local first=1 entry ts level type source msg rest rest2 after_type
    for entry in "${_TUI_RECENT_EVENTS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        ts="${entry%%|*}"
        rest="${entry#*|}"
        level="${rest%%|*}"
        rest2="${rest#*|}"
        source=""
        if [[ "$rest2" == *"|"* ]]; then
            type="${rest2%%|*}"
            after_type="${rest2#*|}"
            case "$type" in
                runtime|summary)
                    # Modern 5-field has "source|msg" in after_type. Detect
                    # 4-field legacy by absence of an additional pipe.
                    if [[ "$after_type" == *"|"* ]]; then
                        source="${after_type%%|*}"
                        msg="${after_type#*|}"
                    else
                        msg="$after_type"
                    fi
                    ;;
                *)
                    msg="$rest2"
                    type="runtime"
                    ;;
            esac
        else
            type="runtime"
            msg="$rest2"
        fi
        if (( first )); then
            first=0
        else
            printf ','
        fi
        if [[ -n "$source" ]]; then
            printf '{"ts":"%s","level":"%s","type":"%s","source":"%s","msg":"%s"}' \
                "$(_tui_escape "$ts")" \
                "$(_tui_escape "$level")" \
                "$(_tui_escape "$type")" \
                "$(_tui_escape "$source")" \
                "$(_tui_escape "$msg")"
        else
            printf '{"ts":"%s","level":"%s","type":"%s","msg":"%s"}' \
                "$(_tui_escape "$ts")" \
                "$(_tui_escape "$level")" \
                "$(_tui_escape "$type")" \
                "$(_tui_escape "$msg")"
        fi
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
    printf '"current_lifecycle_id":"%s",' "$(_tui_escape "${_TUI_CURRENT_LIFECYCLE_ID:-}")"
    printf '"current_substage_label":"%s",' "$(_tui_escape "${_TUI_CURRENT_SUBSTAGE_LABEL:-}")"
    printf '"current_substage_start_ts":%s,' "${_TUI_CURRENT_SUBSTAGE_START_TS:-0}"
    printf '"agent_turns_used":%s,' "$turns_used"
    printf '"agent_turns_max":%s,' "$turns_max"
    printf '"agent_elapsed_secs":%s,' "$agent_elapsed"
    printf '"stage_start_ts":%s,' "$stage_start_ts"
    printf '"agent_model":"%s",' "$(_tui_escape "$stage_model")"
    printf '"pipeline_elapsed_secs":%s,' "$elapsed"
    printf '"stages_complete":%s,' "$(_tui_stages_json)"
    printf '"current_agent_status":"%s",' "$(_tui_escape "$agent_status")"
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
