#!/usr/bin/env bash
# Test: lib/metrics.sh — record_run_metrics, summarize_metrics, calibrate_turn_estimate
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Setup: create temp project dir
# =============================================================================

TEST_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${TEST_DIR}'" EXIT

mkdir -p "${TEST_DIR}/.claude/logs"
PROJECT_DIR="$TEST_DIR"
LOG_DIR="${TEST_DIR}/.claude/logs"
export PROJECT_DIR LOG_DIR

# Source libraries
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics_extended.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics_dashboard.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics_calibration.sh"

# =============================================================================
# _classify_task_type
# =============================================================================

echo "=== _classify_task_type ==="

result=$(_classify_task_type "Fix: login bug crashes on empty password")
if [ "$result" = "bug" ]; then
    pass "_classify_task_type 'Fix: ...' → bug"
else
    fail "expected 'bug', got '${result}'"
fi

result=$(_classify_task_type "Implement Milestone 3: Auto-advance")
if [ "$result" = "milestone" ]; then
    pass "_classify_task_type 'Implement Milestone 3' → milestone"
else
    fail "expected 'milestone', got '${result}'"
fi

result=$(_classify_task_type "Add user authentication")
if [ "$result" = "feature" ]; then
    pass "_classify_task_type 'Add user authentication' → feature"
else
    fail "expected 'feature', got '${result}'"
fi

result=$(_classify_task_type "bugfix: handle null pointer")
if [ "$result" = "bug" ]; then
    pass "_classify_task_type 'bugfix: ...' → bug"
else
    fail "expected 'bug', got '${result}'"
fi

# =============================================================================
# record_run_metrics
# =============================================================================

echo
echo "=== record_run_metrics ==="

# Reset metrics file path for fresh test
_METRICS_FILE=""

# Set pipeline globals
TASK="Fix: login crash"
MILESTONE_MODE=false
TOTAL_TURNS=42
TOTAL_TIME=300
STAGE_SUMMARY="\n  Scout: 5/20 turns, 0m30s\n  Coder: 30/50 turns, 3m0s\n  Reviewer: 7/10 turns, 1m0s"
VERDICT="APPROVED"
SCOUT_REC_CODER_TURNS=35
SCOUT_REC_REVIEWER_TURNS=8
SCOUT_REC_TESTER_TURNS=20
ADJUSTED_CODER_TURNS=35
ADJUSTED_REVIEWER_TURNS=8
ADJUSTED_TESTER_TURNS=20
LAST_CONTEXT_TOKENS=5000
METRICS_ENABLED=true

record_run_metrics

METRICS_FILE="${LOG_DIR}/metrics.jsonl"

if [ -f "$METRICS_FILE" ]; then
    pass "record_run_metrics creates metrics.jsonl"
else
    fail "metrics.jsonl not found at ${METRICS_FILE}"
fi

# Verify JSONL content
line=$(cat "$METRICS_FILE")
if echo "$line" | grep -q '"task_type":"bug"'; then
    pass "metrics record has correct task_type"
else
    fail "expected task_type:bug in record: ${line}"
fi

if echo "$line" | grep -q '"total_turns":42'; then
    pass "metrics record has correct total_turns"
else
    fail "expected total_turns:42 in record: ${line}"
fi

if echo "$line" | grep -q '"outcome":"success"'; then
    pass "metrics record maps APPROVED → success"
else
    fail "expected outcome:success in record: ${line}"
fi

if echo "$line" | grep -q '"scout_est_coder":35'; then
    pass "metrics record captures scout estimate"
else
    fail "expected scout_est_coder:35 in record: ${line}"
fi

if echo "$line" | grep -q '"milestone_mode":false'; then
    pass "metrics record captures milestone_mode"
else
    fail "expected milestone_mode:false in record: ${line}"
fi

# Test METRICS_ENABLED=false skips recording
_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
METRICS_ENABLED=false
record_run_metrics
if [ ! -f "${LOG_DIR}/metrics.jsonl" ]; then
    pass "METRICS_ENABLED=false skips recording"
else
    fail "metrics.jsonl should not exist when METRICS_ENABLED=false"
fi
METRICS_ENABLED=true

# =============================================================================
# _extract_stage_turns
# =============================================================================

echo
echo "=== _extract_stage_turns ==="

