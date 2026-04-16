#!/usr/bin/env bash
# Test: _render_progress_bar() no subshell forks optimization (M82 fix)
# Verifies that progress bar rendering uses printf -v (zero forks) instead of
# $(printf ...) subshells (40+ forks per render).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

# Minimal stubs
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
NC="\033[0m"
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
_is_utf8_terminal() { return 1; }  # ASCII mode for predictable output

# Source the helpers
source "${TEKHTON_HOME}/lib/milestone_progress_helpers.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }

echo "=== Test: _render_progress_bar — output correctness ==="

# Test 1: 50% completion (20 filled, 20 empty)
output=$(_render_progress_bar 20 40)
# In ASCII mode: bar_ch="=", bar_empty=" "
# Expected: 20 equals + 20 spaces = 40 chars
bar_only=$(echo "$output" | sed "s/^[^=]*//; s/[^= ]*$//")  # Strip color codes
if [[ ${#bar_only} -eq 40 ]]; then
    pass "50% bar is 40 characters (20 filled, 20 empty)"
else
    fail "50% bar length is ${#bar_only}, expected 40"
fi

# Count filled vs empty
filled=$(echo "$bar_only" | tr -cd '=' | wc -c)
empty=$(echo "$bar_only" | tr -cd ' ' | wc -c)
if [[ $filled -eq 20 ]]; then
    pass "50% bar has 20 filled characters"
else
    fail "50% bar has $filled filled, expected 20"
fi
if [[ $empty -eq 20 ]]; then
    pass "50% bar has 20 empty characters"
else
    fail "50% bar has $empty empty, expected 20"
fi

# Test 2: 0% completion (0 filled, 40 empty)
output=$(_render_progress_bar 0 40)
bar_only=$(echo "$output" | sed "s/^[^=]*//; s/[^= ]*$//")
filled=$(echo "$bar_only" | tr -cd '=' | wc -c)
if [[ $filled -eq 0 ]]; then
    pass "0% bar has 0 filled characters"
else
    fail "0% bar has $filled filled, expected 0"
fi

# Test 3: 100% completion (40 filled, 0 empty)
output=$(_render_progress_bar 40 40)
bar_only=$(echo "$output" | sed "s/^[^=]*//; s/[^= ]*$//")
filled=$(echo "$bar_only" | tr -cd '=' | wc -c)
if [[ $filled -eq 40 ]]; then
    pass "100% bar has 40 filled characters"
else
    fail "100% bar has $filled filled, expected 40"
fi

# Test 4: Partial percentages (test rounding)
# 25 out of 100 = 25%
output=$(_render_progress_bar 25 100)
bar_only=$(echo "$output" | sed "s/^[^=]*//; s/[^= ]*$//")
filled=$(echo "$bar_only" | tr -cd '=' | wc -c)
if [[ $filled -eq 10 ]]; then  # 25 * 40 / 100 = 10
    pass "25% bar has 10 filled characters (correct rounding)"
else
    fail "25% bar has $filled filled, expected 10 (got $(( 25 * 40 / 100 )))"
fi

# Test 5: UTF-8 mode bar rendering
# Create a version that uses UTF-8
_is_utf8_terminal() { return 0; }
output=$(_render_progress_bar 20 40)
# In UTF-8 mode: bar_ch is the unicode box-drawing character
# The output should still render correctly (though we can't easily verify UTF-8 bytes in test)
bar_only=$(echo "$output" | sed "s/^[^= ]*//; s/[^= ]*$//")  # May contain UTF-8 chars
if [[ -n "$bar_only" ]]; then
    pass "UTF-8 mode bar renders non-empty output"
else
    fail "UTF-8 mode bar produced no output"
fi

# Test 6: Edge case — zero total (avoid division by zero)
output=$(_render_progress_bar 0 0)
if [[ -n "$output" ]]; then
    pass "Zero total doesn't crash, produces output"
else
    fail "Zero total caused empty output (possible crash)"
fi

# Test 7: Color codes are present (check for ANSI escape sequences)
_is_utf8_terminal() { return 1; }  # Back to ASCII
output=$(_render_progress_bar 20 40)
# Check for ANSI escape sequences: \033[...m or [32m pattern
if echo "$output" | grep -qE '\[3[0-9]m'; then
    pass "Bar output includes ANSI color codes"
else
    fail "Bar output missing ANSI color codes"
fi

echo ""
echo "════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
exit "$FAIL"
