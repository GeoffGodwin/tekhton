#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tui_liveness.sh — Atomic status-file writer + sampled sidecar liveness probe.
#
# Sourced by lib/tui.sh — do not run directly. Hosts _tui_write_status (the
# hot status-file write path) alongside _tui_check_sidecar_liveness (the
# sampled probe it invokes) so that the writer's invariants and the probe
# that protects them stay co-located.
#
# Why the probe exists: when the Python sidecar self-terminates mid-run
# (most commonly via the watchdog in tools/tui.py:170-198, but also possible
# if the Python process crashes), the parent bash process is not notified —
# _TUI_ACTIVE=true stays set, _TUI_PID becomes stale, and subsequent tui_*
# calls silently write to a status file nobody reads. The probe flips
# _TUI_ACTIVE=false on detected death so downstream tui_* calls cleanly
# no-op, removes the pidfile, and emits one warn line so the transition
# from TUI to CLI is observable to the user.
# =============================================================================

# Liveness sampling counters. Defined here so they exist regardless of
# whether tui.sh has finished sourcing yet.
_TUI_WRITE_COUNT_SINCE_LIVENESS=0
_TUI_LIVENESS_INTERVAL=20

# _tui_write_status — Atomic write of the JSON status snapshot consumed by
# the Python sidecar. Tolerant of missing parent directory and write failures
# (sidecar can read a stale snapshot just fine). Calls the sampled liveness
# probe so a dead sidecar is detected without paying the syscall cost on
# every write.
_tui_write_status() {
    [[ -z "$_TUI_STATUS_FILE" ]] && return 0
    # Batched-write suppression: callers that issue multiple state mutations
    # in sequence (e.g. tui_stage_end auto-closing a substage) bump the
    # counter before the first mutation and decrement after, producing a
    # single coherent write instead of one per mutation.
    (( ${_TUI_SUPPRESS_WRITE:-0} > 0 )) && return 0
    _tui_check_sidecar_liveness
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - _TUI_PIPELINE_START_TS ))

    local parent_dir
    parent_dir=$(dirname "$_TUI_STATUS_TMP")
    [[ ! -d "$parent_dir" ]] && return 0

    _tui_json_build_status "$elapsed" >"$_TUI_STATUS_TMP" 2>/dev/null || return 0
    mv -f "$_TUI_STATUS_TMP" "$_TUI_STATUS_FILE" 2>/dev/null || true
}

# _tui_check_sidecar_liveness — Sampled kill -0 probe of the sidecar process.
# Returns 0 unconditionally so callers can ignore its exit status. Only fires
# the syscall once per _TUI_LIVENESS_INTERVAL invocations to keep the
# status-file write path cheap.
_tui_check_sidecar_liveness() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    [[ -n "${_TUI_PID:-}" ]] || return 0
    _TUI_WRITE_COUNT_SINCE_LIVENESS=$(( _TUI_WRITE_COUNT_SINCE_LIVENESS + 1 ))
    if (( _TUI_WRITE_COUNT_SINCE_LIVENESS < _TUI_LIVENESS_INTERVAL )); then
        return 0
    fi
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    if kill -0 "$_TUI_PID" 2>/dev/null; then
        return 0
    fi
    _TUI_ACTIVE=false
    local dead_pid="$_TUI_PID"
    _TUI_PID=""
    local pidfile="${PROJECT_DIR:-.}/.claude/tui_sidecar.pid"
    rm -f "$pidfile" 2>/dev/null || true
    warn "TUI sidecar exited (pid ${dead_pid}; likely watchdog timeout); continuing in CLI mode"
    return 0
}
