#!/usr/bin/env bash
# =============================================================================
# test_metrics_total_time_computation.sh — Test total_time computation in metrics.sh
#
# Tests the new total_time computation path in record_run_metrics():
# - _STAGE_DURATION array sum takes precedence over TOTAL_TIME
# - Fallback to TOTAL_TIME when _STAGE_DURATION is empty
# - Proper handling of missing stage entries
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

LOG_DIR="$TEST_TMPDIR/logs"
PROJECT_DIR="$TEST_TMPDIR"
mkdir -p "$LOG_DIR"

# Stub logging
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Export required globals
export LOG_DIR PROJECT_DIR

# Source metrics.sh
# shellcheck source=../lib/metrics.sh
source "${TEKHTON_HOME}/lib/metrics.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics_extended.sh"

# Helper: extract total_time_s from metrics.jsonl
_read_total_time() {
    tail -1 "$LOG_DIR/metrics.jsonl" 2>/dev/null | \
        sed -n 's/.*"total_time_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
}

echo "=== Test Suite: total_time computation in record_run_metrics() ==="

# Test 1: _STAGE_DURATION array sum takes precedence
echo "Test 1: _STAGE_DURATION array sum takes precedence"
declare -A _STAGE_DURATION=([intake]=30 [scout]=45 [coder]=300 [build_gate]=0 [security]=0 [reviewer]=150 [tester]=180)
METRICS_ENABLED=true
TASK="Test task 1"
MILESTONE_MODE=false
TOTAL_TURNS=50
TOTAL_TIME=500  # This should be ignored
STAGE_SUMMARY=$'Coder: 30/50 turns, 5m\nReviewer: 15/20 turns, 2m30s\nTester: 5/10 turns, 3m'
VERDICT="APPROVED"
SCOUT_REC_CODER_TURNS=50
SCOUT_REC_REVIEWER_TURNS=20
SCOUT_REC_TESTER_TURNS=10

expected_total=$((30 + 45 + 300 + 0 + 0 + 150 + 180))  # 705 seconds
record_run_metrics
actual_total=$(_read_total_time)

if [[ "$actual_total" == "$expected_total" ]]; then
    pass "Stage duration sum (705s) used instead of TOTAL_TIME (500s)"
else
    fail "Expected total_time_s=$expected_total, got $actual_total"
fi

# Test 2: Fallback to TOTAL_TIME when _STAGE_DURATION is empty
echo "Test 2: Fallback to TOTAL_TIME when _STAGE_DURATION is empty"
rm -f "$LOG_DIR/metrics.jsonl"
declare -A _STAGE_DURATION=()  # Empty array
TASK="Test task 2"
TOTAL_TIME=450  # Should be used as fallback
record_run_metrics
actual_total=$(_read_total_time)

if [[ "$actual_total" == "450" ]]; then
    pass "Fallback to TOTAL_TIME (450s) when _STAGE_DURATION is empty"
else
    fail "Expected total_time_s=450, got $actual_total"
fi

# Test 3: Partial _STAGE_DURATION (some stages have values, some are zero)
echo "Test 3: Partial _STAGE_DURATION with zero entries"
rm -f "$LOG_DIR/metrics.jsonl"
declare -A _STAGE_DURATION=([coder]=250 [reviewer]=120 [tester]=0 [scout]=0)
# intake, build_gate, security are unset (will be treated as 0)
TASK="Test task 3"
TOTAL_TIME=999  # Should be ignored
record_run_metrics
actual_total=$(_read_total_time)

# When an array key doesn't exist, ${_STAGE_DURATION[$key]:-0} returns 0
# So: coder=250 + reviewer=120 + (all others) = 370
expected_total=$((250 + 120))
if [[ "$actual_total" == "$expected_total" ]]; then
    pass "Partial stage durations sum to $expected_total (ignored TOTAL_TIME)"
else
    fail "Expected total_time_s=$expected_total, got $actual_total"
fi

# Test 4: All stages zero — should fall back to TOTAL_TIME
echo "Test 4: All stage durations zero, fall back to TOTAL_TIME"
rm -f "$LOG_DIR/metrics.jsonl"
declare -A _STAGE_DURATION=([intake]=0 [scout]=0 [coder]=0 [build_gate]=0 [security]=0 [reviewer]=0 [tester]=0)
TASK="Test task 4"
TOTAL_TIME=600
record_run_metrics
actual_total=$(_read_total_time)

if [[ "$actual_total" == "600" ]]; then
    pass "Fallback to TOTAL_TIME (600s) when all stage durations are zero"
else
    fail "Expected total_time_s=600, got $actual_total"
fi

# Test 5: Large values test — verify no integer overflow
echo "Test 5: Large stage duration values"
rm -f "$LOG_DIR/metrics.jsonl"
declare -A _STAGE_DURATION=([coder]=3600 [reviewer]=1800 [tester]=1200 [scout]=600)
TASK="Test task 5 with large durations"
TOTAL_TIME=0
record_run_metrics
actual_total=$(_read_total_time)

expected_total=$((3600 + 1800 + 1200 + 600))
if [[ "$actual_total" == "$expected_total" ]]; then
    pass "Large stage durations sum correctly to $expected_total"
else
    fail "Expected total_time_s=$expected_total, got $actual_total"
fi

# Test 6: JSON validity — ensure total_time_s is valid JSON number
echo "Test 6: total_time_s produces valid JSON"
rm -f "$LOG_DIR/metrics.jsonl"
declare -A _STAGE_DURATION=([coder]=100 [reviewer]=50)
TASK="Test task 6"
record_run_metrics
json=$(tail -1 "$LOG_DIR/metrics.jsonl" 2>/dev/null || echo "")

# Try to extract and verify it's a number
if echo "$json" | grep -q '"total_time_s":[0-9]*[,}]'; then
    pass "total_time_s in valid JSON format"
else
    fail "total_time_s not in valid JSON format: $json"
fi

echo ""
echo "=== Test Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

[[ $FAIL -eq 0 ]]
