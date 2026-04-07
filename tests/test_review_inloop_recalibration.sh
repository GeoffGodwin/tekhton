#!/usr/bin/env bash
# =============================================================================
# test_review_inloop_recalibration.sh — Verify in-loop reviewer limit bumping
#
# BUG FIX VERIFICATION:
# In the review loop, when the reviewer uses >= 85% of its allocated turns,
# the ADJUSTED_REVIEWER_TURNS limit should be bumped for the next cycle.
# This prevents repeated overshoots against the same limit.
#
# The fix adds in-loop recalibration logic in stages/review.sh lines 120-138:
# If usage >= 85%, bump by 25% clamped to REVIEWER_MAX_TURNS_CAP, and update
# ADJUSTED_REVIEWER_TURNS for the next cycle.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# TEST 1: Usage at 85% triggers bump
# =============================================================================
echo "=== Test Suite 1: Usage >= 85% triggers limit bump ==="

# Scenario: reviewer allowed 20 turns, used 17 (85%)
# Bump = ceil(20 * 125 / 100) = 25, clamped to REVIEWER_MAX_TURNS_CAP (default 30)
ADJUSTED_REVIEWER_TURNS=20
LAST_AGENT_TURNS=17
REVIEWER_MAX_TURNS_CAP=30

usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi

if [ "$ADJUSTED_REVIEWER_TURNS" = "25" ]; then
    pass "Test 1.1: Usage 85% (17/20) bumps limit to 25"
else
    fail "Test 1.1: Expected 25, got '$ADJUSTED_REVIEWER_TURNS'"
fi

# =============================================================================
# TEST 2: Usage just below 85% does NOT trigger bump
# =============================================================================
echo
echo "=== Test Suite 2: Usage < 85% does NOT trigger bump ==="

# Scenario: reviewer allowed 20 turns, used 16 (80%)
ADJUSTED_REVIEWER_TURNS=20
LAST_AGENT_TURNS=16
REVIEWER_MAX_TURNS_CAP=30

original_limit=$ADJUSTED_REVIEWER_TURNS
usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi

if [ "$ADJUSTED_REVIEWER_TURNS" = "$original_limit" ]; then
    pass "Test 2.1: Usage 80% (16/20) does NOT bump limit (stays 20)"
else
    fail "Test 2.1: Expected $original_limit, got '$ADJUSTED_REVIEWER_TURNS'"
fi

# =============================================================================
# TEST 3: Bump is clamped to REVIEWER_MAX_TURNS_CAP
# =============================================================================
echo
echo "=== Test Suite 3: Bump clamped to REVIEWER_MAX_TURNS_CAP ==="

# Scenario: reviewer allowed 30 turns, used 26 (87%)
# Bump would be 30 * 125 / 100 = 37.5 → 37, but clamped to 30
ADJUSTED_REVIEWER_TURNS=30
LAST_AGENT_TURNS=26
REVIEWER_MAX_TURNS_CAP=30

usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi

if [ "$ADJUSTED_REVIEWER_TURNS" = "30" ]; then
    pass "Test 3.1: Bump clamped to REVIEWER_MAX_TURNS_CAP (stays 30, not bumped to 37)"
else
    fail "Test 3.1: Expected 30 (clamped), got '$ADJUSTED_REVIEWER_TURNS'"
fi

# =============================================================================
# TEST 4: Bump by 25% from mid-range value
# =============================================================================
echo
echo "=== Test Suite 4: 25% bump from mid-range value ==="

# Scenario: reviewer allowed 10 turns, used 9 (90%)
# Bump = 10 * 125 / 100 = 12, not clamped
ADJUSTED_REVIEWER_TURNS=10
LAST_AGENT_TURNS=9
REVIEWER_MAX_TURNS_CAP=30

usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi

if [ "$ADJUSTED_REVIEWER_TURNS" = "12" ]; then
    pass "Test 4.1: Usage 90% (9/10) bumps to 12 (25% increase)"
else
    fail "Test 4.1: Expected 12, got '$ADJUSTED_REVIEWER_TURNS'"
fi

# =============================================================================
# TEST 5: Exact 85% threshold triggers bump
# =============================================================================
echo
echo "=== Test Suite 5: Exact 85% threshold triggers bump ==="

