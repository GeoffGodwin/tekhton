#!/usr/bin/env bash
# =============================================================================
# tui.sh — m23 thin shim. The TUI writer subsystem (status JSON construction,
# atomic writes, sampled liveness probe, stage/agent/event mutators, pause
# state machine, substage breadcrumbs) is owned by Go under
# internal/tui/ and exposed through `tekhton tui ...` subcommands.
#
# This file is the bash-caller seam. Each bash function below is a thin
# wrapper that execs the Go binary; no business logic lives here. The five
# previously-satellite files (tui_helpers.sh, tui_liveness.sh, tui_ops.sh,
# tui_ops_pause.sh, tui_ops_substage.sh) are deleted at m23 close — their
# logic moved to internal/tui/.
#
# Why this single shim file survives the m23 deletion sweep:
# 28+ bash callsites across lib/agent.sh, lib/agent_spinner.sh, lib/quota.sh,
# lib/quota_sleep.sh, stages/coder.sh, stages/architect.sh, stages/review.sh,
# tekhton.sh, tekhton-legacy.sh — each one uses the `declare -f tui_X` /
# `command -v tui_X` guard pattern to no-op when TUI is inactive. Mechanically
# substituting every callsite for `${tekhton_bin} tui X` is a 1000-line patch
# whose blast radius dwarfs the rest of the milestone. The shim keeps the
# function-name seam stable while the *writer logic* fully ports. A follow-up
# milestone (or patch series) can migrate callsites once the Go implementation
# proves itself in dogfood.
#
# Activation: `tui_start` sets _TUI_ACTIVE=true and exports
# TEKHTON_TUI_STATUS_FILE so the shim's other wrappers know where to write.
# =============================================================================
set -euo pipefail

# shellcheck source=lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

# Resolve the Go binary that owns the writer logic. TEKHTON_BIN overrides;
# falls back to bin/tekhton under TEKHTON_HOME.
_tui_bin() {
    if [[ -n "${TEKHTON_BIN:-}" ]] && [[ -x "${TEKHTON_BIN}" ]]; then
        printf '%s' "${TEKHTON_BIN}"
        return 0
    fi
    local default="${TEKHTON_HOME}/bin/tekhton"
    if [[ -x "$default" ]]; then
        printf '%s' "$default"
        return 0
    fi
    return 1
}

# Activation globals. Preserved for the small number of callsites that still
# branch on _TUI_ACTIVE (e.g. lib/agent_spinner.sh, lib/output.sh).
export _TUI_ACTIVE=false
_TUI_PID=""
_TUI_STATUS_FILE=""