summary="\n  Scout: 5/20 turns, 0m30s\n  Coder: 30/50 turns, 3m0s\n  Reviewer: 7/10 turns, 1m0s\n  Tester: 25/30 turns, 2m0s"

result=$(_extract_stage_turns "$summary" "Coder")
if [ "$result" = "30" ]; then
    pass "_extract_stage_turns extracts Coder turns = 30"
else
    fail "expected 30, got '${result}'"
fi

result=$(_extract_stage_turns "$summary" "Reviewer")
if [ "$result" = "7" ]; then
    pass "_extract_stage_turns extracts Reviewer turns = 7"
else
    fail "expected 7, got '${result}'"
fi

result=$(_extract_stage_turns "$summary" "Scout")
if [ "$result" = "5" ]; then
    pass "_extract_stage_turns extracts Scout turns = 5"
else
    fail "expected 5, got '${result}'"
fi

result=$(_extract_stage_turns "$summary" "Missing")
if [ "$result" = "0" ]; then
    pass "_extract_stage_turns returns 0 for missing stage"
else
    fail "expected 0, got '${result}'"
fi

# =============================================================================
# calibrate_turn_estimate — no data
# =============================================================================

echo
echo "=== calibrate_turn_estimate ==="

# No metrics file → returns original estimate
_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
result=$(calibrate_turn_estimate 50 "coder")
if [ "$result" = "50" ]; then
    pass "calibrate_turn_estimate returns original when no metrics file"
else
    fail "expected 50, got '${result}'"
fi

# Disabled → returns original
_METRICS_FILE=""
METRICS_ADAPTIVE_TURNS=false
result=$(calibrate_turn_estimate 50 "coder")
if [ "$result" = "50" ]; then
    pass "calibrate_turn_estimate returns original when disabled"
else
    fail "expected 50, got '${result}'"
fi
METRICS_ADAPTIVE_TURNS=true

# Too few runs → returns original
_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
METRICS_MIN_RUNS=5
echo '{"task_type":"feature","scout_est_coder":30,"coder_turns":40,"scout_est_reviewer":10,"reviewer_turns":12,"scout_est_tester":20,"tester_turns":25}' > "${LOG_DIR}/metrics.jsonl"
result=$(calibrate_turn_estimate 50 "coder")
if [ "$result" = "50" ]; then
    pass "calibrate_turn_estimate returns original with too few runs"
else
    fail "expected 50, got '${result}'"
fi

# =============================================================================
# calibrate_turn_estimate — with enough data
# =============================================================================

echo
echo "=== calibrate_turn_estimate — with data ==="

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
# Write 6 records where scout consistently underestimates coder by ~40%
# est=30, actual=42 → multiplier = 42/30 = 1.4 → 140%
for i in 1 2 3 4 5 6; do
    echo "{\"task_type\":\"feature\",\"scout_est_coder\":30,\"coder_turns\":42,\"scout_est_reviewer\":10,\"reviewer_turns\":10,\"scout_est_tester\":20,\"tester_turns\":20}" >> "${LOG_DIR}/metrics.jsonl"
done

METRICS_MIN_RUNS=5
result=$(calibrate_turn_estimate 50 "coder" | tail -1)
# Expected: 50 * 140% = 70
if [ "$result" = "70" ]; then
    pass "calibrate_turn_estimate applies 1.4x multiplier (50 → 70)"
else
    fail "expected 70, got '${result}'"
fi

# Reviewer with no calibration needed (est matches actual)
result=$(calibrate_turn_estimate 10 "reviewer" | tail -1)
# est=10, actual=10 → multiplier = 1.0 → 100%
if [ "$result" = "10" ]; then
    pass "calibrate_turn_estimate returns unchanged when estimate matches actual"
else
    fail "expected 10, got '${result}'"
fi

# =============================================================================
# calibrate_turn_estimate — clamping
# =============================================================================

echo
echo "=== calibrate_turn_estimate — clamping ==="

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
# Write records where scout vastly overestimates (est=100, actual=10 → 10%)
# Should clamp to 50% (0.5x)
for i in 1 2 3 4 5 6; do
    echo "{\"task_type\":\"feature\",\"scout_est_coder\":100,\"coder_turns\":10,\"scout_est_reviewer\":0,\"reviewer_turns\":0,\"scout_est_tester\":0,\"tester_turns\":0}" >> "${LOG_DIR}/metrics.jsonl"
done

