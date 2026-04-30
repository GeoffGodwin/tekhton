#!/usr/bin/env bash
# =============================================================================
# test_tui_pid_validation.sh — Security fix: validate PID before kill
#
# Tests that _tui_kill_stale and tui_stop reject malformed PIDs:
# - Negative numbers (-1, -999) → regex fails → no kill call
# - Zero (0) → regex fails → no kill call
# - Non-numeric (abc, xyz) → regex fails → no kill call
# - Valid positive integers (1, 12345) → regex passes → kill called (safely)
#
# Prevents kill -0 -1 (signals any process) and kill -1 (SIGHUP all).
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(mktemp -d)"
trap 'rm -rf "$PROJECT_DIR"' EXIT

mkdir -p "${PROJECT_DIR}/.claude"

# Stub the output functions so tests run clean
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

source "${TEKHTON_HOME}/lib/tui.sh"

pass() { printf "✓ %s\n" "$@"; }
fail() { printf "✗ %s\n" "$@"; exit 1; }

# --- Test _tui_kill_stale validation ----------------------------------------

# Test: -1 in pidfile is rejected
test_kill_stale_rejects_negative() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    echo "-1" > "$pidfile"

    _tui_kill_stale

    # If regex validation works, pidfile should still exist (early return)
    if [[ ! -f "$pidfile" ]]; then
        fail "_tui_kill_stale should not process PID=-1 (rejected by regex)"
    fi

    pass "_tui_kill_stale rejects PID=-1 (negative number)"
}

# Test: 0 in pidfile is rejected
test_kill_stale_rejects_zero() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    echo "0" > "$pidfile"

    _tui_kill_stale

    if [[ ! -f "$pidfile" ]]; then
        fail "_tui_kill_stale should not process PID=0 (rejected by regex)"
    fi

    pass "_tui_kill_stale rejects PID=0"
}

# Test: non-numeric value is rejected
test_kill_stale_rejects_nonnumeric() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    echo "abcdef" > "$pidfile"

    _tui_kill_stale

    if [[ ! -f "$pidfile" ]]; then
        fail "_tui_kill_stale should not process non-numeric PID (rejected by regex)"
    fi

    pass "_tui_kill_stale rejects non-numeric PID"
}

# Test: valid positive integer is accepted and validated with kill -0
test_kill_stale_accepts_valid_pid() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    # Use a PID that definitely doesn't exist
    echo "999999" > "$pidfile"

    _tui_kill_stale

    # Pidfile should be removed (kill -0 failed, so removed as stale)
    if [[ -f "$pidfile" ]]; then
        fail "_tui_kill_stale should remove pidfile even for non-existent PID"
    fi

    pass "_tui_kill_stale accepts and processes valid PID=999999"
}

# --- Test tui_stop validation -----------------------------------------------

# Test: -1 in pidfile is safely handled (regex validation prevents kill)
test_tui_stop_rejects_negative() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    echo "-1" > "$pidfile"

    _TUI_ACTIVE=false
    _TUI_PID=""

    # Should not raise an error; regex validation prevents kill -0 -1
    if ! tui_stop 2>/dev/null; then
        fail "tui_stop should complete without error for PID=-1"
    fi

    # _TUI_ACTIVE should be false
    if [[ "${_TUI_ACTIVE}" != "false" ]]; then
        fail "_TUI_ACTIVE should be false"
    fi

    pass "tui_stop safely handles PID=-1 (regex validation prevents kill)"
}

# Test: 0 in pidfile is safely handled
test_tui_stop_rejects_zero() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    echo "0" > "$pidfile"

    _TUI_ACTIVE=false
    _TUI_PID=""

    if ! tui_stop 2>/dev/null; then
        fail "tui_stop should complete without error for PID=0"
    fi

    if [[ "${_TUI_ACTIVE}" != "false" ]]; then
        fail "_TUI_ACTIVE should be false"
    fi

    pass "tui_stop safely handles PID=0 (regex validation prevents kill)"
}

# Test: non-numeric is safely handled
test_tui_stop_rejects_nonnumeric() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    echo "not_a_pid" > "$pidfile"

    _TUI_ACTIVE=false
    _TUI_PID=""

    if ! tui_stop 2>/dev/null; then
        fail "tui_stop should complete without error for non-numeric PID"
    fi

    if [[ "${_TUI_ACTIVE}" != "false" ]]; then
        fail "_TUI_ACTIVE should be false"
    fi

    pass "tui_stop safely handles non-numeric PID (regex validation prevents kill)"
}

# Test: valid PID is accepted
test_tui_stop_accepts_valid_pid() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    echo "999999" > "$pidfile"

    _TUI_ACTIVE=false
    _TUI_PID=""

    tui_stop

    # Pidfile should be removed (kill -0 failed, so cleaned up)
    if [[ -f "$pidfile" ]]; then
        fail "tui_stop should remove pidfile after processing valid PID"
    fi

    pass "tui_stop accepts and processes valid PID=999999"
}

# Test: regex validation for _TUI_PID fallback path
test_tui_stop_validates_tui_pid() {
    _TUI_ACTIVE=false
    _TUI_PID="-1"

    tui_stop

    # tui_stop should have cleared _TUI_PID (rejected by regex check)
    if [[ -n "${_TUI_PID}" ]]; then
        fail "tui_stop should clear _TUI_PID when it contains invalid value"
    fi

    pass "tui_stop validates _TUI_PID directly (rejects -1)"
}

# Test: valid _TUI_PID is used
test_tui_stop_uses_valid_tui_pid() {
    _TUI_ACTIVE=true
    _TUI_PID="999999"
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    rm -f "$pidfile"

    tui_stop

    # _TUI_ACTIVE should be false after cleanup
    if [[ "${_TUI_ACTIVE}" != "false" ]]; then
        fail "tui_stop should set _TUI_ACTIVE=false"
    fi

    # _TUI_PID should be cleared
    if [[ -n "${_TUI_PID}" ]]; then
        fail "tui_stop should clear _TUI_PID after cleanup"
    fi

    pass "tui_stop processes valid _TUI_PID=999999"
}

# --- Run all tests ---

test_kill_stale_rejects_negative
test_kill_stale_rejects_zero
test_kill_stale_rejects_nonnumeric
test_kill_stale_accepts_valid_pid

test_tui_stop_rejects_negative
test_tui_stop_rejects_zero
test_tui_stop_rejects_nonnumeric
test_tui_stop_accepts_valid_pid
test_tui_stop_validates_tui_pid
test_tui_stop_uses_valid_tui_pid

printf "\n✓ All PID validation tests passed\n"
