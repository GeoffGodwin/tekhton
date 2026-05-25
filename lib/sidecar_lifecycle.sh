#!/usr/bin/env bash
# =============================================================================
# sidecar_lifecycle.sh — Python TUI sidecar lifecycle + _tui_call helper.
#
# The TUI writer subsystem (status JSON construction, atomic writes, sampled
# liveness probe, stage/agent/event mutators, pause state machine, substage
# breadcrumbs) is owned by Go under internal/tui/ and exposed through
# `tekhton tui ...` subcommands. This file holds the small remaining bash
# residue: globals that gate writer invocation, a thin helper that execs the
# Go binary, and the Python sidecar process lifecycle (spawn / kill /
# hold-on-complete wait) — the sidecar is a long-running child of the bash
# orchestrator and can't move to Go without restructuring how the supervisor
# owns its descendants.
#
# Sourced by lib/output.sh — do not run directly.
# =============================================================================
set -euo pipefail

# Bash-side activation globals. Files in lib/ and stages/ gate their TUI-mode
# behavior on _TUI_ACTIVE; mutators read _TUI_STATUS_FILE to find the JSON
# file the sidecar is polling; the lifecycle helpers below read _TUI_PID to
# know which Python child to signal at end-of-run.
: "${_TUI_ACTIVE:=false}"
: "${_TUI_PID:=}"
: "${_TUI_STATUS_FILE:=}"
export _TUI_ACTIVE _TUI_PID _TUI_STATUS_FILE

# _tui_bin — resolve the Go binary path. Echoes the path or returns 1.
_tui_bin() {
    local default="${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}"
    if [[ -x "$default" ]]; then
        printf '%s' "$default"
        return 0
    fi
    return 1
}

# _tui_call SUBCMD [ARGS...] — invoke `tekhton tui SUBCMD ...` against the
# active status file. No-op when TUI is inactive or the tekhton binary is
# missing. The standard --status-file flag is added automatically.
_tui_call() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local bin
    bin="$(_tui_bin)" || return 0
    local sub="${1:-}"
    [[ -z "$sub" ]] && return 0
    shift
    if [[ -n "${_TUI_STATUS_FILE:-}" ]]; then
        "$bin" tui "$sub" --status-file "$_TUI_STATUS_FILE" "$@" 2>/dev/null || true
    else
        "$bin" tui "$sub" "$@" 2>/dev/null || true
    fi
}

