#!/usr/bin/env bash
# =============================================================================
# test_duration_estimation_jsonl.sh — Test proportional duration estimation in _parse_run_summaries_from_jsonl
#
# Tests:
# - Proportional duration estimation when legacy metrics lack individual stage durations
# - Correct turn-based weighting: duration = (total_time * stage_turns) / total_turns
# - Both Python and shell fallback paths
# - Handling of edge cases (zero turns, missing stages, all stages with duration)
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

# Source dashboard_parsers.sh
# shellcheck source=../lib/dashboard_parsers.sh
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Mock _json_escape for use in dashboard_parsers
_json_escape() {
    local str="$1"
    printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$//'
}

# Helper: create a JSONL metric with specified parameters
_make_metric_line() {
    local total_time_s=$1
    local total_turns=$2
    local coder_turns=$3
    local reviewer_turns=$4
    local tester_turns=$5
    local scout_turns=$6
    # Optional: per-stage durations (0 = not provided)
    local coder_dur=${7:-0}
    local reviewer_dur=${8:-0}
    local tester_dur=${9:-0}
    local scout_dur=${10:-0}

    {
        printf '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":%d,"total_time_s":%d,"coder_turns":%d,"reviewer_turns":%d,"tester_turns":%d,"scout_turns":%d,"outcome":"success"' \
            "$total_turns" "$total_time_s" "$coder_turns" "$reviewer_turns" "$tester_turns" "$scout_turns"

        if [[ $coder_dur -gt 0 || $reviewer_dur -gt 0 || $tester_dur -gt 0 || $scout_dur -gt 0 ]]; then
            printf ',"coder_duration_s":%d,"reviewer_duration_s":%d,"tester_duration_s":%d,"scout_duration_s":%d' \
                "$coder_dur" "$reviewer_dur" "$tester_dur" "$scout_dur"
        fi
        printf '}\n'
    }
}

# Helper: extract duration for a stage from parsed JSON
_get_stage_dur() {
    local json="$1"
    local stage="$2"
    echo "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if data and len(data) > 0:
        run = data[0]
        if '$stage' in run['stages']:
            print(run['stages']['$stage'].get('duration_s', 0))
        else:
            print(0)
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0"
}

echo "=== Test Suite: Proportional Duration Estimation ==="

# Test 1: Legacy metric without per-stage durations — estimate proportionally
echo "Test 1: Proportional duration estimation for legacy metrics"
metrics_file="$LOG_DIR/metrics_test1.jsonl"

# Create metric: 600s total, 20 turns total
# coder: 10 turns → should get 10/20 * 600 = 300s
# reviewer: 5 turns → should get 5/20 * 600 = 150s
# tester: 3 turns → should get 3/20 * 600 = 90s
# scout: 2 turns → should get 2/20 * 600 = 60s
_make_metric_line 600 20 10 5 3 2 0 0 0 0 >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

# Verify coder duration
coder_dur=$(_get_stage_dur "$result" "coder")
if [[ "$coder_dur" == "300" ]]; then
    pass "Coder duration estimated correctly: 10/20 * 600 = 300s"
else
    fail "Coder duration estimation failed: expected 300, got $coder_dur"
fi

# Verify reviewer duration
reviewer_dur=$(_get_stage_dur "$result" "reviewer")
if [[ "$reviewer_dur" == "150" ]]; then
    pass "Reviewer duration estimated correctly: 5/20 * 600 = 150s"
else
    fail "Reviewer duration estimation failed: expected 150, got $reviewer_dur"
fi

# Verify tester duration
tester_dur=$(_get_stage_dur "$result" "tester")
if [[ "$tester_dur" == "90" ]]; then
    pass "Tester duration estimated correctly: 3/20 * 600 = 90s"
else
    fail "Tester duration estimation failed: expected 90, got $tester_dur"
fi

# Test 2: When individual durations ARE provided, don't estimate
echo "Test 2: Use actual durations when provided (no estimation)"
metrics_file="$LOG_DIR/metrics_test2.jsonl"

# Create metric with explicit durations
_make_metric_line 600 20 10 5 3 2 250 120 80 150 >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur "$result" "coder")
if [[ "$coder_dur" == "250" ]]; then
    pass "Actual coder duration used (250s), not estimated"
else
    fail "Actual coder duration not used: expected 250, got $coder_dur"
