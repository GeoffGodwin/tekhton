#!/usr/bin/env bash
# =============================================================================
# test_finalize_summary_tester_guard.sh — Verify simplified tester guard
# condition in lib/finalize_summary.sh:164
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

FINALIZE_FILE="${TEKHTON_HOME}/lib/finalize_summary.sh"

echo "=== test_finalize_summary_tester_guard.sh ==="

# Test 1: Verify guard at line 165 is simplified to single condition
if sed -n '165p' "$FINALIZE_FILE" | grep -q 'if \[\[ "$_stg" == "tester" \]\]; then'; then
    pass "Guard at line 165 is simplified single condition for tester"
else
    fail "Guard at line 165 is not the expected simplified condition"
fi

# Test 2: Verify _stg_extra is initialized before the guard
if sed -n '164,166p' "$FINALIZE_FILE" | grep -q '_stg_extra=""'; then
    pass "_stg_extra is initialized before guard"
else
    fail "_stg_extra initialization missing"
fi

# Test 3: Verify the guard properly sets _stg_extra with tester timing fields
if sed -n '165,167p' "$FINALIZE_FILE" | grep -q 'test_execution_count'; then
    pass "Guard sets test_execution_count field for tester"
else
    fail "Guard does not set test_execution_count"
fi

# Test 4: Verify all three tester timing fields are included
fields_present=0
[[ $(sed -n '165,167p' "$FINALIZE_FILE" | grep -c "test_execution_count") -gt 0 ]] && fields_present=$((fields_present + 1))
[[ $(sed -n '165,167p' "$FINALIZE_FILE" | grep -c "test_execution_approx_s") -gt 0 ]] && fields_present=$((fields_present + 1))
[[ $(sed -n '165,167p' "$FINALIZE_FILE" | grep -c "test_writing_approx_s") -gt 0 ]] && fields_present=$((fields_present + 1))
if [[ $fields_present -eq 3 ]]; then
    pass "All three tester timing fields are included"
else
    fail "Not all tester timing fields present (found $fields_present of 3)"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
