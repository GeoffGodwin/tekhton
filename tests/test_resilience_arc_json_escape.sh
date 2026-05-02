#!/usr/bin/env bash
# Test: M135/M134 JSON heredoc escaping
# Verifies _arc_json_escape helper is used to prevent injection
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"
source "${TEKHTON_HOME}/tests/resilience_arc_fixtures.sh"

test_arc_json_escape_exists() {
    # Verify the helper function exists
    grep -q "_arc_json_escape" "${TEKHTON_HOME}/tests/resilience_arc_fixtures.sh"
}

test_arc_json_escape_escapes_quotes() {
    # Test that the function escapes double quotes
    local test_input='test"value'
    local result
    result=$(_arc_json_escape "$test_input")

    # Should contain escaped quote
    [[ "$result" == 'test\"value' ]] || [[ "$result" == 'test\\"value' ]]
}

test_escape_applied_in_write_functions() {
    # Verify _arc_write_v2_failure_context uses the escape helper
    grep -q "_arc_json_escape" "${TEKHTON_HOME}/tests/resilience_arc_fixtures.sh" && \
    grep -A 5 "_arc_write_v2_failure_context" "${TEKHTON_HOME}/tests/resilience_arc_fixtures.sh" | \
    grep -q "_arc_json_escape"
}

# Run tests
result=0

if test_arc_json_escape_exists; then
    echo "PASS: _arc_json_escape helper function exists"
else
    echo "FAIL: _arc_json_escape not found"
    result=1
fi

if test_arc_json_escape_escapes_quotes; then
    echo "PASS: JSON escape function handles quotes correctly"
else
    echo "FAIL: JSON escape function doesn't escape properly"
    result=1
fi

if test_escape_applied_in_write_functions; then
    echo "PASS: Escape helper applied in write functions"
else
    echo "FAIL: Escape helper not applied"
    result=1
fi

exit $result
