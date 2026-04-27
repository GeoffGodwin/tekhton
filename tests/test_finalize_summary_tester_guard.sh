#!/usr/bin/env bash
# =============================================================================
# test_finalize_summary_tester_guard.sh — Verify simplified tester guard
# condition in lib/finalize_summary.sh. Uses grep -n to locate the guard
# rather than hard-coded line numbers (M132 enrichment shifted offsets).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

FINALIZE_FILE="${TEKHTON_HOME}/lib/finalize_summary.sh"

echo "=== test_finalize_summary_tester_guard.sh ==="

# Locate the guard line dynamically (the simplified single-condition tester guard)
guard_line=$(grep -n 'if \[\[ "$_stg" == "tester" \]\]; then' "$FINALIZE_FILE" | head -1 | cut -d: -f1)

# Test 1: Verify the simplified guard exists in the file
if [[ -n "$guard_line" ]]; then
    pass "Simplified tester guard found at line ${guard_line}"
else
    fail "Simplified tester guard not found in finalize_summary.sh"
fi

# Test 2: Verify _stg_extra is initialized one line before the guard
if [[ -n "$guard_line" ]]; then
    init_line=$((guard_line - 1))
    if sed -n "${init_line}p" "$FINALIZE_FILE" | grep -q '_stg_extra=""'; then
        pass "_stg_extra is initialized before guard"
    else
        fail "_stg_extra initialization missing"
    fi
fi

# Test 3: Verify the guard body sets _stg_extra with test_execution_count
if [[ -n "$guard_line" ]]; then
    body_line=$((guard_line + 1))
    if sed -n "${body_line}p" "$FINALIZE_FILE" | grep -q 'test_execution_count'; then
        pass "Guard sets test_execution_count field for tester"
    else
        fail "Guard does not set test_execution_count"
    fi
fi

# Test 4: Verify all three tester timing fields are included in the guard body
if [[ -n "$guard_line" ]]; then
    body_line=$((guard_line + 1))
    body=$(sed -n "${body_line}p" "$FINALIZE_FILE")
    fields_present=0
    [[ "$body" == *test_execution_count* ]]    && fields_present=$((fields_present + 1))
    [[ "$body" == *test_execution_approx_s* ]] && fields_present=$((fields_present + 1))
    [[ "$body" == *test_writing_approx_s* ]]   && fields_present=$((fields_present + 1))
    if [[ $fields_present -eq 3 ]]; then
        pass "All three tester timing fields are included"
    else
        fail "Not all tester timing fields present (found $fields_present of 3)"
    fi
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
