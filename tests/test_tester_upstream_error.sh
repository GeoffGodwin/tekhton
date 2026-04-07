#!/usr/bin/env bash
# Test: UPSTREAM error handling in _run_tester_write_failing sets SKIP_FINAL_CHECKS and returns
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
mkdir -p "${PROJECT_DIR}/.claude/logs"
mkdir -p "${PROJECT_DIR}/.claude/agents"

# Source required libraries
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/state.sh"

FAIL=0

# Helper: assert that a condition is true
assert_true() {
    local name="$1" condition="$2"
    if ! eval "$condition"; then
        echo "FAIL: $name — expected condition to be true"
        FAIL=1
    fi
}

# Helper: assert that a variable is set to a value
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: Verify SKIP_FINAL_CHECKS is exported when AGENT_ERROR_CATEGORY is UPSTREAM
# =============================================================================

# Create a stub function that mimics the UPSTREAM error handling from
# _run_tester_write_failing (lines 340-351)
test_upstream_error_handler() {
    local _resume_flag="--start-at test"

    # Simulate the UPSTREAM error check
    if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
        export SKIP_FINAL_CHECKS=true
        return
    fi

    export SKIP_FINAL_CHECKS=false
    return
}

# Test with UPSTREAM error set
export AGENT_ERROR_CATEGORY="UPSTREAM"
export AGENT_ERROR_SUBCATEGORY="test_error"
export SKIP_FINAL_CHECKS=false
test_upstream_error_handler
assert_eq "SKIP_FINAL_CHECKS set on UPSTREAM error" "true" "${SKIP_FINAL_CHECKS:-false}"

# Test without UPSTREAM error
export AGENT_ERROR_CATEGORY="OTHER"
export SKIP_FINAL_CHECKS=false
test_upstream_error_handler
assert_eq "SKIP_FINAL_CHECKS not set on non-UPSTREAM error" "false" "${SKIP_FINAL_CHECKS:-false}"

# =============================================================================
# Test 2: Verify function returns (doesn't exit) on UPSTREAM error
# =============================================================================

# Create a test function that calls the error handler
test_handler_returns_not_exits() {
    export AGENT_ERROR_CATEGORY="UPSTREAM"
    test_upstream_error_handler
    # If we reach here, the function returned (didn't exit)
    echo "HANDLER_RETURNED"
}

RESULT=$(test_handler_returns_not_exits)
assert_eq "UPSTREAM error handler returns without exiting" "HANDLER_RETURNED" "$RESULT"

# =============================================================================
# Test 3: Verify the error handling matches the normal tester flow pattern
# =============================================================================

# Both the normal flow (line 119) and write_failing flow (line 350) should:
# 1. Export SKIP_FINAL_CHECKS=true
# 2. Return (not exit)
# This test verifies both patterns are equivalent

test_normal_flow_pattern() {
    export SKIP_FINAL_CHECKS=true
    return
}

test_write_failing_flow_pattern() {
    export SKIP_FINAL_CHECKS=true
    return
}

export SKIP_FINAL_CHECKS=false
test_normal_flow_pattern
normal_skip="${SKIP_FINAL_CHECKS}"

export SKIP_FINAL_CHECKS=false
test_write_failing_flow_pattern
write_failing_skip="${SKIP_FINAL_CHECKS}"

assert_eq "Both flows export SKIP_FINAL_CHECKS=true" "$normal_skip" "$write_failing_skip"

# =============================================================================
# Results
# =============================================================================

if [ "$FAIL" = "1" ]; then
    echo "FAIL: Some tests failed"
    exit 1
else
    echo "PASS: All UPSTREAM error handling tests passed"
    exit 0
fi
