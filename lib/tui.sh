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

# shellcheck source=lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

# shellcheck source=lib/tui_helpers.sh
source "${TEKHTON_HOME}/lib/tui_helpers.sh"

# shellcheck source=lib/tui_ops.sh
source "${TEKHTON_HOME}/lib/tui_ops.sh"

# shellcheck source=lib/tui_ops_substage.sh
source "${TEKHTON_HOME}/lib/tui_ops_substage.sh"

# --- Activation state --------------------------------------------------------

# Exported so child processes (e.g. tests spawned via `bash tests/...`) see the
# sidecar-active signal and can suppress their own direct-to-/dev/tty writes.
export _TUI_ACTIVE=false
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
_TUI_STAGE_START_TS=0
_TUI_PIPELINE_START_TS=0
_TUI_COMPLETE=false
_TUI_VERDICT=""

# Run context (set by tui_set_context before tui_start). These are surfaced
# in the JSON status so the Python sidecar can render run_mode, non-default
# CLI flags, and the stage-pills row in the header.
_TUI_RUN_MODE="task"
_TUI_CLI_FLAGS=""
declare -a _TUI_STAGE_ORDER=()

# M110 lifecycle identity: per-label monotonic cycle counter + current owner id.
# Keys are canonical display labels (from get_stage_display_label). Values are
# the last allocated cycle number. Every tui_stage_begin increments the counter
# for its label and records "<label>#<cycle>" as the current owner.
declare -gA _TUI_STAGE_CYCLE=()
_TUI_CURRENT_LIFECYCLE_ID=""
declare -gA _TUI_CLOSED_LIFECYCLE_IDS=()

# M113 hierarchical substage API. A substage is a transient phase (scout,
# rework, architect-remediation) that runs inside an already-open pipeline
# stage. Its begin/end calls never mutate the parent stage's label, start
# timestamp, lifecycle id, or the stages_complete record array.
_TUI_CURRENT_SUBSTAGE_LABEL=""
_TUI_CURRENT_SUBSTAGE_START_TS=0

# M124 quota-pause awareness. Populated by tui_enter_pause / tui_update_pause
# while enter_quota_pause is blocking on a Claude usage-limit refresh.
# All five fields are emitted in every status snapshot (empty/0 when not
# paused) so the JSON shape stays stable for the sidecar consumer.
# _TUI_AGENT_STATUS reverts to "paused" while a pause is active; the
# spinner subshell is stopped before the pause and respawned on resume,
# so no other writer is racing for that field.
_TUI_PAUSE_REASON=""
_TUI_PAUSE_RETRY_INTERVAL=0
_TUI_PAUSE_MAX_DURATION=0
_TUI_PAUSE_STARTED_AT=0
_TUI_PAUSE_NEXT_PROBE_AT=0

# Batched-write semaphore: bump to coalesce multiple mutations into one
# status-file write. _tui_write_status returns early when > 0.
_TUI_SUPPRESS_WRITE=0

# --- Activation check --------------------------------------------------------

