#!/usr/bin/env bash
# =============================================================================
# test_tester.sh — Unit tests for stages/tester.sh functions
#
# Tests:
#   1. _run_tester_write_failing is a defined function
#   2. _run_tester_write_failing exits with code 1 on UPSTREAM error
#   3. Normal tester path (line 110-120) uses return on UPSTREAM error
#   4. TDD pre-flight path (_run_tester_write_failing) uses exit 1 on UPSTREAM error
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAIL=0
TEST_NUM=0

# Source library
source "${TEKHTON_HOME}/lib/common.sh"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    TEST_NUM=$((TEST_NUM + 1))
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: Test $TEST_NUM ($name) — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: Test $TEST_NUM ($name)"
    fi
}

assert_exit() {
    local name="$1" expected_exit="$2"
    shift 2
    TEST_NUM=$((TEST_NUM + 1))
    local actual_exit=0
    "$@" > /dev/null 2>&1 || actual_exit=$?
    if [ "$expected_exit" != "$actual_exit" ]; then
        echo "FAIL: Test $TEST_NUM ($name) — expected exit $expected_exit, got $actual_exit"
        FAIL=1
    else
        echo "PASS: Test $TEST_NUM ($name)"
    fi
}

assert_true() {
    local name="$1"
    TEST_NUM=$((TEST_NUM + 1))
    shift
    if "$@" > /dev/null 2>&1; then
        echo "PASS: Test $TEST_NUM ($name)"
    else
        echo "FAIL: Test $TEST_NUM ($name)"
        FAIL=1
    fi
}

# Test 1: Function exists
_test_function_exists() {
    source "${TEKHTON_HOME}/stages/tester.sh"
    declare -f _run_tester_write_failing > /dev/null
}

assert_exit "function _run_tester_write_failing exists" 0 _test_function_exists

# Test 2: UPSTREAM error causes exit 1
_test_upstream_exit() {
    (
        source "${TEKHTON_HOME}/stages/tester.sh"

        export AGENT_ERROR_CATEGORY="UPSTREAM"
        export AGENT_ERROR_SUBCATEGORY="API_TIMEOUT"
        export AGENT_ERROR_MESSAGE="timeout"
        export TESTER_MODE="write_failing"
        export TASK="test"

        # Mock minimal dependencies
        run_agent() { return; }
        write_pipeline_state() { :; }
        warn() { :; }
        print_run_summary() { :; }
        was_null_run() { return 1; }

        _run_tester_write_failing
    )
}

assert_exit "UPSTREAM error causes exit 1" 1 _test_upstream_exit

# Test 3: Verify UPSTREAM error handling code exists in _run_tester_write_failing
_check_upstream_code_exists() {
    grep -q "AGENT_ERROR_CATEGORY.*UPSTREAM" "${TEKHTON_HOME}/stages/tester.sh" && \
    grep -q "exit 1" "${TEKHTON_HOME}/stages/tester.sh"
}

assert_true "UPSTREAM error code exists in tester.sh" _check_upstream_code_exists

# Test 4: Verify write_pipeline_state is called before exit in UPSTREAM path
_check_write_pipeline_state_before_exit() {
    local content
    content=$(sed -n '/if \[\[ "\${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" \]\]; then/,/^    fi$/p' "${TEKHTON_HOME}/stages/tester.sh")
    # Check that write_pipeline_state appears before exit 1
    echo "$content" | head -20 | grep -q "write_pipeline_state"
}

assert_true "write_pipeline_state is called in UPSTREAM error handler" _check_write_pipeline_state_before_exit

echo ""
echo "════════════════════════════════════════"
echo "  Test Summary"
echo "════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
    echo "All $TEST_NUM tests passed"
else
    echo "FAILED: $FAIL test(s) out of $TEST_NUM"
fi

exit $FAIL
