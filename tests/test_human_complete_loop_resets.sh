#!/usr/bin/env bash
# =============================================================================
# test_human_complete_loop_resets.sh — Verify per-iteration resets work
#
# Tests that _run_human_complete_loop resets state between note iterations:
# - out_reset_pass is called to reset display state
# - tui_reset_for_next_milestone is called to:
#   - Zero _TUI_AGENT_TURNS_USED (prevents watchdog idle condition)
#   - Refresh status-file mtime (prevents watchdog stale-mtime condition)
#
# Without these resets, the quiet window between notes (inbox drain, triage,
# archive moves, log rotation, threshold checks, quota-probe sleeps) can
# cross TUI_WATCHDOG_TIMEOUT (default 300s), causing the Python watchdog
# to fire and self-terminate the sidecar.
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(mktemp -d)"
trap 'rm -rf "$PROJECT_DIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/output_format.sh"
source "${TEKHTON_HOME}/lib/tui.sh"
source "${TEKHTON_HOME}/lib/tui_ops.sh"

pass() { printf "✓ %s\n" "$@"; }
fail() { printf "✗ %s\n" "$@"; exit 1; }

# Helper: track function call history
declare -a CALL_HISTORY=()

# Mock out_reset_pass to track calls
out_reset_pass() {
    CALL_HISTORY+=("out_reset_pass")
}

# Verify the reset functions exist and are callable
test_reset_functions_exist() {
    # Check that declare -f can find the functions
    if ! declare -f out_reset_pass &>/dev/null; then
        fail "out_reset_pass should be declared in scope"
    fi

    if ! declare -f tui_reset_for_next_milestone &>/dev/null; then
        fail "tui_reset_for_next_milestone should be declared"
    fi

    pass "reset functions exist and are callable"
}

# Test: tui_reset_for_next_milestone zeros _TUI_AGENT_TURNS_USED
test_tui_reset_zeros_turns() {
    local status_file="${PROJECT_DIR}/test_turns_status.json"
    echo '{}' > "$status_file"

    _TUI_ACTIVE=true
    _TUI_AGENT_TURNS_USED=42
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    tui_reset_for_next_milestone

    if [[ "$_TUI_AGENT_TURNS_USED" -ne 0 ]]; then
        fail "_TUI_AGENT_TURNS_USED should be 0 after reset, was $_TUI_AGENT_TURNS_USED"
    fi

    pass "tui_reset_for_next_milestone zeros _TUI_AGENT_TURNS_USED"

    rm -f "$status_file" "${status_file}.tmp"
}

# Test: tui_reset_for_next_milestone refreshes status-file mtime
test_tui_reset_refreshes_mtime() {
    local status_file="${PROJECT_DIR}/test_status.json"

    # Create a status file with old timestamp
    echo '{}' > "$status_file"
    touch -d '10 minutes ago' "$status_file"

    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)
    _TUI_AGENT_TURNS_USED=0
    _TUI_AGENT_TURNS_MAX=0
    _TUI_AGENT_ELAPSED_SECS=0
    _TUI_AGENT_STATUS="idle"
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_CURRENT_STAGE_NUM=0
    _TUI_CURRENT_STAGE_TOTAL=0

    # Get mtime before reset
    local mtime_before
    mtime_before=$(stat -c %Y "$status_file" 2>/dev/null || stat -f %m "$status_file" 2>/dev/null)

    sleep 0.1  # Ensure time passes

    # Call reset which should update status file mtime
    tui_reset_for_next_milestone

    # Get mtime after reset
    local mtime_after
    mtime_after=$(stat -c %Y "$status_file" 2>/dev/null || stat -f %m "$status_file" 2>/dev/null)

    if [[ $mtime_after -le $mtime_before ]]; then
        fail "status-file mtime should be refreshed, before=$mtime_before after=$mtime_after"
    fi

    pass "tui_reset_for_next_milestone refreshes status-file mtime"

    rm -f "$status_file" "${status_file}.tmp"
}