result=$(calibrate_turn_estimate 50 "coder" | tail -1)
# Expected: 50 * 50% = 25 (clamped to 0.5x floor)
if [ "$result" = "25" ]; then
    pass "calibrate_turn_estimate clamps low multiplier to 0.5x (50 → 25)"
else
    fail "expected 25, got '${result}'"
fi

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
# Write records where scout vastly underestimates (est=10, actual=100 → 1000%)
# Should clamp to 200% (2.0x)
for i in 1 2 3 4 5 6; do
    echo "{\"task_type\":\"feature\",\"scout_est_coder\":10,\"coder_turns\":100,\"scout_est_reviewer\":0,\"reviewer_turns\":0,\"scout_est_tester\":0,\"tester_turns\":0}" >> "${LOG_DIR}/metrics.jsonl"
done

result=$(calibrate_turn_estimate 50 "coder" | tail -1)
# Expected: 50 * 200% = 100 (clamped to 2.0x ceiling)
if [ "$result" = "100" ]; then
    pass "calibrate_turn_estimate clamps high multiplier to 2.0x (50 → 100)"
else
    fail "expected 100, got '${result}'"
fi

# =============================================================================
# summarize_metrics
# =============================================================================

echo
echo "=== summarize_metrics ==="

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

# Write mixed records
echo '{"timestamp":"2026-03-17T10:00:00Z","task":"Fix: bug","task_type":"bug","milestone_mode":false,"total_turns":20,"total_time_s":120,"coder_turns":15,"reviewer_turns":5,"tester_turns":0,"scout_turns":3,"scout_est_coder":20,"scout_est_reviewer":5,"scout_est_tester":0,"adjusted_coder":20,"adjusted_reviewer":5,"adjusted_tester":0,"context_tokens":3000,"verdict":"APPROVED","outcome":"success"}' >> "${LOG_DIR}/metrics.jsonl"
echo '{"timestamp":"2026-03-17T11:00:00Z","task":"Add auth","task_type":"feature","milestone_mode":false,"total_turns":45,"total_time_s":300,"coder_turns":30,"reviewer_turns":10,"tester_turns":5,"scout_turns":5,"scout_est_coder":25,"scout_est_reviewer":8,"scout_est_tester":10,"adjusted_coder":25,"adjusted_reviewer":8,"adjusted_tester":10,"context_tokens":5000,"verdict":"APPROVED","outcome":"success"}' >> "${LOG_DIR}/metrics.jsonl"
echo '{"timestamp":"2026-03-17T12:00:00Z","task":"Implement Milestone 1","task_type":"milestone","milestone_mode":true,"total_turns":85,"total_time_s":600,"coder_turns":60,"reviewer_turns":15,"tester_turns":10,"scout_turns":5,"scout_est_coder":50,"scout_est_reviewer":10,"scout_est_tester":15,"adjusted_coder":50,"adjusted_reviewer":10,"adjusted_tester":15,"context_tokens":8000,"verdict":"APPROVED","outcome":"success"}' >> "${LOG_DIR}/metrics.jsonl"

output=$(summarize_metrics 50)

if echo "$output" | grep -q "Bug fixes:"; then
    pass "summarize_metrics shows bug fixes"
else
    fail "missing 'Bug fixes:' in output: ${output}"
fi

if echo "$output" | grep -q "Features:"; then
    pass "summarize_metrics shows features"
else
    fail "missing 'Features:' in output: ${output}"
fi

if echo "$output" | grep -q "Milestones:"; then
    pass "summarize_metrics shows milestones"
else
    fail "missing 'Milestones:' in output: ${output}"
fi

if echo "$output" | grep -q "Scout accuracy:"; then
    pass "summarize_metrics shows scout accuracy"
else
    fail "missing 'Scout accuracy:' in output: ${output}"
fi

if echo "$output" | grep -q "100%"; then
    pass "summarize_metrics shows 100% success rate"
else
    fail "expected 100% success rate in output: ${output}"
fi

# Empty metrics
_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
output=$(summarize_metrics 50)
if echo "$output" | grep -q "No metrics data"; then
    pass "summarize_metrics handles empty metrics file"
else
    fail "expected 'No metrics data' message: ${output}"
fi

# =============================================================================
# record_run_metrics — error classification fields (12.3)
# =============================================================================

echo
echo "=== record_run_metrics — error classification fields ==="

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

