#!/usr/bin/env bash
# =============================================================================
# test_milestone_shorthand_parsing.sh — Unit tests for milestone shorthand regex
#
# Tests the regex in tekhton.sh:1754-1755 that parses shorthand milestone
# notation (e.g., "M66", "M3.1", "M3: title") in task strings.
#
# Cases covered:
# - M3: (colon suffix)
# - M3.1 title (decimal with space)
# - M3 (no suffix)
# - m3 (lowercase)
# - m3.1: description (lowercase decimal with colon)
# - Milestone 3: (original long format — should still work)
# - M3abc (non-matching edge case)
# - M3.1.2 (multiple decimals)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Test infrastructure -------------------------------------------------------

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_match() {
    local desc="$1" pattern="$2" text="$3"
    if [[ "$text" =~ $pattern ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — pattern did not match"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_match() {
    local desc="$1" pattern="$2" text="$3"
    if [[ ! "$text" =~ $pattern ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — pattern matched but should not"
        FAIL=$((FAIL + 1))
    fi
}

# --- Extract milestone from regex (same logic as tekhton.sh:1754-1756) -------

extract_milestone() {
    local task="$1"
    local milestone=""

    # Long format: "Milestone 3" or "Milestone 3.1"
    if [[ "$task" =~ [Mm]ilestone[[:space:]]+([0-9]+([.][0-9]+)*) ]]; then
        milestone="${BASH_REMATCH[1]}"
    # Shorthand format: "M3", "M3:", "M3.1 ...", "m3.1: ..."
    elif [[ "$task" =~ ^[Mm]([0-9]+([.][0-9]+)*)(:|[[:space:]]|$) ]]; then
        milestone="${BASH_REMATCH[1]}"
    fi

    echo "$milestone"
}

# --- Test cases ----------------------------------------------------------------

echo "Testing milestone shorthand parsing..."
echo

# Test 1: "M3:" format
TASK="M3: Implement feature X"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3: colon suffix extracts '3'" "3" "$RESULT"

# Test 2: "M3.1 title" format
TASK="M3.1 Advanced feature"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3.1 decimal with space extracts '3.1'" "3.1" "$RESULT"

# Test 3: "M3" format (no suffix)
TASK="M3"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3 with no suffix extracts '3'" "3" "$RESULT"

# Test 4: "M3 " format (space after, end-of-string variant)
TASK="M3 is the next milestone"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3 with space suffix extracts '3'" "3" "$RESULT"

# Test 5: lowercase "m66" format
TASK="m66: Bug fix"
RESULT=$(extract_milestone "$TASK")
assert_eq "m66 lowercase extracts '66'" "66" "$RESULT"

# Test 6: lowercase "m3.1: description"
TASK="m3.1: Advanced refactor"
RESULT=$(extract_milestone "$TASK")
assert_eq "m3.1 lowercase decimal extracts '3.1'" "3.1" "$RESULT"

# Test 7: "Milestone 3:" original long format still works
TASK="Milestone 3: The original format"
RESULT=$(extract_milestone "$TASK")
assert_eq "Milestone 3: long format extracts '3'" "3" "$RESULT"

# Test 8: "Milestone 3.1" long format with decimal
TASK="Milestone 3.1: Decimal in long format"
RESULT=$(extract_milestone "$TASK")
assert_eq "Milestone 3.1: long format extracts '3.1'" "3.1" "$RESULT"

# Test 9: "M3abc" should NOT match shorthand (non-matching edge case)
TASK="M3abc is not a valid milestone"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3abc non-matching case extracts empty" "" "$RESULT"

# Test 10: "M3x" should NOT match shorthand
TASK="M3x something"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3x non-matching case extracts empty" "" "$RESULT"

# Test 11: Multiple decimals "M3.1.2"
TASK="M3.1.2 with multiple decimals"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3.1.2 multiple decimals extracts '3.1.2'" "3.1.2" "$RESULT"

# Test 12: Large number "M999"
TASK="M999: Final milestone"
RESULT=$(extract_milestone "$TASK")
assert_eq "M999 large number extracts '999'" "999" "$RESULT"

# Test 13: Large decimal "M99.99"
TASK="M99.99 extreme decimal"
RESULT=$(extract_milestone "$TASK")
assert_eq "M99.99 large decimal extracts '99.99'" "99.99" "$RESULT"

# Test 14: "milestone" lowercase long format
TASK="milestone 5: lowercase variant"
RESULT=$(extract_milestone "$TASK")
assert_eq "milestone 5 lowercase long format extracts '5'" "5" "$RESULT"

# Test 15: "M5 " at end (boundary: space at EOL)
TASK="M5 "
RESULT=$(extract_milestone "$TASK")
assert_eq "M5 with trailing space extracts '5'" "5" "$RESULT"

# Test 16: No milestone in task
TASK="Fix the bug in component X"
RESULT=$(extract_milestone "$TASK")
assert_eq "No milestone extracts empty" "" "$RESULT"

# Test 17: "M" alone should NOT match
TASK="M: something"
RESULT=$(extract_milestone "$TASK")
assert_eq "M: alone should not match" "" "$RESULT"

# Test 18: "M3.1.2.3" many decimals
TASK="M3.1.2.3 nested structure"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3.1.2.3 many decimals extracts '3.1.2.3'" "3.1.2.3" "$RESULT"

# Test 19: Milestone in middle of task (should not match shorthand due to ^)
TASK="Do something with M3 milestone"
RESULT=$(extract_milestone "$TASK")
assert_eq "M3 in middle of text (not at start) extracts empty" "" "$RESULT"

# Test 20: "Milestone" in middle should still work (no ^ anchor)
TASK="Work on Milestone 5 improvements"
RESULT=$(extract_milestone "$TASK")
assert_eq "Milestone 5 in middle of text extracts '5'" "5" "$RESULT"

# Test 21: Tab character between M and number (should NOT match)
TASK="M	5: something"
RESULT=$(extract_milestone "$TASK")
assert_eq "M<TAB>5 should not match shorthand" "" "$RESULT"

# Test 22: "M0" edge case
TASK="M0: baseline"
RESULT=$(extract_milestone "$TASK")
assert_eq "M0 with zero extracts '0'" "0" "$RESULT"

# Test 23: Decimal at start "M.5" should NOT match
TASK="M.5: bad format"
RESULT=$(extract_milestone "$TASK")
assert_eq "M.5 decimal at start should not match" "" "$RESULT"

# Test 24: Trailing decimal "M5." should NOT match
TASK="M5. bad decimal"
RESULT=$(extract_milestone "$TASK")
assert_eq "M5. trailing decimal should not match" "" "$RESULT"

# Test 25: Consecutive decimals "M5..1" should NOT match
TASK="M5..1 double decimal"
RESULT=$(extract_milestone "$TASK")
assert_eq "M5..1 consecutive decimals should not match" "" "$RESULT"

# --- Summary ---

echo
echo "========================================="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
