#!/usr/bin/env bash
# =============================================================================
# agent_spinner.sh — Agent CLI activity indicator (spinner) subshell management
#
# Sourced by lib/agent.sh — do not run directly. Provides two separate paths:
#   * Non-TUI: subshell writes progress to /dev/tty + dashboard heartbeat.
#   * TUI:     subshell pushes turn/elapsed updates to the sidecar status file.
# Neither path can accidentally write to /dev/tty for the other's use case.
#
# Callers set two locals and read them back after the agent returns:
#   _spinner_pid       — non-TUI subshell PID (empty when TUI active)
#   _tui_updater_pid   — TUI subshell PID (empty when TUI inactive)
# =============================================================================
set -euo pipefail

# _start_agent_spinner LABEL TURNS_FILE MAX_TURNS
# Echoes two PIDs separated by `:`: <spinner_pid>:<tui_updater_pid>.
# Either value is empty when the corresponding path is not active.
# Caller MUST parse with `IFS=: read` — using whitespace would lose a leading
# empty field (TUI path) and route the PID into the wrong variable, causing
# _stop_agent_spinner to take the non-TUI branch and corrupt the alt screen.
_start_agent_spinner() {
    local label="$1"
    local turns_file="$2"
    local max_turns="$3"
    local spinner_pid=""
    local tui_updater_pid=""

    if [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ -e /dev/tty ]] \
       && [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        (
            trap 'exit 0' INT TERM
            chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            start_ts=$(date +%s)
            i=0
            _last_refresh=0
            _refresh_interval="${DASHBOARD_REFRESH_INTERVAL:-10}"
            while true; do
                now=$(date +%s)
                elapsed=$(( now - start_ts ))
                mins=$(( elapsed / 60 ))
                secs=$(( elapsed % 60 ))
                _turns_display="--"
                if [[ -f "$turns_file" ]]; then
                    _cur_turns=$(cat "$turns_file" 2>/dev/null || echo "")
                    [[ "$_cur_turns" =~ ^[0-9]+$ ]] && _turns_display="$_cur_turns"
                fi
                printf '\r\033[0;36m[tekhton]\033[0m %s %s (%dm%02ds, %s/%s turns) ' \
                    "${chars:i%${#chars}:1}" "$label" "$mins" "$secs" \
                    "$_turns_display" "$max_turns" > /dev/tty
                i=$(( i + 1 ))
                if (( elapsed - _last_refresh >= _refresh_interval )); then
                    if command -v emit_dashboard_run_state &>/dev/null; then
                        emit_dashboard_run_state 2>/dev/null || true
                    fi
                    _last_refresh=$elapsed
                fi
                sleep 0.2
            done
        ) &
        spinner_pid=$!
    elif [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ "${_TUI_ACTIVE:-false}" == "true" ]] \
         && declare -f tui_update_agent &>/dev/null; then
        # TUI active: lightweight updater pushes turn count to the sidecar.
        # No terminal writes of any kind in this path.
        (
            trap 'exit 0' INT TERM
            start_ts=$(date +%s)
            while true; do
                elapsed=$(( $(date +%s) - start_ts ))
                _turns_display="--"
                _tui_turns=0
                if [[ -f "$turns_file" ]]; then
                    _cur_turns=$(cat "$turns_file" 2>/dev/null || echo "")
                    [[ "$_cur_turns" =~ ^[0-9]+$ ]] && _turns_display="$_cur_turns"
                fi
                [[ "$_turns_display" =~ ^[0-9]+$ ]] && _tui_turns="$_turns_display"
                tui_update_agent "$_tui_turns" "$max_turns" "$elapsed" 2>/dev/null || true
                sleep 0.2
            done
        ) &
        tui_updater_pid=$!
    fi

    printf '%s:%s\n' "$spinner_pid" "$tui_updater_pid"
}

# _stop_agent_spinner SPINNER_PID TUI_UPDATER_PID
# Kills whichever subshell is running; only the non-TUI path clears /dev/tty.
_stop_agent_spinner() {
    local spinner_pid="${1:-}"
    local tui_updater_pid="${2:-}"
    if [[ -n "$spinner_pid" ]]; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
        printf '\r\033[K' > /dev/tty 2>/dev/null || true
    fi
    if [[ -n "$tui_updater_pid" ]]; then
        kill "$tui_updater_pid" 2>/dev/null || true
        wait "$tui_updater_pid" 2>/dev/null || true
    fi
}