# Record a run with error classification
TASK="Fix: api crash"
MILESTONE_MODE=false
TOTAL_TURNS=2
TOTAL_TIME=15
STAGE_SUMMARY="\n  Coder: 2/50 turns, 0m15s"
VERDICT="UPSTREAM/api_500"
AGENT_ERROR_CATEGORY="UPSTREAM"
AGENT_ERROR_SUBCATEGORY="api_500"
AGENT_ERROR_TRANSIENT="true"
METRICS_ENABLED=true

record_run_metrics

line=$(cat "${LOG_DIR}/metrics.jsonl")

if echo "$line" | grep -q '"error_category":"UPSTREAM"'; then
    pass "metrics record includes error_category on failure"
else
    fail "expected error_category:UPSTREAM in record: ${line}"
fi

if echo "$line" | grep -q '"error_subcategory":"api_500"'; then
    pass "metrics record includes error_subcategory on failure"
else
    fail "expected error_subcategory:api_500 in record: ${line}"
fi

if echo "$line" | grep -q '"error_transient":true'; then
    pass "metrics record includes error_transient on failure"
else
    fail "expected error_transient:true in record: ${line}"
fi

# Record a success run — error fields should be absent
_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
TASK="Add feature"
VERDICT="APPROVED"
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""

record_run_metrics

line=$(cat "${LOG_DIR}/metrics.jsonl")

if echo "$line" | grep -q '"error_category"'; then
    fail "success record should not include error_category: ${line}"
else
    pass "success record omits error fields"
fi

# Clean up error globals
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""

# =============================================================================
# summarize_metrics — error breakdown (12.3)
# =============================================================================

echo
echo "=== summarize_metrics — error breakdown ==="

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

# Write records with various error categories
echo '{"timestamp":"2026-03-18T10:00:00Z","task":"Fix: api","task_type":"bug","milestone_mode":false,"total_turns":2,"total_time_s":15,"coder_turns":2,"reviewer_turns":0,"tester_turns":0,"scout_turns":0,"scout_est_coder":0,"scout_est_reviewer":0,"scout_est_tester":0,"adjusted_coder":0,"adjusted_reviewer":0,"adjusted_tester":0,"context_tokens":0,"verdict":"UPSTREAM/api_500","outcome":"UPSTREAM/api_500","error_category":"UPSTREAM","error_subcategory":"api_500","error_transient":true}' >> "${LOG_DIR}/metrics.jsonl"
echo '{"timestamp":"2026-03-18T10:01:00Z","task":"Fix: oom","task_type":"bug","milestone_mode":false,"total_turns":0,"total_time_s":5,"coder_turns":0,"reviewer_turns":0,"tester_turns":0,"scout_turns":0,"scout_est_coder":0,"scout_est_reviewer":0,"scout_est_tester":0,"adjusted_coder":0,"adjusted_reviewer":0,"adjusted_tester":0,"context_tokens":0,"verdict":"ENVIRONMENT/oom","outcome":"ENVIRONMENT/oom","error_category":"ENVIRONMENT","error_subcategory":"oom","error_transient":true}' >> "${LOG_DIR}/metrics.jsonl"
echo '{"timestamp":"2026-03-18T10:02:00Z","task":"Add auth","task_type":"feature","milestone_mode":false,"total_turns":50,"total_time_s":300,"coder_turns":40,"reviewer_turns":10,"tester_turns":0,"scout_turns":5,"scout_est_coder":30,"scout_est_reviewer":8,"scout_est_tester":0,"adjusted_coder":30,"adjusted_reviewer":8,"adjusted_tester":0,"context_tokens":5000,"verdict":"APPROVED","outcome":"success"}' >> "${LOG_DIR}/metrics.jsonl"
echo '{"timestamp":"2026-03-18T10:03:00Z","task":"Milestone 1","task_type":"milestone","milestone_mode":true,"total_turns":0,"total_time_s":10,"coder_turns":0,"reviewer_turns":0,"tester_turns":0,"scout_turns":0,"scout_est_coder":0,"scout_est_reviewer":0,"scout_est_tester":0,"adjusted_coder":0,"adjusted_reviewer":0,"adjusted_tester":0,"context_tokens":0,"verdict":"null_run","outcome":"null_run","error_category":"AGENT_SCOPE","error_subcategory":"null_run","error_transient":false}' >> "${LOG_DIR}/metrics.jsonl"