# _sidecar_spawn RUN_MODE CLI_FLAGS [STAGE1 STAGE2 ...]
# Activate the TUI: gate on TTY+venv+rich+tui.py, seed tui_status.json via
# `tekhton tui start`, then fork the Python sidecar. Sets _TUI_PID,
# _TUI_ACTIVE=true, _TUI_STATUS_FILE. Silent no-op when any gate fails.
_sidecar_spawn() {
    [[ "$_TUI_ACTIVE" == "true" ]] && return 0
    local mode="${TUI_ENABLED:-auto}"
    [[ "$mode" == "false" ]] && return 0
    [[ -t 1 ]] || return 0
    local venv="${TUI_VENV_DIR:-${REPO_MAP_VENV_DIR:-.claude/indexer-venv}}"
    local py="${PROJECT_DIR:-.}/${venv}/bin/python"
    [[ -x "$py" ]] || py="${PROJECT_DIR:-.}/${venv}/Scripts/python.exe"
    [[ -x "$py" ]] || return 0
    "$py" -c "import rich" 2>/dev/null || return 0
    [[ -f "${TEKHTON_HOME}/tools/tui.py" ]] || return 0

    local run_mode="${1:-task}"
    local cli_flags="${2:-}"
    if (( $# >= 2 )); then shift 2; else shift "$#"; fi
    local stages_csv=""
    if (( $# > 0 )); then
        printf -v stages_csv '%s,' "$@"
        stages_csv="${stages_csv%,}"
    fi
    # Export so later set-context calls (e.g. mid-run stage re-seeding) can
    # reuse the same run_mode + cli_flags without recomputing them.
    _TUI_RUN_MODE="$run_mode"
    _TUI_CLI_FLAGS="$cli_flags"
    export _TUI_RUN_MODE _TUI_CLI_FLAGS

    local session_dir="${TEKHTON_SESSION_DIR:-/tmp}"
    _TUI_STATUS_FILE="${session_dir}/tui_status.json"
    export TEKHTON_TUI_STATUS_FILE="$_TUI_STATUS_FILE"

    local bin
    if bin="$(_tui_bin)"; then
        local -a _start_args=(
            tui start
            --status-file "$_TUI_STATUS_FILE"
            --run-mode "$run_mode"
            --cli-flags "$cli_flags"
        )
        if [[ -n "$stages_csv" ]]; then
            _start_args+=(--stage-order "$stages_csv")
        fi
        "$bin" "${_start_args[@]}" 2>/dev/null || return 0
    fi

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
    "$py" "${_tui_args[@]}" 2>"${session_dir}/tui_sidecar.log" &
    _TUI_PID=$!
    _TUI_ACTIVE=true
    export TEKHTON_TUI_PID="$_TUI_PID"

    local pidfile="${PROJECT_DIR:-.}/.claude/tui_sidecar.pid"
    echo "$_TUI_PID" > "$pidfile" 2>/dev/null || true
}

# _tui_restore_terminal — undo the terminal state changes the Python sidecar
# applies (alternate screen, cursor hide, ICRNL toggle). Called from the
# cleanup trap on interactive exits.
_tui_restore_terminal() {
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    stty icrnl 2>/dev/null || true
}

# _sidecar_kill — terminate the Python sidecar. Tolerant of stale pidfiles
# and idempotent so the cleanup trap can call it after a normal stop.
_sidecar_kill() {
    local pidfile="${PROJECT_DIR:-.}/.claude/tui_sidecar.pid"
    local target_pid="${_TUI_PID:-}"
    if [[ -z "$target_pid" ]] && [[ -f "$pidfile" ]]; then
        target_pid=$(cat "$pidfile" 2>/dev/null) || target_pid=""
    fi
    _TUI_ACTIVE=false
    unset TEKHTON_TUI_PID
    [[ "$target_pid" =~ ^[1-9][0-9]*$ ]] || target_pid=""
    if [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
        kill "$target_pid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$target_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$target_pid" 2>/dev/null || true
        wait "$target_pid" 2>/dev/null || true
    fi
    _TUI_PID=""
    rm -f "$pidfile" 2>/dev/null || true
}

# M117: compute a TUI-only source attribution for Recent Events. Consults
# the M113 substage label and the current pipeline stage label; returns the
# breadcrumb form "stage » substage" when both are set, the stage label
# alone when no substage is active, or empty before any stage is open.
# Skipped when TUI_LIFECYCLE_V2=false so the opt-out flag suppresses the
# whole attribution surface (matches M113's no-op substage behavior).
_tui_compute_source() {
    if [[ "${TUI_LIFECYCLE_V2:-true}" == "false" ]]; then
        printf ''
        return 0
    fi
    local stage="${_TUI_CURRENT_STAGE_LABEL:-}"
    local sub="${_TUI_CURRENT_SUBSTAGE_LABEL:-}"
    if [[ -n "$stage" && -n "$sub" ]]; then
        printf '%s » %s' "$stage" "$sub"
    elif [[ -n "$sub" ]]; then
        printf '%s' "$sub"
    elif [[ -n "$stage" ]]; then
        printf '%s' "$stage"
    fi
}

# _tui_notify LEVEL MSG... — push a runtime event onto the sidecar's ring
# buffer with the current stage/substage breadcrumb as the source. The
# `declare -f` guard tolerates standalone tests that source individual lib
# files without the full output.sh / sidecar_lifecycle.sh chain and unset
# _tui_call to exercise the absent-helper path.
_tui_notify() {
    declare -f _tui_call &>/dev/null || return 0
    local level="$1"; shift
    local _src
    _src=$(_tui_compute_source)
    _tui_call append-event --level "$level" --message "$(_tui_strip_ansi "$*")" \
        --type runtime --source "$_src"
}

# _sidecar_complete_hold VERDICT — flip complete=true in the status file,
# wait up to TUI_COMPLETE_HOLD_TIMEOUT seconds for the sidecar to exit on
# its own (user presses Enter on the hold screen), then kill.
_sidecar_complete_hold() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _tui_call complete --verdict "${1:-}"
    local hold_timeout="${TUI_COMPLETE_HOLD_TIMEOUT:-120}"
    if [[ "$hold_timeout" =~ ^[0-9]+$ ]] && (( hold_timeout > 0 )) \
        && [[ -n "${_TUI_PID:-}" ]]; then
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
    _sidecar_kill
}
