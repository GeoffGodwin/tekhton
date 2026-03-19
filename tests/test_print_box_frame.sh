#!/usr/bin/env bash
# =============================================================================
# test_print_box_frame.sh — Tests for _print_box_frame() and the em-dash
# fallback added to report_retry() in lib/common.sh
#
# Tests:
#   1. _print_box_frame() outputs to stderr
#   2. _print_box_frame() uses ASCII box chars in non-UTF-8 terminal
#   3. _print_box_frame() uses Unicode box chars in UTF-8 terminal
#   4. _print_box_frame() renders each positional argument as a content line
#   5. _print_box_frame() renders empty-string arg as a blank separator line
#   6. report_retry() uses "--" (double-dash) in non-UTF-8 terminal
#   7. report_retry() uses "—" (em-dash) in UTF-8 terminal
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"

FAIL=0

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL: $name — expected to find '$needle' in output"
        FAIL=1
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL: $name — expected NOT to find '$needle' in output"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: _print_box_frame() outputs to stderr, not stdout
# =============================================================================

stdout_out=$( LANG=C LC_ALL=C _print_box_frame "hello" 2>/dev/null ) || true
stderr_out=$( LANG=C LC_ALL=C _print_box_frame "hello" 2>&1 1>/dev/null ) || true

if [ -n "$stdout_out" ]; then
    echo "FAIL: 1.1 _print_box_frame should not write to stdout"
    FAIL=1
else
    echo "✓ Test 1.1: No output on stdout"
fi

if [ -z "$stderr_out" ]; then
    echo "FAIL: 1.2 _print_box_frame should write to stderr"
    FAIL=1
else
    echo "✓ Test 1.2: Output goes to stderr"
fi

# =============================================================================
# Test 2: ASCII box chars in non-UTF-8 terminal
# =============================================================================

output=$( LANG=C LC_ALL=C _print_box_frame "test line" 2>&1 ) || true

assert_contains "2.1 ASCII top-left corner"      "+"  "$output"
assert_contains "2.2 ASCII horizontal rule"      "-"  "$output"
assert_contains "2.3 ASCII vertical bar"         "|"  "$output"
assert_not_contains "2.4 no Unicode top-left"    "╔"  "$output"
assert_not_contains "2.5 no Unicode horizontal"  "═"  "$output"
assert_not_contains "2.6 no Unicode vertical"    "║"  "$output"
echo "✓ Test 2: ASCII box chars in non-UTF-8 terminal"

# =============================================================================
# Test 3: Unicode box chars in UTF-8 terminal
# =============================================================================

output=$( LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 _print_box_frame "test line" 2>&1 ) || true

assert_contains "3.1 Unicode top-left corner"     "╔"  "$output"
assert_contains "3.2 Unicode horizontal rule"     "═"  "$output"
assert_contains "3.3 Unicode vertical bar"        "║"  "$output"
assert_not_contains "3.4 no ASCII top-left"       "+"  "$output"
echo "✓ Test 3: Unicode box chars in UTF-8 terminal"

# =============================================================================
# Test 4: Each positional arg appears as content in the box
# =============================================================================

output=$( LANG=C LC_ALL=C _print_box_frame "first line" "second line" "third line" 2>&1 ) || true

assert_contains "4.1 first line present"   "first line"   "$output"
assert_contains "4.2 second line present"  "second line"  "$output"
assert_contains "4.3 third line present"   "third line"   "$output"
echo "✓ Test 4: All content lines rendered"

# =============================================================================
# Test 5: Empty-string arg produces a blank separator line (no crash)
# =============================================================================

output=$( LANG=C LC_ALL=C _print_box_frame "before" "" "after" 2>&1 ) || true

assert_contains "5.1 before separator" "before" "$output"
assert_contains "5.2 after separator"  "after"  "$output"

# The output should have at least 5 lines: blank, top border, before, blank sep, after, bottom border, blank
line_count=$(echo "$output" | wc -l | tr -d '[:space:]')
if [ "$line_count" -lt 5 ]; then
    echo "FAIL: 5.3 expected at least 5 lines, got $line_count"
    FAIL=1
else
    echo "✓ Test 5.3: Blank separator produces sufficient output lines ($line_count)"
fi
echo "✓ Test 5: Empty-string arg handled without crash"

# =============================================================================
# Test 6: report_retry() uses "--" in non-UTF-8 terminal (not em-dash)
# =============================================================================

output=$( LANG=C LC_ALL=C report_retry 1 3 "api_500" 30 2>&1 ) || true

assert_contains "6.1 double-dash present in non-UTF-8"  "--"  "$output"
assert_not_contains "6.2 em-dash absent in non-UTF-8"   "—"   "$output"
echo "✓ Test 6: report_retry uses double-dash in non-UTF-8 terminal"

# =============================================================================
# Test 7: report_retry() uses "—" em-dash in UTF-8 terminal
# =============================================================================

output=$( LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 report_retry 2 5 "api_rate_limit" 60 2>&1 ) || true

assert_contains "7.1 em-dash present in UTF-8"           "—"   "$output"
echo "✓ Test 7: report_retry uses em-dash in UTF-8 terminal"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

echo "PASS"
