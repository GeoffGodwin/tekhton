#!/usr/bin/env bash
# =============================================================================
# test_metrics_calibration_overshoot.sh — Verify overshoots are included in calibration
#
# BUG FIX VERIFICATION:
# The metrics calibration used to skip ALL records where actual >= adjusted * 0.85,
# which incorrectly excluded overshoots (actual > adjusted). Overshoots are the
# most important signals — they teach calibration to raise limits when the agent
# needs more turns than allocated.
#
# The fix adds `[[ "$actual" -le "$adjusted" ]] &&` to the skip condition.
# This ensures only true cap-hits (agent hit the ceiling) are skipped, while
# overshoots (agent exceeded the ceiling) are included in calibration.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/metrics.sh"
source "${TEKHTON_HOME}/lib/metrics_calibration.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# TEST 1: Overshoots (actual > adjusted) ARE INCLUDED in calibration
# =============================================================================
echo "=== Test Suite 1: Overshoots are included in calibration ==="

METRICS_FILE="$TMPDIR/test1_metrics.jsonl"
printf '{"scout_est_reviewer":10,"reviewer_turns":12,"adjusted_reviewer":10}\n' > "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":15,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":15,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":15,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":15,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"

_METRICS_FILE="$METRICS_FILE"
export METRICS_ADAPTIVE_TURNS=true
export METRICS_MIN_RUNS=5

# All 5 records are overshoots (actual > adjusted)
# est_sum = 10 + 10 + 10 + 10 + 10 = 50
# actual_sum = 12 + 15 + 15 + 15 + 15 = 72
# multiplier = 72 * 100 / 50 = 144 (clamped [50, 200])
# adjusted = (10 * 144 + 50) / 100 = 14

result=$(calibrate_turn_estimate 10 reviewer)
if [ "$result" = "14" ]; then
    pass "Test 1.1: Overshoots included — multiplier 144 applies to base 10 → 14"
else
    fail "Test 1.1: Expected 14, got '$result' (overshoots should teach calibration to raise limits)"
fi

# =============================================================================
# TEST 2: Cap-hits (actual <= adjusted && usage >= 85%) ARE EXCLUDED
# =============================================================================
echo
echo "=== Test Suite 2: Cap-hits are excluded from calibration ==="

METRICS_FILE="$TMPDIR/test2_metrics.jsonl"
# All records have < 85% usage, so none are cap-hits
printf '{"scout_est_reviewer":10,"reviewer_turns":8,"adjusted_reviewer":10}\n' > "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":8,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":8,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":8,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":8,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"

_METRICS_FILE="$METRICS_FILE"

# All records: actual=8, adjusted=10 → 80% usage (below 85%, all included)
# est_sum = 50, actual_sum = 40
# multiplier = 40 * 100 / 50 = 80
# adjusted = (10 * 80 + 50) / 100 = 8

result=$(calibrate_turn_estimate 10 reviewer)
if [ "$result" = "8" ]; then
    pass "Test 2.1: 80% usage (below 85%) included — multiplier 80 → 8"
else
    fail "Test 2.1: Expected 8, got '$result'"
fi

# =============================================================================
# TEST 3: Mixed records exclude cap-hits but include overshoots
# =============================================================================
echo
echo "=== Test Suite 3: Selective exclusion of cap-hits vs overshoots ==="

METRICS_FILE="$TMPDIR/test3_metrics.jsonl"
# Record 1-2: 80% usage (include)
# Record 3-4: 90% usage (cap-hit, exclude)
# Record 5: 150% usage (overshoot, include)
printf '{"scout_est_reviewer":10,"reviewer_turns":8,"adjusted_reviewer":10}\n' > "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":8,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":9,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":9,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":15,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"

_METRICS_FILE="$METRICS_FILE"

# Included: records 1, 2 (actual=8,8), 5 (actual=15)
# est_sum = 10 + 10 + 10 = 30, actual_sum = 8 + 8 + 15 = 31
# multiplier = 31 * 100 / 30 = 103
# adjusted = (10 * 103 + 50) / 100 = 10

result=$(calibrate_turn_estimate 10 reviewer)
if [ "$result" = "10" ]; then
    pass "Test 3.1: Mixed records (2 includes + 2 excludes + 1 overshoot) → multiplier 103 → 10"
else
    fail "Test 3.1: Expected 10, got '$result'"
fi

# =============================================================================
# TEST 4: Overshoot at very high level (actual > 1.5x adjusted)
# =============================================================================
echo
echo "=== Test Suite 4: Extreme overshoots are clamped to 2.0x multiplier ==="

METRICS_FILE="$TMPDIR/test4_metrics.jsonl"
# All records: est=10, actual=30, adjusted=10 (overshoot by 3x)
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' > "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"

_METRICS_FILE="$METRICS_FILE"

# multiplier = 150 * 100 / 50 = 300, clamped to 200 (2.0x)
# adjusted = (10 * 200 + 50) / 100 = 20

result=$(calibrate_turn_estimate 10 reviewer)
if [ "$result" = "20" ]; then
    pass "Test 4.1: Overshoot at 3x clamped to 2.0x multiplier → 20"
else
    fail "Test 4.1: Expected 20, got '$result'"
fi

# =============================================================================
# TEST 5: Insufficient data returns original estimate
# =============================================================================
echo
echo "=== Test Suite 5: Insufficient data returns original recommendation ==="

METRICS_FILE="$TMPDIR/test5_metrics.jsonl"
# Only 2 records (below METRICS_MIN_RUNS=5)
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' > "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"

_METRICS_FILE="$METRICS_FILE"

result=$(calibrate_turn_estimate 25 reviewer)
if [ "$result" = "25" ]; then
    pass "Test 5.1: Insufficient records (2 < 5) returns original estimate 25"
else
    fail "Test 5.1: Expected 25, got '$result'"
fi

# =============================================================================
# TEST 6: Adaptive calibration disabled
# =============================================================================
echo
echo "=== Test Suite 6: Disabled adaptive calibration returns original ==="

METRICS_FILE="$TMPDIR/test6_metrics.jsonl"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' > "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"
printf '{"scout_est_reviewer":10,"reviewer_turns":30,"adjusted_reviewer":10}\n' >> "$METRICS_FILE"

_METRICS_FILE="$METRICS_FILE"
export METRICS_ADAPTIVE_TURNS=false

result=$(calibrate_turn_estimate 10 reviewer)
if [ "$result" = "10" ]; then
    pass "Test 6.1: METRICS_ADAPTIVE_TURNS=false returns original estimate 10"
else
    fail "Test 6.1: Expected 10, got '$result'"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  Metrics Calibration Overshoot Tests"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
