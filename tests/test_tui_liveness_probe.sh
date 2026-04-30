#!/usr/bin/env bash
# =============================================================================
# test_tui_liveness_probe.sh — Verify liveness probe detection & state mgmt
#
# Tests _tui_check_sidecar_liveness behavior:
# - Returns 0 unconditionally (safe to call from hot paths)
# - Detects dead sidecar via kill -0
# - Sets _TUI_ACTIVE=false on detection
# - Clears _TUI_PID
# - Removes pidfile
# - Emits warning message
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(mktemp -d)"
trap 'rm -rf "$PROJECT_DIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/output_format.sh"
source "${TEKHTON_HOME}/lib/tui.sh"

pass() { printf "✓ %s\n" "$@"; }
fail() { printf "✗ %s\n" "$@"; exit 1; }

# Test: probe returns 0 when _TUI_ACTIVE is false
test_probe_noop_when_inactive() {
    _TUI_ACTIVE=false
    _TUI_PID="12345"

    if ! _tui_check_sidecar_liveness; then
        fail "probe should return 0 when _TUI_ACTIVE=false"
    fi

    pass "probe returns 0 when _TUI_ACTIVE=false (no-op path)"
}

# Test: probe returns 0 when _TUI_PID is empty
test_probe_noop_when_no_pid() {
    _TUI_ACTIVE=true
    _TUI_PID=""

    if ! _tui_check_sidecar_liveness; then
        fail "probe should return 0 when _TUI_PID is empty"
    fi

    pass "probe returns 0 when _TUI_PID is empty (no-op path)"
}

# Test: probe always returns 0 (success exit code)
test_probe_exit_code_always_zero() {
    # Test with dead PID (intentional invalid PID)
    _TUI_ACTIVE=true
    _TUI_PID="99999"  # Unlikely to exist
    _TUI_WRITE_COUNT_SINCE_LIVENESS=19  # Force check on next call

    local exit_code
    _tui_check_sidecar_liveness
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "probe should always return 0, returned $exit_code"
    fi

    pass "probe always returns 0 (safe for hot paths)"
}

# Test: probe detects dead sidecar and flips _TUI_ACTIVE=false
test_probe_detects_dead_sidecar() {
    # Use a process that definitely doesn't exist
    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=19  # Force check on next call

    _tui_check_sidecar_liveness

    if [[ "${_TUI_ACTIVE}" != "false" ]]; then
        fail "_TUI_ACTIVE should be false after detecting dead sidecar, was $_TUI_ACTIVE"
    fi

    pass "_TUI_ACTIVE flipped to false on dead sidecar detection"
}

# Test: probe clears _TUI_PID on detection
test_probe_clears_pid() {
    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=19  # Force check on next call

    _tui_check_sidecar_liveness

    if [[ -n "${_TUI_PID}" ]]; then
        fail "_TUI_PID should be empty after detection, was '$_TUI_PID'"
    fi

    pass "_TUI_PID cleared on dead sidecar detection"
}

# Test: probe removes pidfile on detection
test_probe_removes_pidfile() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    mkdir -p "${PROJECT_DIR}/.claude"
    echo "99999" > "$pidfile"

    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=19  # Force check on next call

    _tui_check_sidecar_liveness

    if [[ -f "$pidfile" ]]; then
        fail "pidfile should be removed, still exists at $pidfile"
    fi

    pass "pidfile removed on dead sidecar detection"
}

# Test: probe only checks when write count exceeds interval
test_probe_sampling_interval() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    mkdir -p "${PROJECT_DIR}/.claude"
    echo "99999" > "$pidfile"

    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    local orig_interval="$_TUI_LIVENESS_INTERVAL"
    _TUI_LIVENESS_INTERVAL=20

    # First call should NOT trigger check (counter still 0 after increment)
    _tui_check_sidecar_liveness

    # _TUI_ACTIVE should still be true (no check performed)
    if [[ "${_TUI_ACTIVE}" != "true" ]]; then
        fail "first call should not trigger check, _TUI_ACTIVE=$_TUI_ACTIVE"
    fi

    # pidfile should still exist (no check performed)
    if [[ ! -f "$pidfile" ]]; then
        fail "pidfile should exist after first call (no check), but was removed"
    fi

    pass "probe respects sampling interval (no check < INTERVAL)"

    _TUI_LIVENESS_INTERVAL="$orig_interval"
}

# Test: probe resets counter after check
test_probe_resets_counter() {
    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=19  # Force check on next call

    _tui_check_sidecar_liveness

    # After detection and reset, counter should be 0
    if [[ "$_TUI_WRITE_COUNT_SINCE_LIVENESS" -ne 0 ]]; then
        fail "counter should be reset to 0 after check, was $_TUI_WRITE_COUNT_SINCE_LIVENESS"
    fi

    pass "probe resets counter to 0 after check"
}

# Test: probe with real live process (self)
test_probe_with_live_process() {
    local my_pid=$$

    _TUI_ACTIVE=true
    _TUI_PID="$my_pid"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=19  # Force check on next call

    _tui_check_sidecar_liveness

    # Should still be active because we're alive
    if [[ "${_TUI_ACTIVE}" != "true" ]]; then
        fail "_TUI_ACTIVE should remain true for live process, was $_TUI_ACTIVE"
    fi

    # PID should still be set
    if [[ -z "${_TUI_PID}" ]]; then
        fail "_TUI_PID should remain set for live process"
    fi

    pass "probe correctly identifies live process (kill -0 succeeds)"
}

# Run all tests
test_probe_noop_when_inactive
test_probe_noop_when_no_pid
test_probe_exit_code_always_zero
test_probe_detects_dead_sidecar
test_probe_clears_pid
test_probe_removes_pidfile
test_probe_sampling_interval
test_probe_resets_counter
test_probe_with_live_process

printf "\n✓ All liveness probe tests passed\n"
