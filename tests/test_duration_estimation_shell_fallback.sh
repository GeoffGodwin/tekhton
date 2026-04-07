#!/usr/bin/env bash
# =============================================================================
# test_duration_estimation_shell_fallback.sh — Test shell fallback duration estimation
#
# Tests the portable sed/awk path in _parse_run_summaries_from_jsonl
# when Python is unavailable. This path should produce the same results
# as the Python path for proportional duration estimation.
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

# Mock _json_escape
_json_escape() {
    local str="$1"
    printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$//'
}

# Mock python3 to force shell fallback path
python3() { return 1; }
export -f python3

# Source dashboard_parsers.sh
# shellcheck source=../lib/dashboard_parsers.sh
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Helper: extract duration for a stage from parsed JSON using portable tools
_get_stage_dur_shell() {
    local json="$1"
    local stage="$2"

    # Extract the stages object and look for the stage
    printf '%s' "$json" | sed -n "s/.*\"${stage}\":{\"turns\":[0-9]*,\"duration_s\":\([0-9]*\).*/\1/p" | head -1
}

echo "=== Test Suite: Shell Fallback Proportional Duration Estimation ==="

# Test 1: Legacy metric without per-stage durations — shell fallback estimation
echo "Test 1: Shell fallback — proportional duration estimation"
metrics_file="$LOG_DIR/metrics_shell_test1.jsonl"

# Create metric: 600s total, 20 turns total
# Expected: coder: 10/20 * 600 = 300s, reviewer: 5/20 * 600 = 150s, etc.
echo '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":20,"total_time_s":600,"coder_turns":10,"reviewer_turns":5,"tester_turns":3,"scout_turns":2,"outcome":"success"}' >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur_shell "$result" "coder")
if [[ "$coder_dur" == "300" ]]; then
    pass "Shell fallback: coder duration 10/20 * 600 = 300s"
else
    fail "Shell fallback: expected coder=300, got $coder_dur"
fi

reviewer_dur=$(_get_stage_dur_shell "$result" "reviewer")
if [[ "$reviewer_dur" == "150" ]]; then
    pass "Shell fallback: reviewer duration 5/20 * 600 = 150s"
else
    fail "Shell fallback: expected reviewer=150, got $reviewer_dur"
fi

tester_dur=$(_get_stage_dur_shell "$result" "tester")
if [[ "$tester_dur" == "90" ]]; then
    pass "Shell fallback: tester duration 3/20 * 600 = 90s"
else
    fail "Shell fallback: expected tester=90, got $tester_dur"
fi

# Test 2: Shell fallback with explicit durations — should use them, not estimate
echo "Test 2: Shell fallback with explicit durations (no estimation)"
metrics_file="$LOG_DIR/metrics_shell_test2.jsonl"

echo '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":20,"total_time_s":600,"coder_turns":10,"reviewer_turns":5,"tester_turns":3,"scout_turns":2,"coder_duration_s":250,"reviewer_duration_s":120,"tester_duration_s":80,"scout_duration_s":150,"outcome":"success"}' >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur_shell "$result" "coder")
if [[ "$coder_dur" == "250" ]]; then
    pass "Shell fallback: actual coder duration 250s used (not estimated)"
else
    fail "Shell fallback: expected coder=250, got $coder_dur"
fi

# Test 3: Shell fallback with asymmetric turns
echo "Test 3: Shell fallback with asymmetric turns"
metrics_file="$LOG_DIR/metrics_shell_test3.jsonl"

# 600s total, 100 turns: coder 50 turns (300s), tester 1 turn (6s), scout 49 turns (294s)
echo '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":100,"total_time_s":600,"coder_turns":50,"reviewer_turns":0,"tester_turns":1,"scout_turns":49,"outcome":"success"}' >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur_shell "$result" "coder")
scout_dur=$(_get_stage_dur_shell "$result" "scout")

if [[ "$coder_dur" == "300" ]] && [[ "$scout_dur" == "294" ]]; then
    pass "Shell fallback: asymmetric case coder=300s, scout=294s"
else
    fail "Shell fallback: expected coder=300, scout=294, got coder=$coder_dur, scout=$scout_dur"
fi

# Test 4: Shell fallback with zero total turns
echo "Test 4: Shell fallback with zero total turns (no estimation)"
metrics_file="$LOG_DIR/metrics_shell_test4.jsonl"

echo '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":0,"total_time_s":600,"coder_turns":0,"reviewer_turns":0,"tester_turns":0,"scout_turns":0,"outcome":"success"}' >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur_shell "$result" "coder")
if [[ -z "$coder_dur" || "$coder_dur" == "0" ]]; then
    pass "Shell fallback: zero turns case handled (no stages or zero durations)"
else
    fail "Shell fallback: zero turns should not estimate, got coder=$coder_dur"
fi

# Test 5: Shell fallback with large total_time
echo "Test 5: Shell fallback with large total_time (3600s)"
metrics_file="$LOG_DIR/metrics_shell_test5.jsonl"

# 3600s total, 20 turns: coder 10 turns (1800s), reviewer 5 (900s), etc.
echo '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":20,"total_time_s":3600,"coder_turns":10,"reviewer_turns":5,"tester_turns":3,"scout_turns":2,"outcome":"success"}' >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur_shell "$result" "coder")
if [[ "$coder_dur" == "1800" ]]; then
    pass "Shell fallback: large total_time 10/20 * 3600 = 1800s"
else
    fail "Shell fallback: expected coder=1800, got $coder_dur"
fi

# Test 6: Shell fallback with single-digit turns
echo "Test 6: Shell fallback with single-digit turns"
metrics_file="$LOG_DIR/metrics_shell_test6.jsonl"

# 300s total, 3 turns: coder 2 turns (200s), reviewer 1 turn (100s)
echo '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":3,"total_time_s":300,"coder_turns":2,"reviewer_turns":1,"tester_turns":0,"scout_turns":0,"outcome":"success"}' >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur_shell "$result" "coder")
reviewer_dur=$(_get_stage_dur_shell "$result" "reviewer")

if [[ "$coder_dur" == "200" ]] && [[ "$reviewer_dur" == "100" ]]; then
    pass "Shell fallback: single-digit turns coder=200s, reviewer=100s"
else
    fail "Shell fallback: expected coder=200, reviewer=100, got coder=$coder_dur, reviewer=$reviewer_dur"
fi

# Test 7: Shell fallback with partial durations (some stages have durations, some don't)
echo "Test 7: Shell fallback with partial durations (has_any_dur=true, no estimation)"
metrics_file="$LOG_DIR/metrics_shell_test7.jsonl"

# coder and reviewer have durations, tester and scout don't
echo '{"timestamp":"2025-01-01T00:00:00Z","task":"test","task_type":"feature","milestone_mode":false,"total_turns":20,"total_time_s":600,"coder_turns":10,"reviewer_turns":5,"tester_turns":3,"scout_turns":2,"coder_duration_s":250,"reviewer_duration_s":120,"outcome":"success"}' >> "$metrics_file"

result=$(_parse_run_summaries_from_jsonl "$metrics_file" 10)

coder_dur=$(_get_stage_dur_shell "$result" "coder")
# When ANY stage has duration_s, estimation doesn't kick in
# In this case, tester and scout are not in the stages object, so their durations should be 0 or missing
if [[ "$coder_dur" == "250" ]]; then
    pass "Shell fallback: when any stage has duration_s, use actual (coder=250s)"
else
    fail "Shell fallback: expected actual coder=250, got $coder_dur"
fi

echo ""
echo "=== Test Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

[[ $FAIL -eq 0 ]]