# _tui_should_activate — returns 0 when TUI should spawn, 1 otherwise.
# Reason is set in _TUI_DISABLED_REASON when returning 1.
_tui_should_activate() {
    local mode="${TUI_ENABLED:-auto}"
    if [[ "$mode" == "false" ]]; then
        _TUI_DISABLED_REASON="TUI_ENABLED=false"
        return 1
    fi
    # Conservative: gate on stdout being a TTY even though the sidecar
    # writes directly to /dev/tty. Keeps `tekhton.sh | tee log` predictable
    # (plain output to the log, no TUI) rather than leaking escape sequences
    # through /dev/tty while stdout captures log text.
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

# _tui_kill_stale — kill any leftover sidecar from a prior crashed run.
# Uses a project-level PID file so orphans don't accumulate across runs.
_tui_kill_stale() {
    local pidfile="${PROJECT_DIR:-.}/.claude/tui_sidecar.pid"
    [[ -f "$pidfile" ]] || return 0
    local stale_pid
    stale_pid=$(cat "$pidfile" 2>/dev/null) || return 0
    [[ -n "$stale_pid" ]] || return 0
    if kill -0 "$stale_pid" 2>/dev/null; then
        kill "$stale_pid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$stale_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$stale_pid" 2>/dev/null || true
        wait "$stale_pid" 2>/dev/null || true
    fi
    rm -f "$pidfile" 2>/dev/null || true
}

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

    # Kill any orphan sidecar from a prior crashed run
    _tui_kill_stale

    local session_dir="${TEKHTON_SESSION_DIR:-/tmp}"
    _TUI_STATUS_FILE="${session_dir}/tui_status.json"
    _TUI_STATUS_TMP="${session_dir}/tui_status.json.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    _tui_write_status

    local tick_ms="${TUI_TICK_MS:-500}"
    local -a _tui_args=(
        "${TEKHTON_HOME}/tools/tui.py"
        --status-file "$_TUI_STATUS_FILE"
        --tick-ms "$tick_ms"
        --event-lines "${TUI_EVENT_LINES:-60}"
        --watchdog-secs "${TUI_WATCHDOG_TIMEOUT:-300}"
    )
    if [[ "${TUI_SIMPLE_LOGO:-false}" == "true" ]]; then
        _tui_args+=(--simple-logo)
    fi
    # Redirect only stderr to the sidecar log so Python tracebacks are
    # captured for debugging.  tui.py opens /dev/tty directly for rendering
    # and does not depend on fd 1, but we leave stdout unredirected anyway
    # to avoid silently swallowing any output it cannot write to /dev/tty.
    "$_TUI_PYTHON" "${_tui_args[@]}" \
        2>"${session_dir}/tui_sidecar.log" &
    _TUI_PID=$!
    _TUI_ACTIVE=true

    # Write PID file for stale-sidecar cleanup on next run
    local pidfile="${PROJECT_DIR:-.}/.claude/tui_sidecar.pid"
    echo "$_TUI_PID" > "$pidfile" 2>/dev/null || true

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
    # Remove PID file so next run doesn't try to kill a recycled PID
    rm -f "${PROJECT_DIR:-.}/.claude/tui_sidecar.pid" 2>/dev/null || true
    # Safety net: restore terminal state in case the sidecar exited without
    # cleaning up (e.g. SIGKILL before rich could send RMCUP / cnorm).
    # These are no-ops if the terminal is already in normal mode.
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    # Restore ICRNL (input CR→NL translation) which Rich may leave disabled
    stty icrnl 2>/dev/null || true
}

# tui_complete VERDICT — mark complete, wait for the sidecar to finish its
# hold-on-complete prompt (user presses Enter), then force-stop after
# TUI_COMPLETE_HOLD_TIMEOUT seconds. Set the timeout to 0 for the pre-M98
# behaviour (brief pause + kill, suitable for CI / non-interactive wrappers).
tui_complete() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _TUI_VERDICT="${1:-}"
    _TUI_COMPLETE=true
    _TUI_AGENT_STATUS="complete"
    _tui_write_status

    local hold_timeout="${TUI_COMPLETE_HOLD_TIMEOUT:-120}"
    if [[ "$hold_timeout" =~ ^[0-9]+$ ]] && (( hold_timeout > 0 )) && [[ -n "$_TUI_PID" ]]; then
        # Counter-based wait avoids forking `date +%s` on every 100ms tick
        # (up to ~1200 forks over the default 120s hold).
        local ticks=0
        local max_ticks=$(( hold_timeout * 10 ))
        while kill -0 "$_TUI_PID" 2>/dev/null; do
            (( ticks < max_ticks )) || break
            sleep 0.1
            ticks=$(( ticks + 1 ))
        done
    else
        sleep 0.3
    fi
    tui_stop
}

# tui_set_context RUN_MODE FLAGS_STRING STAGE1 [STAGE2 ...]
#
# Populate the run-context globals that flow into the JSON status file.  Must
# be called before tui_start (if called afterward the first header render
# will use defaults).  The stage list is the ordered set of pipeline stages
# for this run (e.g. intake scout coder security review tester), used by the
# sidecar to render the stage-pills row.
tui_set_context() {
    _TUI_RUN_MODE="${1:-task}"
    _TUI_CLI_FLAGS="${2:-}"
    if (( $# >= 2 )); then
        shift 2
    else
        shift "$#"
    fi
    _TUI_STAGE_ORDER=("$@")
}

# --- Atomic status file writer -----------------------------------------------

_tui_write_status() {
    [[ -z "$_TUI_STATUS_FILE" ]] && return 0
    # Batched-write suppression: callers that issue multiple state mutations
    # in sequence (e.g. tui_stage_end auto-closing a substage) bump the
    # counter before the first mutation and decrement after, producing a
    # single coherent write instead of one per mutation.
    (( ${_TUI_SUPPRESS_WRITE:-0} > 0 )) && return 0
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - _TUI_PIPELINE_START_TS ))

    _tui_json_build_status "$elapsed" >"$_TUI_STATUS_TMP" 2>/dev/null || return 0
    mv -f "$_TUI_STATUS_TMP" "$_TUI_STATUS_FILE" 2>/dev/null || true
}