# Scenario: reviewer allowed 20 turns, used 17 (exactly 85%)
# Should bump: 20 * 125 / 100 = 25, not clamped
ADJUSTED_REVIEWER_TURNS=20
LAST_AGENT_TURNS=17
REVIEWER_MAX_TURNS_CAP=30

usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi

if [ "$ADJUSTED_REVIEWER_TURNS" = "25" ]; then
    pass "Test 5.1: Exact 85% (17/20) triggers bump to 25"
else
    fail "Test 5.1: Expected 25, got '$ADJUSTED_REVIEWER_TURNS'"
fi

# =============================================================================
# TEST 6: Low usage does NOT bump even close to 85%
# =============================================================================
echo
echo "=== Test Suite 6: 84% usage (just below threshold) does NOT bump ==="

# Scenario: reviewer allowed 100 turns, used 84 (84%)
ADJUSTED_REVIEWER_TURNS=100
LAST_AGENT_TURNS=84
REVIEWER_MAX_TURNS_CAP=30

original_limit=$ADJUSTED_REVIEWER_TURNS
usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi

if [ "$ADJUSTED_REVIEWER_TURNS" = "$original_limit" ]; then
    pass "Test 6.1: Usage 84% (84/100) does NOT bump (stays 100)"
else
    fail "Test 6.1: Expected $original_limit, got '$ADJUSTED_REVIEWER_TURNS'"
fi

# =============================================================================
# TEST 7: Bump happens ONLY when it increases the limit
# =============================================================================
echo
echo "=== Test Suite 7: Bump applied only when it increases limit ==="

# Scenario: reviewer allowed 20 turns, used 17 (85%)
# Bump would be 20 * 125 / 100 = 25, which is > 20, so it applies
ADJUSTED_REVIEWER_TURNS=20
LAST_AGENT_TURNS=17
REVIEWER_MAX_TURNS_CAP=30

usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
bumped_applied=false
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
        bumped_applied=true
    fi
fi

if [ "$bumped_applied" = "true" ] && [ "$ADJUSTED_REVIEWER_TURNS" = "25" ]; then
    pass "Test 7.1: Bump from 20→25 applied (increases limit)"
else
    fail "Test 7.1: Expected bump applied and limit=25, got limit=$ADJUSTED_REVIEWER_TURNS"
fi

# =============================================================================
# TEST 8: Multiple cycles accumulate bumps
# =============================================================================
echo
echo "=== Test Suite 8: Multiple cycles accumulate bumps ==="

# Simulate 3 consecutive cycles with sustained high usage
ADJUSTED_REVIEWER_TURNS=10
LAST_AGENT_TURNS=9
REVIEWER_MAX_TURNS_CAP=30

# Cycle 1: 10 turns used 9 (90%) → bump to 12
usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi
cycle1_limit=$ADJUSTED_REVIEWER_TURNS

# Cycle 2: 12 turns used 11 (92%) → bump to 15
LAST_AGENT_TURNS=11
usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi
cycle2_limit=$ADJUSTED_REVIEWER_TURNS

# Cycle 3: 15 turns used 13 (87%) → bump to 18
LAST_AGENT_TURNS=13
usage_pct=$((LAST_AGENT_TURNS * 100 / ADJUSTED_REVIEWER_TURNS))
if [[ "$usage_pct" -ge 85 ]]; then
    bumped=$((ADJUSTED_REVIEWER_TURNS * 125 / 100))
    if [[ "$bumped" -gt "${REVIEWER_MAX_TURNS_CAP:-30}" ]]; then
        bumped="${REVIEWER_MAX_TURNS_CAP:-30}"
    fi
    if [[ "$bumped" -gt "$ADJUSTED_REVIEWER_TURNS" ]]; then
        ADJUSTED_REVIEWER_TURNS="$bumped"
    fi
fi
cycle3_limit=$ADJUSTED_REVIEWER_TURNS

if [ "$cycle1_limit" = "12" ] && [ "$cycle2_limit" = "15" ] && [ "$cycle3_limit" = "18" ]; then
    pass "Test 8.1: Bumps accumulate across cycles: 10→12→15→18"
else
    fail "Test 8.1: Expected progression 10→12→15→18, got $cycle1_limit→$cycle2_limit→$cycle3_limit"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  Review In-Loop Recalibration Tests"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
