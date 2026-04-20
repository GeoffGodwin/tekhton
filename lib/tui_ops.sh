#!/usr/bin/env bash
# =============================================================================
# tui_ops.sh — TUI state update operations.
#
# Sourced by lib/tui.sh — do not run directly. Provides the public update API
# called from agent.sh and other stages (tui_update_stage, tui_finish_stage,
# tui_update_agent, tui_append_event) plus run_op(), the long-running-command
# wrapper introduced in M104.
# =============================================================================
set -euo pipefail
# shellcheck source=lib/tui.sh

# Operation label for the JSON status file (empty outside a run_op call).
_TUI_OPERATION_LABEL=""

# --- Update functions --------------------------------------------------------

# tui_update_stage NUM TOTAL LABEL MODEL — set current stage.
tui_update_stage() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _TUI_CURRENT_STAGE_NUM="${1:-0}"
    _TUI_CURRENT_STAGE_TOTAL="${2:-0}"
    _TUI_CURRENT_STAGE_LABEL="${3:-}"
    _TUI_CURRENT_STAGE_MODEL="${4:-}"
    _TUI_AGENT_STATUS="running"
    _TUI_AGENT_TURNS_USED=0
    _TUI_AGENT_ELAPSED_SECS=0
    _TUI_STAGE_START_TS=$(date +%s)
    _tui_write_status
}

# tui_finish_stage LABEL MODEL TURNS TIME VERDICT — mark stage complete.
tui_finish_stage() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local label="${1:-}"
    local model="${2:-}"
    local turns="${3:-}"
    local time_str="${4:-}"
    local verdict="${5:-}"
    local entry
    entry=$(_tui_json_stage "$label" "$model" "$turns" "$time_str" "$verdict")
    _TUI_STAGES_COMPLETE+=("$entry")
    _TUI_AGENT_STATUS="idle"
    _tui_write_status
}

# tui_update_agent TURNS_USED TURNS_MAX ELAPSED_SECS — tick update from spinner.
# Safe to call at high frequency; writes atomically.
tui_update_agent() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _TUI_AGENT_TURNS_USED="${1:-0}"
    _TUI_AGENT_TURNS_MAX="${2:-0}"
    _TUI_AGENT_ELAPSED_SECS="${3:-0}"
    _TUI_AGENT_STATUS="running"
    _tui_write_status
}

# tui_append_event LEVEL MSG — append to ring buffer and flush status.
# LEVEL: info | warn | error | success
tui_append_event() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local level="${1:-info}"
    local msg="${2:-}"
    local ts
    ts=$(date +"%H:%M:%S")
    _TUI_RECENT_EVENTS+=("${ts}|${level}|${msg}")
    local max="${TUI_EVENT_LINES:-60}"
    local overflow=$(( ${#_TUI_RECENT_EVENTS[@]} - max ))
    if (( overflow > 0 )); then
        _TUI_RECENT_EVENTS=("${_TUI_RECENT_EVENTS[@]:overflow}")
    fi
    _tui_write_status
}

# --- run_op: long-running-command wrapper (M104) ------------------------------

# run_op LABEL CMD [ARGS...]
# Wraps CMD in TUI "working" state with a heartbeat subprocess so the watchdog
# never fires during long operations (test suites, build analysis, etc.).
# Falls back to transparent passthrough when TUI is not active — zero overhead
# for non-TUI users. Preserves CMD exit code.
run_op() {
    local _label="$1"; shift
    if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        "$@"
        return
    fi

    _TUI_AGENT_STATUS="working"
    _TUI_OPERATION_LABEL="$_label"
    _tui_write_status 2>/dev/null || true

    # Heartbeat subprocess: re-writes the status file every ~10s so the
    # sidecar's watchdog timer never expires during long-running commands.
    # TERM/INT trap ensures `kill` returns immediately without leaving a
    # sleeping child behind.
    (
        trap 'exit 0' TERM INT
        while true; do
            sleep 10 &
            wait $!
            _tui_write_status 2>/dev/null || true
        done
    ) &
    local _hb_pid=$!

    local _rc=0
    "$@" || _rc=$?

    kill "$_hb_pid" 2>/dev/null || true
    wait "$_hb_pid" 2>/dev/null || true

    _TUI_AGENT_STATUS="idle"
    _TUI_OPERATION_LABEL=""
    _tui_write_status 2>/dev/null || true

    return "$_rc"
}

# --- Protocol API: stage lifecycle wrappers (M106) ---------------------------

# tui_stage_begin DISPLAY_LABEL [MODEL]
# Begin a stage: ensure its pill exists in the bar, mark it running.
# DISPLAY_LABEL must come from get_stage_display_label(); callers must not
# pass raw internal stage names.
# NOTE: _TUI_STAGE_ORDER is a single-writer array (main process only). When
# parallel stages are introduced in a future milestone, this will require a
# lock or a migration to an atomic update via the JSON status file.
tui_stage_begin() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local label="${1:-}"
    local model="${2:-}"
    local _found=false
    local _s
    for _s in "${_TUI_STAGE_ORDER[@]:-}"; do
        [[ "$_s" == "$label" ]] && { _found=true; break; }
    done
    [[ "$_found" == "false" ]] && _TUI_STAGE_ORDER+=("$label")
    local _idx=0 _i
    for _i in "${!_TUI_STAGE_ORDER[@]}"; do
        [[ "${_TUI_STAGE_ORDER[$_i]}" == "$label" ]] && { _idx=$((_i + 1)); break; }
    done
    tui_update_stage "$_idx" "${#_TUI_STAGE_ORDER[@]}" "$label" "$model"
}

# tui_stage_end DISPLAY_LABEL [MODEL] [TURNS_STR] [TIME_STR] [VERDICT]
# End a stage: freeze the timer and mark it complete.
# DISPLAY_LABEL must match what was passed to tui_stage_begin.
tui_stage_end() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local label="${1:-}"
    local model="${2:-}"
    local turns="${3:-}"
    local time_str="${4:-}"
    local verdict="${5:-}"
    local _final_elapsed=0
    if [[ "${_TUI_STAGE_START_TS:-0}" -gt 0 ]]; then
        _final_elapsed=$(( $(date +%s) - _TUI_STAGE_START_TS ))
    fi
    _TUI_STAGE_START_TS=0
    _TUI_AGENT_ELAPSED_SECS="$_final_elapsed"
    tui_finish_stage "$label" "$model" "$turns" "$time_str" "$verdict"
}
