#!/usr/bin/env bash
# =============================================================================
# test_m62_comment_accuracy.sh — Verify comment in test_m62_resume_cumulative_overcount.sh
# accurately describes delta-based contract
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_FILE="${TEKHTON_HOME}/tests/test_m62_resume_cumulative_overcount.sh"

echo "=== test_m62_comment_accuracy.sh ==="

# Test 1: Verify comment mentions "delta" at line 206-208
if grep -q "delta" "$TEST_FILE"; then
    pass "Comment mentions 'delta' keyword"
else
    fail "Comment does not mention 'delta' keyword"
fi

# Test 2: Verify comment at lines 206-208 mentions "delta-based contract"
if sed -n '206,208p' "$TEST_FILE" | grep -q "delta"; then
    pass "Comment at lines 206-208 describes delta-based behavior"
else
    fail "Comment at lines 206-208 does not describe delta"
fi

# Test 3: Verify comment mentions "accumulate" (the function being tested)
if sed -n '206,208p' "$TEST_FILE" | grep -q "accumulate"; then
    pass "Comment mentions 'accumulate' function"
else
    fail "Comment does not mention 'accumulate'"
fi

# Test 4: Verify comment mentions "continuation"
if sed -n '206,208p' "$TEST_FILE" | grep -q "continuation"; then
    pass "Comment mentions continuation context"
else
    fail "Comment does not mention continuation"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