fi

# Test 3: Edge case — zero total turns (should not estimate)
echo "Test 3: Zero total turns — no estimation"
metrics_file="$LOG_DIR/metrics_test3.jsonl"

# All turns are zero
_make_metric_line 600 0 0 0 0 0 0 0 0 0 > "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

# Stages should be empty or have zero duration
coder_dur=$(_get_stage_dur "$result" "coder")
if [[ "$coder_dur" == "0" || "$coder_dur" == "" ]]; then
    pass "Zero turns case handled correctly (no estimation)"
else
    fail "Zero turns case: unexpected coder_dur=$coder_dur"
fi

# Test 4: Partial durations — some stages have durations, some don't
echo "Test 4: Mixed — some stages have durations, others don't"
metrics_file="$LOG_DIR/metrics_test4.jsonl"

# coder and reviewer have durations, tester and scout don't
_make_metric_line 600 20 10 5 3 2 250 120 0 0 > "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur "$result" "coder")
reviewer_dur=$(_get_stage_dur "$result" "reviewer")
# When SOME stages have durations, estimation should NOT kick in (has_any_dur is true)
if [[ "$coder_dur" == "250" ]] && [[ "$reviewer_dur" == "120" ]]; then
    pass "Actual durations used when any stage has duration_s set"
else
    fail "Partial durations case failed: coder=$coder_dur, reviewer=$reviewer_dur"
fi

# Test 5: Asymmetric turns (one stage uses many turns but runs quickly)
echo "Test 5: Asymmetric turns/duration — long stage with few turns"
metrics_file="$LOG_DIR/metrics_test5.jsonl"

# Total: 600s, 100 turns
# coder: 50 turns → estimated 50/100 * 600 = 300s
# tester: 1 turn → estimated 1/100 * 600 = 6s (very fast)
# scout: 49 turns → estimated 49/100 * 600 = 294s
_make_metric_line 600 100 50 0 1 49 0 0 0 0 > "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur "$result" "coder")
tester_dur=$(_get_stage_dur "$result" "tester")
scout_dur=$(_get_stage_dur "$result" "scout")

if [[ "$coder_dur" == "300" ]] && [[ "$tester_dur" == "6" ]] && [[ "$scout_dur" == "294" ]]; then
    pass "Asymmetric case: coder=300s (50 turns), tester=6s (1 turn), scout=294s (49 turns)"
else
    fail "Asymmetric case failed: coder=$coder_dur, tester=$tester_dur, scout=$scout_dur"
fi

# Test 6: Large total_time with proper proportional distribution
echo "Test 6: Large total_time (3600s) with proper distribution"
metrics_file="$LOG_DIR/metrics_test6.jsonl"

# 1 hour = 3600s, with 20 turns total
# coder: 10 turns → 10/20 * 3600 = 1800s
# reviewer: 5 turns → 5/20 * 3600 = 900s
# tester: 3 turns → 3/20 * 3600 = 540s
# scout: 2 turns → 2/20 * 3600 = 360s
_make_metric_line 3600 20 10 5 3 2 0 0 0 0 > "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur "$result" "coder")
if [[ "$coder_dur" == "1800" ]]; then
    pass "Large total_time distributed correctly: 10/20 * 3600 = 1800s"
else
    fail "Large total_time case failed: expected 1800, got $coder_dur"
fi

# Test 7: Multiple metrics in JSONL — each processed independently
echo "Test 7: Multiple metrics in JSONL, each estimated independently"
metrics_file="$LOG_DIR/metrics_test7.jsonl"

# First metric: 300s, 10 turns
_make_metric_line 300 10 5 3 2 0 0 0 0 0 >> "$metrics_file"
# Second metric: 600s, 20 turns (should not be affected by first)
_make_metric_line 600 20 10 5 3 2 0 0 0 0 >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

# Check the second metric (most recent, appears first in reversed output)
# For second metric: coder should be 10/20 * 600 = 300s
coder_dur=$(_get_stage_dur "$result" "coder")
if [[ "$coder_dur" == "300" ]]; then
    pass "Multiple metrics in JSONL processed independently"
else
    fail "Multiple metrics case: expected coder=300, got $coder_dur"
fi

echo ""
echo "=== Test Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

[[ $FAIL -eq 0 ]]
