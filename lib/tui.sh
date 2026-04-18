#!/usr/bin/env bash
# =============================================================================
# tui.sh — TUI Mode (rich live display) sidecar manager
#
# Sourced by tekhton.sh — do not run directly.
#
# Spawns tools/tui.py as a background sidecar and writes JSON status snapshots
# to TUI_STATUS_FILE. The sidecar reads the file on a tick and re-renders with
# rich.live. All functions are no-ops unless _TUI_ACTIVE=true, so hook sites
# can call them unconditionally.
# =============================================================================

set -euo pipefail

# shellcheck source=lib/tui_helpers.sh
source "${TEKHTON_HOME}/lib/tui_helpers.sh"

# --- Activation state --------------------------------------------------------

_TUI_ACTIVE=false
_TUI_PID=""
_TUI_STATUS_FILE=""
_TUI_STATUS_TMP=""
_TUI_DISABLED_REASON=""

# Status snapshot fields (exported for hooks)
declare -a _TUI_RECENT_EVENTS=()      # "ts|level|msg" entries (ring buffer)
declare -a _TUI_STAGES_COMPLETE=()    # JSON objects for completed stages
_TUI_CURRENT_STAGE_LABEL=""
_TUI_CURRENT_STAGE_MODEL=""
_TUI_CURRENT_STAGE_NUM=0
_TUI_CURRENT_STAGE_TOTAL=0
_TUI_AGENT_TURNS_USED=0
_TUI_AGENT_TURNS_MAX=0
_TUI_AGENT_ELAPSED_SECS=0
_TUI_AGENT_STATUS="idle"
_TUI_PIPELINE_START_TS=0
_TUI_COMPLETE=false
_TUI_VERDICT=""

# --- Activation check --------------------------------------------------------

# _tui_should_activate — returns 0 when TUI should spawn, 1 otherwise.
# Reason is set in _TUI_DISABLED_REASON when returning 1.
_tui_should_activate() {
    local mode="${TUI_ENABLED:-auto}"
    if [[ "$mode" == "false" ]]; then
        _TUI_DISABLED_REASON="TUI_ENABLED=false"
        return 1
    fi
    if [[ ! -t 1 ]]; then
        _TUI_DISABLED_REASON="non-interactive TTY"
        return 1
    fi
    local venv="${TUI_VENV_DIR:-${REPO_MAP_VENV_DIR:-.claude/indexer-venv}}"
    local py="${PROJECT_DIR:-.}/${venv}/bin/python"
    [[ -x "$py" ]] || py="${PROJECT_DIR:-.}/${venv}/Scripts/python.exe"
    if [[ ! -x "$py" ]]; then
        _TUI_DISABLED_REASON="Python venv not found at ${venv}"
        return 1
    fi
    if ! "$py" -c "import rich" 2>/dev/null; then
        _TUI_DISABLED_REASON="rich library not installed in ${venv}"
        return 1
    fi
    if [[ ! -f "${TEKHTON_HOME}/tools/tui.py" ]]; then
        _TUI_DISABLED_REASON="tools/tui.py missing from TEKHTON_HOME"
        return 1
    fi
    _TUI_PYTHON="$py"
    return 0
}

# --- Lifecycle ---------------------------------------------------------------

# tui_start — check activation, create status file, spawn sidecar.
# Idempotent: safe to call multiple times; only first call spawns.
tui_start() {
    [[ "$_TUI_ACTIVE" == "true" ]] && return 0

    if ! _tui_should_activate; then
        if [[ "${TUI_ENABLED:-auto}" == "true" ]]; then
            warn "[tui] Disabled: ${_TUI_DISABLED_REASON}"
        fi
        return 0
    fi

    local session_dir="${TEKHTON_SESSION_DIR:-/tmp}"
    _TUI_STATUS_FILE="${session_dir}/tui_status.json"
    _TUI_STATUS_TMP="${session_dir}/tui_status.json.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    _tui_write_status

    local tick_ms="${TUI_TICK_MS:-500}"
    # Redirect only stderr to the sidecar log so Python tracebacks are
    # captured for debugging.  tui.py opens /dev/tty directly for rendering
    # and does not depend on fd 1, but we leave stdout unredirected anyway
    # to avoid silently swallowing any output it cannot write to /dev/tty.
    "$_TUI_PYTHON" "${TEKHTON_HOME}/tools/tui.py" \
        --status-file "$_TUI_STATUS_FILE" \
        --tick-ms "$tick_ms" \
        --event-lines "${TUI_EVENT_LINES:-8}" \
        2>"${session_dir}/tui_sidecar.log" &
    _TUI_PID=$!
    _TUI_ACTIVE=true
    log_verbose "[tui] Sidecar started (pid ${_TUI_PID}, status=${_TUI_STATUS_FILE})"
}

# tui_stop — unconditional sidecar teardown. Safe to call when inactive.
tui_stop() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _TUI_ACTIVE=false
    if [[ -n "$_TUI_PID" ]] && kill -0 "$_TUI_PID" 2>/dev/null; then
        kill "$_TUI_PID" 2>/dev/null || true
        # Brief wait so the sidecar can restore terminal state on its own
        for _ in 1 2 3 4 5; do
            kill -0 "$_TUI_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$_TUI_PID" 2>/dev/null || true
        wait "$_TUI_PID" 2>/dev/null || true
    fi
    _TUI_PID=""
    # Safety net: restore terminal state in case the sidecar exited without
    # cleaning up (e.g. SIGKILL before rich could send RMCUP / cnorm).
    # These are no-ops if the terminal is already in normal mode.
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
}

# tui_complete VERDICT — mark complete, give sidecar a final tick, then stop.
tui_complete() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _TUI_VERDICT="${1:-}"
    _TUI_COMPLETE=true
    _TUI_AGENT_STATUS="complete"
    _tui_write_status
    # Small pause so the sidecar reads the final state before we kill it
    sleep 0.3
    tui_stop
}

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
    local max="${TUI_EVENT_LINES:-8}"
    local overflow=$(( ${#_TUI_RECENT_EVENTS[@]} - max ))
    if (( overflow > 0 )); then
        _TUI_RECENT_EVENTS=("${_TUI_RECENT_EVENTS[@]:overflow}")
    fi
    _tui_write_status
}

# --- Atomic status file writer -----------------------------------------------

_tui_write_status() {
    [[ -z "$_TUI_STATUS_FILE" ]] && return 0
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - _TUI_PIPELINE_START_TS ))

    _tui_json_build_status "$elapsed" >"$_TUI_STATUS_TMP" 2>/dev/null || return 0
    mv -f "$_TUI_STATUS_TMP" "$_TUI_STATUS_FILE" 2>/dev/null || true
}
