#!/usr/bin/env bash
# =============================================================================
# test_tui_liveness_sampling.sh — Verify probe sampling (only N writes)
#
# Tests that the liveness probe only fires every _TUI_LIVENESS_INTERVAL
# status-file writes (default 20) to avoid paying the syscall cost in
# the hot path. Verifies:
# - Probe doesn't fire before reaching interval
# - Probe fires exactly at interval boundary
# - Counter resets after probe fires
# - Multiple sampling cycles work correctly
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

# Test: counter increments on each probe call (when active with PID)
test_counter_increments() {
    _TUI_ACTIVE=true
    _TUI_PID="$$"  # Use our own PID (alive process)
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    local start_count="$_TUI_WRITE_COUNT_SINCE_LIVENESS"

    # Call probe when active (should increment counter)
    _tui_check_sidecar_liveness

    local after_count="$_TUI_WRITE_COUNT_SINCE_LIVENESS"
    if [[ $after_count -ne $(( start_count + 1 )) ]]; then
        fail "counter should increment, was $start_count, now $after_count"
    fi

    pass "probe increments write counter on each call (when active with PID)"
}

# Test: probe doesn't check before reaching interval
test_no_check_before_interval() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    mkdir -p "${PROJECT_DIR}/.claude"
    echo "99999" > "$pidfile"

    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    local orig_interval="$_TUI_LIVENESS_INTERVAL"
    _TUI_LIVENESS_INTERVAL=10

    # Call 9 times (counter goes 0→1, 1→2, ..., 8→9, all < 10)
    for i in {1..9}; do
        _tui_check_sidecar_liveness
        # After each call, _TUI_ACTIVE should still be true (no detection yet)
        if [[ "${_TUI_ACTIVE}" != "true" ]]; then
            fail "after call $i, should not have detected dead sidecar yet"
        fi
    done

    # pidfile should still exist (no check performed)
    if [[ ! -f "$pidfile" ]]; then
        fail "pidfile should exist after 9 calls, no check should have fired"
    fi

    pass "probe doesn't fire before reaching interval (9 calls, interval=10)"

    _TUI_LIVENESS_INTERVAL="$orig_interval"
}

# Test: probe fires exactly at interval boundary
test_probe_fires_at_interval() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    mkdir -p "${PROJECT_DIR}/.claude"
    echo "99999" > "$pidfile"

    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    local orig_interval="$_TUI_LIVENESS_INTERVAL"
    _TUI_LIVENESS_INTERVAL=5

    # Call 5 times: counter goes 0→1, 1→2, 2→3, 3→4, 4→5 (triggers on 5)
    for i in {1..5}; do
        _tui_check_sidecar_liveness
        if [[ $i -lt 5 ]]; then
            # Before 5th call completes, should still be active
            if [[ "${_TUI_ACTIVE}" != "true" ]]; then
                fail "before 5th call, should still be active"
            fi
        fi
    done

    # After 5th call, should have detected death
    if [[ "${_TUI_ACTIVE}" != "false" ]]; then
        fail "_TUI_ACTIVE should be false after 5th call (interval reached)"
    fi

    if [[ -f "$pidfile" ]]; then
        fail "pidfile should be removed after interval fires"
    fi

    pass "probe fires exactly at interval boundary (5 calls, interval=5)"

    _TUI_LIVENESS_INTERVAL="$orig_interval"
}

# Test: counter resets after probe fires
test_counter_resets_after_fire() {
    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    local orig_interval="$_TUI_LIVENESS_INTERVAL"
    _TUI_LIVENESS_INTERVAL=3

    # Call 3 times to trigger the check
    for i in {1..3}; do
        _tui_check_sidecar_liveness
    done

    # After probe fires, counter should be 0
    if [[ "$_TUI_WRITE_COUNT_SINCE_LIVENESS" -ne 0 ]]; then
        fail "counter should reset to 0 after check fires"
    fi

    pass "counter resets to 0 after probe fires"

    _TUI_LIVENESS_INTERVAL="$orig_interval"
}

# Test: second sampling cycle works correctly
test_second_sampling_cycle() {
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    mkdir -p "${PROJECT_DIR}/.claude"
    echo "99999" > "$pidfile"

    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    local orig_interval="$_TUI_LIVENESS_INTERVAL"
    _TUI_LIVENESS_INTERVAL=3

    # First cycle: 3 calls to trigger detection
    for i in {1..3}; do
        _tui_check_sidecar_liveness
    done

    if [[ "${_TUI_ACTIVE}" != "false" ]]; then
        fail "first cycle should detect death"
    fi

    # Reset for second cycle (simulating new sidecar spawn)
    rm -f "$pidfile"
    _TUI_ACTIVE=true
    _TUI_PID="88888"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    echo "88888" > "$pidfile"

    # Second cycle: 3 more calls to verify fresh sampling
    for i in {1..2}; do
        _tui_check_sidecar_liveness
    done

    # After 2 calls, should still be looking for interval
    if [[ "$_TUI_WRITE_COUNT_SINCE_LIVENESS" -ne 2 ]]; then
        fail "counter should be at 2, was $_TUI_WRITE_COUNT_SINCE_LIVENESS"
    fi

    pass "second sampling cycle initializes correctly after reset"

    _TUI_LIVENESS_INTERVAL="$orig_interval"
}

# Test: interval setting is respected at runtime
test_interval_configuration() {
    _TUI_ACTIVE=true
    _TUI_PID="99999"
    _TUI_WRITE_COUNT_SINCE_LIVENESS=0
    local orig_interval="$_TUI_LIVENESS_INTERVAL"

    # Set custom interval
    _TUI_LIVENESS_INTERVAL=7

    # Call 6 times (all < 7)
    for i in {1..6}; do
        _tui_check_sidecar_liveness
        if [[ "${_TUI_ACTIVE}" != "true" ]]; then
            fail "with interval=7, should not fire before 7 calls"
        fi
    done

    pass "probe respects runtime interval configuration (interval=7)"

    _TUI_LIVENESS_INTERVAL="$orig_interval"
}

# Test: default interval value
test_default_interval() {
    # The default from tui_liveness.sh:24
    if [[ "$_TUI_LIVENESS_INTERVAL" -ne 20 ]]; then
        fail "default _TUI_LIVENESS_INTERVAL should be 20, was $_TUI_LIVENESS_INTERVAL"
    fi

    pass "default _TUI_LIVENESS_INTERVAL is 20"
}

# Run all tests
test_counter_increments
test_no_check_before_interval
test_probe_fires_at_interval
test_counter_resets_after_fire
test_second_sampling_cycle
test_interval_configuration
test_default_interval

printf "\n✓ All liveness sampling tests passed\n"
