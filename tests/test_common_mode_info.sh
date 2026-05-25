#!/usr/bin/env bash
# test_common_mode_info.sh — Verify mode_info() output behavior in TUI and non-TUI modes

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Test globals required by common.sh
_TUI_ACTIVE=false
LOG_FILE=""
TUI_APPEND_EVENT_CALLS=0

# Source common.sh (transitively pulls in sidecar_lifecycle.sh's _tui_call).
source "$TEKHTON_HOME/lib/common.sh"

# m23: stub _tui_call AFTER sourcing so we override the lifecycle helper
# rather than racing it. Increment on append-event subcommand only — the
# subcommand router is what the post-m23 _tui_notify drives.
_tui_call() {
    local sub="${1:-}"
    [[ "$sub" == "append-event" ]] && { ((TUI_APPEND_EVENT_CALLS++)) || true; }
    return 0
}

# Test 1: Default behavior (TUI inactive, no log file)
# Should echo to stdout with CYAN color and [~] prefix
test_mode_info_default() {
    _TUI_ACTIVE=false
    LOG_FILE=""
    TUI_APPEND_EVENT_CALLS=0

    output=$(mode_info "test message" 2>&1)

    # Verify output contains [~] prefix and message
    if ! echo "$output" | grep -q '\[~\]'; then
        echo "FAIL: test_mode_info_default — output missing [~] prefix"
        return 1
    fi

    if ! echo "$output" | grep -q "test message"; then
        echo "FAIL: test_mode_info_default — output missing message"
        return 1
    fi

    # Verify CYAN color code is in output (ANSI escape code)
    if ! echo "$output" | grep -q $'\033'; then
        echo "FAIL: test_mode_info_default — output missing color code"
        return 1
    fi

    echo "PASS: test_mode_info_default"
    return 0
}

# Test 2: TUI active with log file
# Should write to log file (without colors), not to stdout
test_mode_info_tui_with_logfile() {
    _TUI_ACTIVE=true
    LOG_FILE="$TMPDIR/test.log"
    TUI_APPEND_EVENT_CALLS=0
    touch "$LOG_FILE"

    # Don't use subshell to preserve variable state
    mode_info "logged message" 2>/dev/null || true

    # Verify log file contains the message with [~] prefix but no color codes
    if ! grep -q '\[~\] logged message' "$LOG_FILE"; then
        echo "FAIL: test_mode_info_tui_with_logfile — log file missing expected content"
        cat "$LOG_FILE" | sed 's/^/  /'
        return 1
    fi

    # Verify _tui_notify was called (tui_append_event incremented)
    if [[ $TUI_APPEND_EVENT_CALLS -eq 0 ]]; then
        echo "FAIL: test_mode_info_tui_with_logfile — tui_append_event not called, got $TUI_APPEND_EVENT_CALLS"
        return 1
    fi

    echo "PASS: test_mode_info_tui_with_logfile"
    return 0
}

# Test 3: TUI active without log file
# Should call _tui_notify but not write to stdout or file
test_mode_info_tui_no_logfile() {
    _TUI_ACTIVE=true
    LOG_FILE=""
    TUI_APPEND_EVENT_CALLS=0

    # Redirect stdout to verify nothing is written to stdout
    mode_info "tui-only message" > /tmp/mode_info_stdout.txt 2>&1 || true

    # Verify output is NOT echoed to stdout
    if [[ -s /tmp/mode_info_stdout.txt ]]; then
        echo "FAIL: test_mode_info_tui_no_logfile — should not echo to stdout"
        cat /tmp/mode_info_stdout.txt
        return 1
    fi

    # Verify _tui_notify was called
    if [[ $TUI_APPEND_EVENT_CALLS -eq 0 ]]; then
        echo "FAIL: test_mode_info_tui_no_logfile — tui_append_event not called"
        return 1
    fi

    echo "PASS: test_mode_info_tui_no_logfile"
    return 0
}

# Test 4: Multiple calls append to log file
# Should accumulate messages rather than overwrite
test_mode_info_logfile_accumulation() {
    _TUI_ACTIVE=true
    LOG_FILE="$TMPDIR/accumulate.log"
    TUI_APPEND_EVENT_CALLS=0
    touch "$LOG_FILE"

    mode_info "first" > /dev/null 2>&1
    mode_info "second" > /dev/null 2>&1

    if ! grep -q '\[~\] first' "$LOG_FILE"; then
        echo "FAIL: test_mode_info_logfile_accumulation — first message missing"
        return 1
    fi

    if ! grep -q '\[~\] second' "$LOG_FILE"; then
        echo "FAIL: test_mode_info_logfile_accumulation — second message missing"
        return 1
    fi

    # Verify both calls recorded
    if [[ $TUI_APPEND_EVENT_CALLS -lt 2 ]]; then
        echo "FAIL: test_mode_info_logfile_accumulation — expected 2+ tui_notify calls, got $TUI_APPEND_EVENT_CALLS"
        return 1
    fi

    echo "PASS: test_mode_info_logfile_accumulation"
    return 0
}

# Run all tests
all_pass=true
test_mode_info_default || all_pass=false
test_mode_info_tui_with_logfile || all_pass=false
test_mode_info_tui_no_logfile || all_pass=false
test_mode_info_logfile_accumulation || all_pass=false

if $all_pass; then
    exit 0
else
    exit 1
fi
