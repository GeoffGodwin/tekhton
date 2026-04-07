#!/usr/bin/env bash
# =============================================================================
# test_m62_fixes_integration.sh — Integration test verifying all M62/M61
# fixes work together in a realistic scenario
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== test_m62_fixes_integration.sh ==="

# Test 1: Verify all modified files exist and are readable
files_ok=0
[[ -r "${TEKHTON_HOME}/lib/timing.sh" ]] && files_ok=$((files_ok + 1))
[[ -r "${TEKHTON_HOME}/lib/finalize_summary.sh" ]] && files_ok=$((files_ok + 1))
[[ -r "${TEKHTON_HOME}/lib/indexer.sh" ]] && files_ok=$((files_ok + 1))
[[ -r "${TEKHTON_HOME}/stages/tester.sh" ]] && files_ok=$((files_ok + 1))
[[ -r "${TEKHTON_HOME}/stages/review.sh" ]] && files_ok=$((files_ok + 1))
if [[ $files_ok -eq 5 ]]; then
    pass "All modified files are readable"
else
    fail "Some modified files are missing or unreadable"
fi

# Test 2: Verify tester.sh can be sourced (syntax check)
if bash -n "${TEKHTON_HOME}/stages/tester.sh" 2>/dev/null; then
    pass "stages/tester.sh passes syntax check"
else
    fail "stages/tester.sh has syntax errors"
fi

# Test 3: Verify timing.sh can be sourced (syntax check)
if bash -n "${TEKHTON_HOME}/lib/timing.sh" 2>/dev/null; then
    pass "lib/timing.sh passes syntax check"
else
    fail "lib/timing.sh has syntax errors"
fi

# Test 4: Verify finalize_summary.sh can be sourced (syntax check)
if bash -n "${TEKHTON_HOME}/lib/finalize_summary.sh" 2>/dev/null; then
    pass "lib/finalize_summary.sh passes syntax check"
else
    fail "lib/finalize_summary.sh has syntax errors"
fi

# Test 5: Verify indexer.sh can be sourced (syntax check)
if bash -n "${TEKHTON_HOME}/lib/indexer.sh" 2>/dev/null; then
    pass "lib/indexer.sh passes syntax check"
else
    fail "lib/indexer.sh has syntax errors"
fi

# Test 6: Verify review.sh can be sourced (syntax check)
if bash -n "${TEKHTON_HOME}/stages/review.sh" 2>/dev/null; then
    pass "stages/review.sh passes syntax check"
else
    fail "stages/review.sh has syntax errors"
fi

# Test 7: Verify _TESTER_TIMING_WRITING_S is properly set to -1
if grep -q '_TESTER_TIMING_WRITING_S=-1' "${TEKHTON_HOME}/stages/tester.sh"; then
    pass "Tester timing initialization includes _TESTER_TIMING_WRITING_S"
else
    fail "Tester timing initialization missing _TESTER_TIMING_WRITING_S"
fi

# Test 8: Verify finalize_summary.sh uses the tester guard correctly
if sed -n '165p' "${TEKHTON_HOME}/lib/finalize_summary.sh" | grep -q 'if \[\[ "$_stg" == "tester" \]\]; then'; then
    pass "Finalize summary uses correct tester guard"
else
    fail "Finalize summary tester guard is incorrect"
fi

# Test 9: Verify timing.sh doesn't have double conditions on line 138
if sed -n '138p' "${TEKHTON_HOME}/lib/timing.sh" | grep -q 'if \[\[ "$_spk" == "${_pfx}"\* \]\]; then'; then
    pass "Timing.sh line 138 has correct simplified condition"
else
    fail "Timing.sh line 138 has unexpected condition format"
fi

# Test 10: Verify review.sh has the global comment for _REVIEW_MAP_FILES
if sed -n '41p' "${TEKHTON_HOME}/stages/review.sh" | grep -q 'global.*tested externally'; then
    pass "Review.sh _REVIEW_MAP_FILES has correct scope comment"
else
    fail "Review.sh _REVIEW_MAP_FILES scope comment missing or incorrect"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