output=$(summarize_metrics 50)

if echo "$output" | grep -q "Error breakdown:"; then
    pass "summarize_metrics shows error breakdown section"
else
    fail "missing 'Error breakdown:' in output: ${output}"
fi

if echo "$output" | grep -q "UPSTREAM:.*1.*transient.*auto-retry"; then
    pass "summarize_metrics shows UPSTREAM errors with auto-retry note"
else
    fail "missing UPSTREAM error line in output: ${output}"
fi

if echo "$output" | grep -q "ENVIRONMENT:.*1"; then
    pass "summarize_metrics shows ENVIRONMENT errors"
else
    fail "missing ENVIRONMENT error line in output: ${output}"
fi

if echo "$output" | grep -q "AGENT_SCOPE:.*1.*permanent"; then
    pass "summarize_metrics shows AGENT_SCOPE errors as permanent"
else
    fail "missing AGENT_SCOPE error line in output: ${output}"
fi

# No error records → no error breakdown section
_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
echo '{"timestamp":"2026-03-18T10:00:00Z","task":"Add auth","task_type":"feature","milestone_mode":false,"total_turns":50,"total_time_s":300,"coder_turns":40,"reviewer_turns":10,"tester_turns":0,"scout_turns":5,"scout_est_coder":30,"scout_est_reviewer":8,"scout_est_tester":0,"adjusted_coder":30,"adjusted_reviewer":8,"adjusted_tester":0,"context_tokens":5000,"verdict":"APPROVED","outcome":"success"}' >> "${LOG_DIR}/metrics.jsonl"

output=$(summarize_metrics 50)
if echo "$output" | grep -q "Error breakdown:"; then
    fail "summarize_metrics should not show error breakdown when no errors exist"
else
    pass "summarize_metrics omits error breakdown when no errors"
fi

# =============================================================================
# Config defaults
# =============================================================================

echo
echo "=== Config defaults ==="

metrics_enabled=$(
    unset METRICS_ENABLED 2>/dev/null || true
    unset METRICS_MIN_RUNS 2>/dev/null || true
    unset METRICS_ADAPTIVE_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    PROJECT_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${PROJECT_DIR}'" EXIT
    mkdir -p "${PROJECT_DIR}/.claude"
    printf 'PROJECT_NAME=test\nCLAUDE_STANDARD_MODEL=claude-sonnet\nANALYZE_CMD=true\n' \
        > "${PROJECT_DIR}/.claude/pipeline.conf"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "$METRICS_ENABLED"
)
if [ "$metrics_enabled" = "true" ]; then
    pass "default METRICS_ENABLED is true"
else
    fail "expected METRICS_ENABLED=true, got '${metrics_enabled}'"
fi

min_runs=$(
    unset METRICS_ENABLED 2>/dev/null || true
    unset METRICS_MIN_RUNS 2>/dev/null || true
    unset METRICS_ADAPTIVE_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    PROJECT_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${PROJECT_DIR}'" EXIT
    mkdir -p "${PROJECT_DIR}/.claude"
    printf 'PROJECT_NAME=test\nCLAUDE_STANDARD_MODEL=claude-sonnet\nANALYZE_CMD=true\n' \
        > "${PROJECT_DIR}/.claude/pipeline.conf"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "$METRICS_MIN_RUNS"
)
if [ "$min_runs" = "5" ]; then
    pass "default METRICS_MIN_RUNS is 5"
else
    fail "expected METRICS_MIN_RUNS=5, got '${min_runs}'"
fi

adaptive=$(
    unset METRICS_ENABLED 2>/dev/null || true
    unset METRICS_MIN_RUNS 2>/dev/null || true
    unset METRICS_ADAPTIVE_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    PROJECT_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${PROJECT_DIR}'" EXIT
    mkdir -p "${PROJECT_DIR}/.claude"
    printf 'PROJECT_NAME=test\nCLAUDE_STANDARD_MODEL=claude-sonnet\nANALYZE_CMD=true\n' \
        > "${PROJECT_DIR}/.claude/pipeline.conf"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "$METRICS_ADAPTIVE_TURNS"
)
if [ "$adaptive" = "true" ]; then
    pass "default METRICS_ADAPTIVE_TURNS is true"
else
    fail "expected METRICS_ADAPTIVE_TURNS=true, got '${adaptive}'"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
