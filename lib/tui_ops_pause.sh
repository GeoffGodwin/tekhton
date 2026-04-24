#!/usr/bin/env bash
# =============================================================================
# tui_ops_pause.sh — TUI quota-pause state operations (M124)
#
# Sourced by lib/tui_ops.sh — do not run directly. Provides the pause API
# called from lib/quota.sh's enter_quota_pause loop:
#
#   tui_enter_pause REASON [RETRY_INTERVAL] [MAX_DURATION]
#       Sets _TUI_AGENT_STATUS="paused", populates pause-state globals,
#       appends a single warn-level event, flushes the status file.
#
#   tui_update_pause NEXT_PROBE_IN_SECS [ELAPSED_SECS]
#       Refresh the next-probe timestamp without appending events. Called
#       once per chunked sleep tick by quota.sh so the sidecar can render
#       a live countdown. Rate-limited: writes status only.
#
#   tui_exit_pause [RESULT=refreshed|timeout|cancelled]
#       Clears the pause-state globals, appends one summary event, sets
#       agent status back to "idle" so the spinner restart can re-set
#       "running" without conflict.
#
# Lifecycle: pause is a *lateral* transition — it never enters
# _TUI_STAGES_COMPLETE and does not allocate a lifecycle id. The parent
# stage stays "open" (lifecycle id, start ts, label all preserved); only
# the agent-status field swings paused → idle → running.
# =============================================================================
set -euo pipefail
# shellcheck source=lib/tui.sh

# tui_enter_pause REASON [RETRY_INTERVAL_SECS] [MAX_DURATION_SECS] [FIRST_PROBE_DELAY_SECS]
# M125: FIRST_PROBE_DELAY_SECS overrides the default RETRY_INTERVAL_SECS for
# the initial countdown when the original rate-limit error carried a
# Retry-After header. Empty/zero/non-numeric falls back to RETRY_INTERVAL.
tui_enter_pause() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local reason="${1:-Rate limited}"
    local retry_interval="${2:-0}"
    local max_duration="${3:-0}"
    local first_probe_delay="${4:-}"
    [[ "$retry_interval" =~ ^[0-9]+$ ]] || retry_interval=0
    [[ "$max_duration" =~ ^[0-9]+$ ]] || max_duration=0

    local initial_delay="$retry_interval"
    if [[ -n "$first_probe_delay" ]] && [[ "$first_probe_delay" =~ ^[0-9]+$ ]] \
       && [[ "$first_probe_delay" -gt 0 ]]; then
        initial_delay="$first_probe_delay"
    fi

    local now
    now=$(date +%s)
    _TUI_PAUSE_REASON="$reason"
    _TUI_PAUSE_RETRY_INTERVAL="$retry_interval"
    _TUI_PAUSE_MAX_DURATION="$max_duration"
    _TUI_PAUSE_STARTED_AT="$now"
    _TUI_PAUSE_NEXT_PROBE_AT=$(( now + initial_delay ))
    _TUI_AGENT_STATUS="paused"
    if declare -f tui_append_event &>/dev/null; then
        tui_append_event "warn" "Quota pause: ${reason}"
    else
        _tui_write_status
    fi
}

# tui_update_pause NEXT_PROBE_IN_SECS [ELAPSED_SECS]
# ELAPSED_SECS is accepted for symmetry with the call site but is derived
# from _TUI_PAUSE_STARTED_AT by the renderer, so we only need the next-probe
# countdown to recompute pause_next_probe_at.
tui_update_pause() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    [[ "${_TUI_AGENT_STATUS:-}" == "paused" ]] || return 0
    local next_in="${1:-0}"
    [[ "$next_in" =~ ^[0-9]+$ ]] || next_in=0
    local now
    now=$(date +%s)
    _TUI_PAUSE_NEXT_PROBE_AT=$(( now + next_in ))
    _tui_write_status
}

# tui_exit_pause [RESULT=refreshed|timeout|cancelled]
tui_exit_pause() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local result="${1:-refreshed}"
    case "$result" in
        refreshed|timeout|cancelled) ;;
        *) result="refreshed" ;;
    esac

    local elapsed=0
    if [[ "${_TUI_PAUSE_STARTED_AT:-0}" -gt 0 ]]; then
        elapsed=$(( $(date +%s) - _TUI_PAUSE_STARTED_AT ))
    fi

    _TUI_PAUSE_REASON=""
    _TUI_PAUSE_RETRY_INTERVAL=0
    _TUI_PAUSE_MAX_DURATION=0
    _TUI_PAUSE_STARTED_AT=0
    _TUI_PAUSE_NEXT_PROBE_AT=0
    _TUI_AGENT_STATUS="idle"

    local _level="success" _msg
    case "$result" in
        refreshed) _msg="Quota refreshed — resumed (paused ${elapsed}s)" ;;
        timeout)   _level="error"; _msg="Quota pause timed out after ${elapsed}s" ;;
        cancelled) _level="warn";  _msg="Quota pause cancelled after ${elapsed}s" ;;
    esac
    if declare -f tui_append_event &>/dev/null; then
        tui_append_event "$_level" "$_msg"
    else
        _tui_write_status
    fi
}
