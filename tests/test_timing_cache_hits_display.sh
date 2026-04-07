#!/usr/bin/env bash
# =============================================================================
# test_timing_cache_hits_display.sh — Verify cache hits display message
# is grammatically correct
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TIMING_FILE="${TEKHTON_HOME}/lib/timing.sh"

echo "=== test_timing_cache_hits_display.sh ==="

# Test 1: Verify correct message when hits=0
if sed -n '240p' "$TIMING_FILE" | grep -q 'Repo map: 1 generation (saved ~0s)'; then
    pass "Line 240 has correct message when hits=0"
else
    fail "Line 240 does not have expected message format"
fi

# Test 2: Verify correct plural message when hits>0
if sed -n '238p' "$TIMING_FILE" | grep -q 'cache hits (saved'; then
    pass "Line 238 uses 'cache hits' (plural)"
else
    fail "Line 238 does not have correct plural form"
fi

# Test 3: Verify grammar in generation+hits message
if sed -n '238p' "$TIMING_FILE" | grep -q '1 generation +'; then
    pass "Line 238 uses correct conjunction ('+') between generation and hits"
else
    fail "Line 238 does not have correct format for multiple components"
fi

# Test 4: Verify both messages preserve the timestamp format
if sed -n '238,240p' "$TIMING_FILE" | grep -q 'saved ~'; then
    pass "Both messages include '(saved ~' format"
else
    fail "Messages do not follow expected timestamp format"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
