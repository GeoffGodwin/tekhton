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

TESTER_TIMING="${TEKHTON_HOME}/stages/tester_timing.sh"
TESTER_STAGE="${TEKHTON_HOME}/stages/tester.sh"

echo "=== test_tester_timing_initialization.sh ==="

# Test 1: Verify _TESTER_TIMING_WRITING_S is initialized (in tester_timing.sh after M65 extraction)
if grep -q '_TESTER_TIMING_WRITING_S=-1' "$TESTER_TIMING"; then
    pass "_TESTER_TIMING_WRITING_S=-1 is initialized"
else
    fail "_TESTER_TIMING_WRITING_S=-1 not found in tester_timing.sh"
fi

# Test 2: Verify all four timing globals are initialized together in tester_timing.sh
globals_found=0
grep -q "_TESTER_TIMING_EXEC_COUNT=-1" "$TESTER_TIMING" && globals_found=$((globals_found + 1))
grep -q "_TESTER_TIMING_EXEC_APPROX_S=-1" "$TESTER_TIMING" && globals_found=$((globals_found + 1))
grep -q "_TESTER_TIMING_FILES_WRITTEN=-1" "$TESTER_TIMING" && globals_found=$((globals_found + 1))
grep -q "_TESTER_TIMING_WRITING_S=-1" "$TESTER_TIMING" && globals_found=$((globals_found + 1))
if [[ $globals_found -eq 4 ]]; then
    pass "All four timing globals initialized together in tester_timing.sh"
else
    fail "Not all four timing globals found (found $globals_found of 4)"
fi

# Test 3: Verify comment block identifies these as M62
if grep -q "M62" "$TESTER_TIMING"; then
    pass "Comment block identifies these as M62 changes"
else
    fail "M62 identification missing from timing globals comment"
fi

# Test 4: Verify tester.sh sources tester_timing.sh
if grep -q 'source.*tester_timing.sh' "$TESTER_STAGE"; then
    pass "tester.sh sources tester_timing.sh"
else
    fail "tester.sh does not source tester_timing.sh"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