# tui_start — spawn the Python sidecar and seed tui_status.json. Mirrors the
# pre-m23 activation gating (TTY check, venv presence, rich import).
tui_start() {
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

    local session_dir="${TEKHTON_SESSION_DIR:-/tmp}"
    _TUI_STATUS_FILE="${session_dir}/tui_status.json"
    export TEKHTON_TUI_STATUS_FILE="$_TUI_STATUS_FILE"

    # Seed the status file (proto envelope) so the sidecar reads something
    # on its first tick.
    local bin
    if bin="$(_tui_bin)"; then
        "$bin" tui start \
            --status-file "$_TUI_STATUS_FILE" \
            --run-mode "${_TUI_RUN_MODE:-task}" \
            --cli-flags "${_TUI_CLI_FLAGS:-}" 2>/dev/null || return 0
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

# tui_stop — terminate the sidecar. Tolerant of stale pidfiles.
tui_stop() {
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

_tui_restore_terminal() {
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    stty icrnl 2>/dev/null || true
}

# tui_complete VERDICT — mark complete, wait for sidecar exit (or timeout),
# then force-stop. Drives the sidecar's hold-on-complete prompt.
tui_complete() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin
    if bin="$(_tui_bin)" && [[ -n "${_TUI_STATUS_FILE:-}" ]]; then
        "$bin" tui complete --status-file "$_TUI_STATUS_FILE" --verdict "${1:-}" 2>/dev/null || true
    fi
    local hold_timeout="${TUI_COMPLETE_HOLD_TIMEOUT:-120}"
    if [[ "$hold_timeout" =~ ^[0-9]+$ ]] && (( hold_timeout > 0 )) && [[ -n "$_TUI_PID" ]]; then
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
tui_set_context() {
    _TUI_RUN_MODE="${1:-task}"
    _TUI_CLI_FLAGS="${2:-}"
    if (( $# >= 2 )); then shift 2; else shift "$#"; fi
    local stages_csv=""
    if (( $# > 0 )); then
        printf -v stages_csv '%s,' "$@"
        stages_csv="${stages_csv%,}"
    fi
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin
    bin="$(_tui_bin)" || return 0
    "$bin" tui set-context \
        --status-file "${_TUI_STATUS_FILE}" \
        --run-mode "$_TUI_RUN_MODE" \
        --cli-flags "$_TUI_CLI_FLAGS" \
        --stages "$stages_csv" 2>/dev/null || true
}

# Stage / agent / event mutators. Each is a thin wrapper around the Go CLI.
tui_stage_begin() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui stage-begin --status-file "$_TUI_STATUS_FILE" \
        --label "${1:-}" --model "${2:-}" 2>/dev/null || true
}

tui_stage_end() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui stage-end --status-file "$_TUI_STATUS_FILE" \
        --label "${1:-}" --model "${2:-}" --turns "${3:-}" --time "${4:-}" --verdict "${5:-}" 2>/dev/null || true
}

tui_update_stage() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui update-stage --status-file "$_TUI_STATUS_FILE" \
        --num "${1:-0}" --total "${2:-0}" --label "${3:-}" --model "${4:-}" 2>/dev/null || true
}

tui_finish_stage() {
    # Maps to stage-end without auto-close (close-but-skip-substage-auto-close
    # is not yet a CLI verb; in practice every caller uses stage_end now).
    tui_stage_end "$@"
}

tui_update_agent() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui update-agent --status-file "$_TUI_STATUS_FILE" \
        --turns-used "${1:-0}" --turns-max "${2:-0}" --elapsed-secs "${3:-0}" \
        --lifecycle-id "${4:-}" 2>/dev/null || true
}

tui_append_event() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui append-event --status-file "$_TUI_STATUS_FILE" \
        --level "${1:-info}" --message "${2:-}" --type "${3:-runtime}" --source "${4:-}" 2>/dev/null || true
}

tui_append_summary_event() {
    tui_append_event "${1:-info}" "${2:-}" "summary"
}

tui_substage_begin() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    [[ "${TUI_LIFECYCLE_V2:-true}" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui substage-begin --status-file "$_TUI_STATUS_FILE" --label "${1:-}" 2>/dev/null || true
}

tui_substage_end() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    [[ "${TUI_LIFECYCLE_V2:-true}" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui substage-end --status-file "$_TUI_STATUS_FILE" --label "${1:-}" --verdict "${2:-}" 2>/dev/null || true
}

tui_enter_pause() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui pause-enter --status-file "$_TUI_STATUS_FILE" \
        --reason "${1:-Rate limited}" --retry-interval "${2:-0}" --max-duration "${3:-0}" \
        --first-probe-delay "${4:-0}" 2>/dev/null || true
}

tui_update_pause() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui pause-update --status-file "$_TUI_STATUS_FILE" --next-in "${1:-0}" 2>/dev/null || true
}

tui_exit_pause() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui pause-exit --status-file "$_TUI_STATUS_FILE" --result "${1:-refreshed}" 2>/dev/null || true
}

tui_reset_for_next_milestone() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local bin; bin="$(_tui_bin)" || return 0
    "$bin" tui reset --status-file "$_TUI_STATUS_FILE" 2>/dev/null || true
}

# Legacy lifecycle-id accessor; the Go side computes ids server-side, so we
# return an empty string here. Callers that captured a lifecycle id before
# sleeping still pass it back via tui_update_agent; the Go side drops late
# updates whose id no longer matches the current owner.
tui_current_lifecycle_id() { printf '%s' ""; }
