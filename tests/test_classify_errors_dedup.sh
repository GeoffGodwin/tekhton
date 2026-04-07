#!/usr/bin/env bash
set -euo pipefail

# Test: classify_build_errors_all deduplicates multiple unmatched error lines
# Verifies that multiple distinct unmatched lines produce a single "Unclassified build error" entry

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source required libraries
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/error_patterns.sh"

# Test 1: Multiple unmatched lines should deduplicate to single entry
output=$(classify_build_errors_all "unknown error one
unknown error two
unknown error three" | grep -c "Unclassified build error" || true)

if [[ "$output" != "1" ]]; then
    echo "FAIL: Expected 1 'Unclassified build error' entry, got $output"
    exit 1
fi

# Test 2: Mixed matched and unmatched lines
# First, load patterns to verify we have some patterns
load_error_patterns
pattern_count=$(get_pattern_count)
if [[ "$pattern_count" -lt 1 ]]; then
    echo "FAIL: No patterns loaded"
    exit 1
fi

# Test 3: Single unmatched line should produce one entry
output=$(classify_build_errors_all "this is an unknown error line" | grep -c "Unclassified build error" || true)
if [[ "$output" != "1" ]]; then
    echo "FAIL: Expected 1 'Unclassified build error' entry for single line, got $output"
    exit 1
fi

# Test 4: Empty input should produce no output
output=$(classify_build_errors_all "" | wc -l || echo 0)
if [[ "$output" != "0" ]]; then
    echo "FAIL: Expected empty output for empty input, got $output lines"
    exit 1
fi

# Test 5: Unmatched lines produce output in the correct format (pipe-delimited)
output=$(classify_build_errors_all "unknown error")
if ! echo "$output" | grep -q "^code|code||Unclassified build error"; then
    echo "FAIL: Output format incorrect. Expected 'code|code||Unclassified build error', got: '$output'"
    exit 1
fi

echo "PASS"
exit 0
