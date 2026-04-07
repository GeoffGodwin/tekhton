#!/usr/bin/env bash
# =============================================================================
# test_review_map_files_global.sh — Verify _REVIEW_MAP_FILES scope comment
# exists and function still works
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

REVIEW_STAGE="${TEKHTON_HOME}/stages/review.sh"

echo "=== test_review_map_files_global.sh ==="

# Test 1: Verify _REVIEW_MAP_FILES is declared as global
if grep -q '_REVIEW_MAP_FILES=""' "$REVIEW_STAGE"; then
    pass "_REVIEW_MAP_FILES is declared and initialized"
else
    fail "_REVIEW_MAP_FILES declaration missing"
fi

# Test 2: Verify comment at line 41 mentions "global"
if sed -n '41p' "$REVIEW_STAGE" | grep -q "global"; then
    pass "Line 41 comment identifies variable as global"
else
    fail "Line 41 comment does not mention 'global'"
fi

# Test 3: Verify comment mentions "tested externally"
if sed -n '41p' "$REVIEW_STAGE" | grep -q "tested externally"; then
    pass "Comment notes variable is tested externally"
else
    fail "Comment does not mention 'tested externally'"
fi

# Test 4: Verify _REVIEW_MAP_FILES is used in cache comparison logic
if grep -q '_old_basenames=$(echo "$_REVIEW_MAP_FILES"' "$REVIEW_STAGE"; then
    pass "_REVIEW_MAP_FILES is used in cache comparison logic"
else
    fail "_REVIEW_MAP_FILES is not used in cache comparison"
fi

# Test 5: Verify _REVIEW_MAP_FILES is assigned in review cycle
if grep -q '_REVIEW_MAP_FILES="$_review_files"' "$REVIEW_STAGE"; then
    pass "_REVIEW_MAP_FILES is assigned during review cycle"
else
    fail "_REVIEW_MAP_FILES assignment missing"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
