#!/usr/bin/env bash
# Test: M128 filter_code_errors test stub
# Verifies that the stub passes positional argument instead of reading stdin
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"
source "${TEKHTON_HOME}/tests/build_fix_loop_fixtures.sh"

test_filter_code_errors_accepts_positional_arg() {
    # Test that filter_code_errors takes a positional argument (not stdin)
    local test_input="error: test"
    local result

    # Call with positional arg (not via stdin)
    result=$(filter_code_errors "$test_input")

    # Should return the argument passed to it
    [[ "$result" == "$test_input" ]]
}

test_filter_code_errors_with_empty_arg() {
    # Test that filter_code_errors handles empty args gracefully
    local result

    # Call with empty/missing arg
    result=$(filter_code_errors "")

    # Should return empty string
    [[ -z "$result" ]]
}

test_filter_code_errors_not_reading_stdin() {
    # Verify the stub is not trying to read from stdin
    # by passing stdin and an argument - should use the argument
    local test_input="from_argument"
    local result

    # The stdin won't be used; only the positional arg matters
    result=$(echo "from_stdin" | filter_code_errors "$test_input")

    # Should match the argument, not stdin
    [[ "$result" == "$test_input" ]]
}

# Run tests
result=0

if test_filter_code_errors_accepts_positional_arg; then
    echo "PASS: filter_code_errors accepts and returns positional argument"
else
    echo "FAIL: filter_code_errors doesn't handle positional argument correctly"
    result=1
fi

if test_filter_code_errors_with_empty_arg; then
    echo "PASS: filter_code_errors handles empty argument"
else
    echo "FAIL: filter_code_errors doesn't handle empty argument"
    result=1
fi

if test_filter_code_errors_not_reading_stdin; then
    echo "PASS: filter_code_errors uses positional arg, not stdin"
else
    echo "FAIL: filter_code_errors incorrectly uses stdin"
    result=1
fi

exit $result
