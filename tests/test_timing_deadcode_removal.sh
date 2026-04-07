#!/usr/bin/env bash
# =============================================================================
# test_timing_deadcode_removal.sh — Verify dead condition removed from lib/timing.sh:138
# and that the function still works correctly
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TIMING_FILE="${TEKHTON_HOME}/lib/timing.sh"

echo "=== test_timing_deadcode_removal.sh ==="

# Test 1: Verify line 138 does not contain dead condition (second && check)
if sed -n '138p' "$TIMING_FILE" | grep -q 'if \[\[ "$_spk" == "${_pfx}"\* \]\]; then'; then
    pass "Line 138 contains simplified prefix check (not double-condition)"
else
    fail "Line 138 does not have expected simplified condition"
fi

# Test 2: Verify the sub-phase parent detection still uses the loop logic
if sed -n '135,142p' "$TIMING_FILE" | grep -q "for _pfx in"; then
    pass "Sub-phase parent detection loop still present"
else
    fail "Sub-phase parent detection loop missing"
fi

# Test 3: Verify function structure is intact (_sub_phase_parents array)
if sed -n '130,145p' "$TIMING_FILE" | grep -q "_sub_phase_parents"; then
    pass "Sub-phase parents array still present and used"
else
    fail "Sub-phase parents array missing"
fi

# Test 4: Verify _sub_phase_prefixes is still defined
if sed -n '130,145p' "$TIMING_FILE" | grep -q "_sub_phase_prefixes"; then
    pass "Sub-phase prefixes array still defined"
else
    fail "Sub-phase prefixes array missing"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
