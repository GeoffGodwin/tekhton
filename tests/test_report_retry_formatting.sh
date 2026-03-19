#!/usr/bin/env bash
# =============================================================================
# test_report_retry_formatting.sh — Verify report_retry() produces correct output
#
# Tests:
#   1. report_retry() outputs to stderr
#   2. Output contains correct category and attempt numbers
#   3. Output contains delay value
#   4. Output includes RETRY label
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"

FAIL=0

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if ! echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        echo "FAIL: $name — expected to find '$needle' in output"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: report_retry outputs to stderr
# =============================================================================

# Capture stderr and stdout separately
stderr_out=$( { report_retry 1 3 "api_500" 30 2>&1 1>/dev/null; } || true )

if [ -z "$stderr_out" ]; then
    echo "FAIL: 1.1 report_retry should output to stderr"
    FAIL=1
else
    echo "✓ Test 1.1: Output goes to stderr"
fi

# =============================================================================
# Test 2: Output contains correct category and attempt numbers
# =============================================================================

output=$( { report_retry 2 5 "api_rate_limit" 60 2>&1; } || true )

assert_contains "2.1 contains attempt number" "$output" "2/5"
assert_contains "2.2 contains category" "$output" "api_rate_limit"
assert_contains "2.3 contains RETRY label" "$output" "RETRY"

# =============================================================================
# Test 3: Output contains delay value
# =============================================================================

output=$( { report_retry 1 3 "api_500" 45 2>&1; } || true )
assert_contains "3.1 contains delay value" "$output" "45"

# =============================================================================
# Test 4: Output includes attempt and max
# =============================================================================

output=$( { report_retry 3 3 "network_timeout" 120 2>&1; } || true )
assert_contains "4.1 contains attempt range" "$output" "3/3"

# =============================================================================
# Test 5: Different categories produce different output
# =============================================================================

output1=$( { report_retry 1 3 "api_500" 30 2>&1; } || true )
output2=$( { report_retry 1 3 "api_overloaded" 30 2>&1; } || true )

# Both should have RETRY but different categories
assert_contains "5.1 output1 has category" "$output1" "api_500"
assert_contains "5.2 output2 has category" "$output2" "api_overloaded"

# They should not be identical
if [ "$output1" = "$output2" ]; then
    echo "FAIL: 5.3 Different categories should produce different output"
    FAIL=1
else
    echo "✓ Test 5.3: Different categories produce different output"
fi

if [ $FAIL -gt 0 ]; then
    exit 1
fi

echo "PASS"