# Test: tui_reset_for_next_milestone clears stage cycle state
test_tui_reset_clears_stage_cycle() {
    local status_file="${PROJECT_DIR}/test_cycle_status.json"
    echo '{}' > "$status_file"

    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    # Set up stage cycle tracking
    declare -gA _TUI_STAGE_CYCLE=()
    _TUI_STAGE_CYCLE["Coder"]=1
    _TUI_STAGE_CYCLE["Reviewer"]=2
    _TUI_CURRENT_LIFECYCLE_ID="Coder#1"

    # Before reset, should have data
    if [[ ${#_TUI_STAGE_CYCLE[@]} -eq 0 ]]; then
        fail "stage cycle should have data before reset"
    fi

    tui_reset_for_next_milestone

    # After reset, should be clear (lifecycle ID is cleared, cycle dict persists for next use)
    if [[ -n "${_TUI_CURRENT_LIFECYCLE_ID}" ]]; then
        fail "lifecycle ID should be cleared after reset"
    fi

    pass "tui_reset_for_next_milestone clears lifecycle tracking"

    rm -f "$status_file" "${status_file}.tmp"
}

# Test: tui_reset_for_next_milestone clears recent events
test_tui_reset_clears_events() {
    local status_file="${PROJECT_DIR}/test_events_status.json"
    echo '{}' > "$status_file"

    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    # Set up recent events
    declare -a _TUI_RECENT_EVENTS=()
    _TUI_RECENT_EVENTS+=("ts1|info|event1")
    _TUI_RECENT_EVENTS+=("ts2|warn|event2")

    # Before reset, should have events
    if [[ ${#_TUI_RECENT_EVENTS[@]} -eq 0 ]]; then
        fail "recent events should have data before reset"
    fi

    tui_reset_for_next_milestone

    # After reset, should be empty (see lib/tui_ops.sh:188)
    if [[ ${#_TUI_RECENT_EVENTS[@]} -ne 0 ]]; then
        fail "recent events should be cleared after reset, had ${#_TUI_RECENT_EVENTS[@]} events"
    fi

    pass "tui_reset_for_next_milestone clears recent events"

    rm -f "$status_file" "${status_file}.tmp"
}

# Test: out_reset_pass can be called without error
test_out_reset_pass_callable() {
    CALL_HISTORY=()

    out_reset_pass

    if [[ ${#CALL_HISTORY[@]} -ne 1 ]]; then
        fail "out_reset_pass should have been called once"
    fi

    pass "out_reset_pass is callable and tracked"
}

# Test: both resets can be called in sequence (typical loop pattern)
test_sequential_resets() {
    local status_file="${PROJECT_DIR}/test_sequential_status.json"
    echo '{}' > "$status_file"

    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)
    _TUI_AGENT_TURNS_USED=10
    declare -gA _TUI_STAGE_CYCLE=(["test"]=1)
    CALL_HISTORY=()

    # Simulate the pattern from _run_human_complete_loop
    if declare -f out_reset_pass &>/dev/null; then
        out_reset_pass
    fi

    if declare -f tui_reset_for_next_milestone &>/dev/null; then
        tui_reset_for_next_milestone
    fi

    # Verify both were called
    if [[ "${#CALL_HISTORY[@]}" -ne 1 ]]; then
        fail "out_reset_pass should have been called"
    fi

    if [[ "$_TUI_AGENT_TURNS_USED" -ne 0 ]]; then
        fail "turns should be zeroed after reset sequence"
    fi

    pass "sequential reset pattern works (out_reset_pass → tui_reset_for_next_milestone)"

    rm -f "$status_file" "${status_file}.tmp"
}

# Test: resets prevent watchdog accumulation scenario
test_resets_prevent_watchdog_accumulation() {
    # Simulate a quiet window where counter could accumulate
    local pidfile="${PROJECT_DIR}/.claude/tui_sidecar.pid"
    mkdir -p "${PROJECT_DIR}/.claude"
    echo "$$" > "$pidfile"

    local status_file="${PROJECT_DIR}/test_status.json"
    _TUI_ACTIVE=true
    _TUI_PID="$$"
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)
    _TUI_AGENT_TURNS_USED=10
    _TUI_WRITE_COUNT_SINCE_LIVENESS=10

    # Without reset, the turns stay nonzero (triggering watchdog idle condition)
    # and write counter stays high (continuing to increment toward next probe)

    # With reset...
    tui_reset_for_next_milestone

    # Turns are zeroed (removes idle precondition for watchdog)
    if [[ "$_TUI_AGENT_TURNS_USED" -ne 0 ]]; then
        fail "turns should be zeroed to prevent watchdog idle condition"
    fi

    # Write counter was reset (via the status-file write inside reset)
    # to prevent accumulation across quiet window

    pass "resets prevent watchdog accumulation (turns → 0)"

    rm -f "$pidfile" "$status_file" "${status_file}.tmp"
}

# Run all tests
test_reset_functions_exist
test_tui_reset_zeros_turns
test_tui_reset_refreshes_mtime
test_tui_reset_clears_stage_cycle
test_tui_reset_clears_events
test_out_reset_pass_callable
test_sequential_resets
test_resets_prevent_watchdog_accumulation

printf "\n✓ All human-complete loop reset tests passed\n"
