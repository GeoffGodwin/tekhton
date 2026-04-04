#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_plan_trap_restore.sh — Test trap save/restore in _call_planning_batch
#
# Tests the fix for _call_planning_batch where previous signal handlers are
# preserved instead of being cleared with `trap - INT TERM` (Observation 2).
#
# The fragility was that global trap clearing would lose any handlers set by
# calling code, e.g., agent.sh's monitor trap or test cleanup traps.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_TEST_MODE=1  # Disable spinner in _call_planning_batch

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/plan.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

_make_test_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "$tmpdir"
}

_cleanup_test_dir() {
    [[ -n "${1:-}" ]] && rm -rf "$1"
}

# =============================================================================
# Test 1: Previous trap handlers are captured and restored
# =============================================================================

echo "=== Previous trap handlers are captured and restored ==="

# Create a mock claude command that succeeds and outputs text
mkdir -p /tmp/tekhton_test_bin
cat > /tmp/tekhton_test_bin/claude << 'EOF'
#!/bin/bash
# Mock claude: accept arguments and output placeholder text
cat <<'ENDOUT'
This is a test design document output from the planning agent.
ENDOUT
exit 0
EOF
chmod +x /tmp/tekhton_test_bin/claude

# Add to PATH so the mock is found
export PATH="/tmp/tekhton_test_bin:$PATH"

TEST_DIR=$(_make_test_dir)
export PROJECT_DIR="$TEST_DIR"

# Create a test logfile
LOG_FILE="$TEST_DIR/plan.log"

# Track whether the cleanup trap was called
CLEANUP_CALLED=0

# Set a pre-existing INT handler that we want to preserve
trap 'CLEANUP_CALLED=1' INT

# Capture the trap before calling _call_planning_batch
PREV_INT_TRAP=$(trap -p INT)

# Call _call_planning_batch with minimal arguments
# It will set temporary INT/TERM handlers and restore them
_call_planning_batch "claude-3.5-sonnet" "5" "Test prompt" "$LOG_FILE" > /dev/null 2>&1
local_rc=$?

# Check that the function completed without error
if [[ $local_rc -eq 0 ]]; then
    pass
else
    fail "_call_planning_batch exited with code $local_rc"
fi

# Verify the log file was created
if [[ -f "$LOG_FILE" ]]; then
    pass
else
    fail "Log file was not created"
fi

# Verify the previous trap handler is still set
CURRENT_INT_TRAP=$(trap -p INT)
if [[ "$PREV_INT_TRAP" == "$CURRENT_INT_TRAP" ]]; then
    pass
else
    fail "INT trap was not restored: expected '$PREV_INT_TRAP' but got '$CURRENT_INT_TRAP'"
fi

# The trap handler should still be functional (send INT to test)
# For safety, we use kill -0 to test without actually sending signal
# If the handler is set, trap -p INT should show it
if [[ -n "$CURRENT_INT_TRAP" ]] && [[ "$CURRENT_INT_TRAP" == *"CLEANUP_CALLED"* ]]; then
    pass
else
    fail "INT trap handler was lost or modified"
fi

trap - INT  # Clean up the test trap

_cleanup_test_dir "$TEST_DIR"

# =============================================================================
# Test 2: TERM trap is also preserved
# =============================================================================

echo "=== TERM trap is also preserved ==="

TEST_DIR=$(_make_test_dir)
export PROJECT_DIR="$TEST_DIR"

LOG_FILE="$TEST_DIR/plan2.log"

TERM_CLEANUP_CALLED=0

# Set a pre-existing TERM handler
trap 'TERM_CLEANUP_CALLED=1' TERM

# Capture the trap before calling _call_planning_batch
PREV_TERM_TRAP=$(trap -p TERM)

# Call _call_planning_batch
_call_planning_batch "claude-3.5-sonnet" "5" "Test prompt" "$LOG_FILE" > /dev/null 2>&1
local_rc=$?

if [[ $local_rc -eq 0 ]]; then
    pass
else
    fail "_call_planning_batch exited with code $local_rc on TERM test"
fi

# Verify the previous TERM trap handler is still set
CURRENT_TERM_TRAP=$(trap -p TERM)
if [[ "$PREV_TERM_TRAP" == "$CURRENT_TERM_TRAP" ]]; then
    pass
else
    fail "TERM trap was not restored: expected '$PREV_TERM_TRAP' but got '$CURRENT_TERM_TRAP'"
fi

if [[ -n "$CURRENT_TERM_TRAP" ]] && [[ "$CURRENT_TERM_TRAP" == *"TERM_CLEANUP_CALLED"* ]]; then
    pass
else
    fail "TERM trap handler was lost or modified"
fi

trap - TERM  # Clean up the test trap

_cleanup_test_dir "$TEST_DIR"

# =============================================================================
# Test 3: No pre-existing handlers — function still works correctly
# =============================================================================

echo "=== Function works correctly with no pre-existing handlers ==="

TEST_DIR=$(_make_test_dir)
export PROJECT_DIR="$TEST_DIR"

LOG_FILE="$TEST_DIR/plan3.log"

# Explicitly clear any INT/TERM handlers
trap - INT TERM 2>/dev/null || true

# Call _call_planning_batch
_call_planning_batch "claude-3.5-sonnet" "5" "Test prompt" "$LOG_FILE" > /dev/null 2>&1
local_rc=$?

if [[ $local_rc -eq 0 ]]; then
    pass
else
    fail "_call_planning_batch exited with code $local_rc with no pre-existing handlers"
fi

# Verify log was created
if [[ -f "$LOG_FILE" ]]; then
    pass
else
    fail "Log file was not created with no pre-existing handlers"
fi

# Verify that INT trap is not set after the function returns
# (when no pre-existing handler was present)
remaining_int=$(trap -p INT)
if [[ -z "$remaining_int" ]]; then
    pass
else
    fail "INT trap was set when no prior handler existed: $remaining_int"
fi

# Verify that TERM trap is not set after the function returns
remaining_term=$(trap -p TERM)
if [[ -z "$remaining_term" ]]; then
    pass
else
    fail "TERM trap was set when no prior handler existed: $remaining_term"
fi

_cleanup_test_dir "$TEST_DIR"

# =============================================================================
# Cleanup
# =============================================================================

rm -rf /tmp/tekhton_test_bin

# =============================================================================
# Summary
# =============================================================================

echo
echo "Passed: $PASS  Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
else
    exit 1
fi
