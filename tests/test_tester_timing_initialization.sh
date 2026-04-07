#!/usr/bin/env bash
# =============================================================================
# test_tester_timing_initialization.sh — Verify _TESTER_TIMING_WRITING_S=-1
# is initialized in stages/tester.sh
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TESTER_STAGE="${TEKHTON_HOME}/stages/tester.sh"

echo "=== test_tester_timing_initialization.sh ==="

# Test 1: Verify _TESTER_TIMING_WRITING_S is initialized
if grep -q '_TESTER_TIMING_WRITING_S=-1' "$TESTER_STAGE"; then
    pass "_TESTER_TIMING_WRITING_S=-1 is initialized"
else
    fail "_TESTER_TIMING_WRITING_S=-1 not found in tester.sh"
fi

# Test 2: Verify it's initialized on line 16 (with other timing globals)
if sed -n '16p' "$TESTER_STAGE" | grep -q '_TESTER_TIMING_WRITING_S=-1'; then
    pass "_TESTER_TIMING_WRITING_S is on line 16 with other globals"
else
    fail "_TESTER_TIMING_WRITING_S not on expected line 16"
fi

# Test 3: Verify all four timing globals are initialized together
globals_found=0
[[ $(sed -n '13,16p' "$TESTER_STAGE" | grep -c "_TESTER_TIMING_EXEC_COUNT=-1") -gt 0 ]] && globals_found=$((globals_found + 1))
[[ $(sed -n '13,16p' "$TESTER_STAGE" | grep -c "_TESTER_TIMING_EXEC_APPROX_S=-1") -gt 0 ]] && globals_found=$((globals_found + 1))
[[ $(sed -n '13,16p' "$TESTER_STAGE" | grep -c "_TESTER_TIMING_FILES_WRITTEN=-1") -gt 0 ]] && globals_found=$((globals_found + 1))
[[ $(sed -n '13,16p' "$TESTER_STAGE" | grep -c "_TESTER_TIMING_WRITING_S=-1") -gt 0 ]] && globals_found=$((globals_found + 1))
if [[ $globals_found -eq 4 ]]; then
    pass "All four timing globals initialized together (lines 13-16)"
else
    fail "Not all four timing globals found (found $globals_found of 4)"
fi

# Test 4: Verify comment block identifies these as M62
if sed -n '11,16p' "$TESTER_STAGE" | grep -q "M62"; then
    pass "Comment block identifies these as M62 changes"
else
    fail "M62 identification missing from timing globals comment"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
