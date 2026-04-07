#!/usr/bin/env bash
# =============================================================================
# test_progress.sh — Unit tests for lib/progress.sh (M50)
#
# Tests: _format_elapsed, _format_estimate, log_decision, _get_decision_log,
#        _get_timing_breakdown, progress_status, progress_outcome,
#        _estimate_stage_time
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs for logging (log goes to a capture file so we can assert on it)
LOG_CAPTURE="${TEST_TMPDIR}/log_output.txt"
log()     { echo "$*" >> "$LOG_CAPTURE"; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source the module under test
# shellcheck source=../lib/progress.sh
source "${TEKHTON_HOME}/lib/progress.sh"

# =============================================================================
# _format_elapsed
# =============================================================================
echo "=== Test: _format_elapsed — sub-minute ==="

result=$(_format_elapsed 0)
[[ "$result" = "0s" ]] && pass "_format_elapsed 0 → '0s'" || fail "Expected '0s', got '${result}'"

result=$(_format_elapsed 1)
[[ "$result" = "1s" ]] && pass "_format_elapsed 1 → '1s'" || fail "Expected '1s', got '${result}'"

result=$(_format_elapsed 59)
[[ "$result" = "59s" ]] && pass "_format_elapsed 59 → '59s'" || fail "Expected '59s', got '${result}'"

echo "=== Test: _format_elapsed — minute boundary ==="

result=$(_format_elapsed 60)
[[ "$result" = "1m 0s" ]] && pass "_format_elapsed 60 → '1m 0s'" || fail "Expected '1m 0s', got '${result}'"

result=$(_format_elapsed 90)
[[ "$result" = "1m 30s" ]] && pass "_format_elapsed 90 → '1m 30s'" || fail "Expected '1m 30s', got '${result}'"

result=$(_format_elapsed 125)
[[ "$result" = "2m 5s" ]] && pass "_format_elapsed 125 → '2m 5s'" || fail "Expected '2m 5s', got '${result}'"

result=$(_format_elapsed 3600)
[[ "$result" = "60m 0s" ]] && pass "_format_elapsed 3600 → '60m 0s'" || fail "Expected '60m 0s', got '${result}'"

# =============================================================================
# _format_estimate
# =============================================================================
echo "=== Test: _format_estimate — empty/zero ==="

result=$(_format_estimate "")
[[ "$result" = "no estimate" ]] && pass "_format_estimate '' → 'no estimate'" || fail "Expected 'no estimate', got '${result}'"

result=$(_format_estimate 0)
[[ "$result" = "no estimate" ]] && pass "_format_estimate 0 → 'no estimate'" || fail "Expected 'no estimate', got '${result}'"

echo "=== Test: _format_estimate — positive seconds (±30% range) ==="

# 100s estimate: low=70s, high=130s → "estimated 1m 10s-2m 10s based on history"
result=$(_format_estimate 100)
# Check it contains "estimated" and "based on history"
if echo "$result" | grep -q "^estimated" && echo "$result" | grep -q "based on history"; then
    pass "_format_estimate 100 → range string with expected prefix/suffix"
else
    fail "_format_estimate 100 → unexpected format: '${result}'"
fi

# 10s: low=7s, high=13s
result=$(_format_estimate 10)
if echo "$result" | grep -q "^estimated 7s-13s based on history"; then
    pass "_format_estimate 10 → 'estimated 7s-13s based on history'"
else
    fail "_format_estimate 10 → unexpected: '${result}'"
fi

# 60s: low=42s, high=78s → "estimated 42s-1m 18s based on history"
result=$(_format_estimate 60)
if echo "$result" | grep -q "^estimated 42s-1m 18s based on history"; then
    pass "_format_estimate 60 → 'estimated 42s-1m 18s based on history'"
else
    fail "_format_estimate 60 → unexpected: '${result}'"
fi

# =============================================================================
# log_decision — accumulation and log() output
# =============================================================================
echo "=== Test: log_decision — accumulates in _DECISION_LOG ==="

# Reset state
_DECISION_LOG=""
> "$LOG_CAPTURE"

log_decision "Scout skipped" "cached results available" "SCOUT_CACHE_ENABLED"

# _DECISION_LOG should contain the entry
if echo "$_DECISION_LOG" | grep -q "Scout skipped|cached results available|SCOUT_CACHE_ENABLED"; then
    pass "log_decision stores pipe-separated entry in _DECISION_LOG"
else
    fail "log_decision entry not found in _DECISION_LOG: '${_DECISION_LOG}'"
fi

# log() should have been called with the decision
if grep -q "Scout skipped" "$LOG_CAPTURE"; then
    pass "log_decision calls log() with decision text"
else
    fail "log_decision did not call log(): '$(cat "$LOG_CAPTURE")'"
fi

echo "=== Test: log_decision — multiple decisions accumulate ==="

_DECISION_LOG=""
log_decision "Decision A" "reason A" "KEY_A"
log_decision "Decision B" "reason B" "KEY_B"
log_decision "Decision C" "reason C" ""

line_count=$(echo "$_DECISION_LOG" | wc -l)
if [[ "$line_count" -eq 3 ]]; then
    pass "Three log_decision calls produce 3-line _DECISION_LOG"
else
    fail "Expected 3 lines in _DECISION_LOG, got ${line_count}"
fi

echo "=== Test: log_decision — optional config_key ==="

_DECISION_LOG=""
log_decision "No key decision" "some reason"

# Entry should have two pipes (decision|reason|) with empty config_key
if echo "$_DECISION_LOG" | grep -q "No key decision|some reason|$"; then
    pass "log_decision stores empty config_key correctly"
else
    fail "log_decision empty config_key not stored correctly: '${_DECISION_LOG}'"
fi

# =============================================================================
# _get_decision_log — JSON serialization
# =============================================================================
echo "=== Test: _get_decision_log — empty log returns [] ==="

_DECISION_LOG=""
result=$(_get_decision_log)
[[ "$result" = "[]" ]] && pass "_get_decision_log with empty log → '[]'" || fail "Expected '[]', got '${result}'"

echo "=== Test: _get_decision_log — single entry produces valid JSON ==="

_DECISION_LOG=""
log_decision "Rework routed" "complex blocker found" "MAX_REVIEW_CYCLES"
result=$(_get_decision_log)

# Must be valid JSON array with one object
if echo "$result" | grep -q '^\[{.*}\]$'; then
    pass "_get_decision_log single entry → JSON array format"
else
    fail "_get_decision_log single entry format unexpected: '${result}'"
fi

# Must contain expected fields
if echo "$result" | grep -q '"decision":"Rework routed"'; then
    pass "_get_decision_log contains decision field"
else
    fail "_get_decision_log missing decision field: '${result}'"
fi

if echo "$result" | grep -q '"reason":"complex blocker found"'; then
    pass "_get_decision_log contains reason field"
else
    fail "_get_decision_log missing reason field: '${result}'"
fi

if echo "$result" | grep -q '"config_key":"MAX_REVIEW_CYCLES"'; then
    pass "_get_decision_log contains config_key field"
else
    fail "_get_decision_log missing config_key field: '${result}'"
fi

echo "=== Test: _get_decision_log — multiple entries ==="

_DECISION_LOG=""
log_decision "Decision 1" "reason 1" "KEY_1"
log_decision "Decision 2" "reason 2" "KEY_2"
result=$(_get_decision_log)

# Should have two objects in array
obj_count=$(echo "$result" | grep -o '"decision"' | wc -l)
if [[ "$obj_count" -eq 2 ]]; then
    pass "_get_decision_log two decisions → 2 objects in array"
else
    fail "_get_decision_log expected 2 objects, got ${obj_count}: '${result}'"
fi

# Must not have a leading comma between array open and first element
if echo "$result" | grep -q '^\[{'; then
    pass "_get_decision_log array starts with '[{' (no leading comma)"
else
    fail "_get_decision_log has malformed start: '${result}'"
fi

echo "=== Test: _get_decision_log — JSON-special chars escaped ==="

_DECISION_LOG=""
log_decision 'Has "quotes"' 'reason with "quotes"' "KEY"
result=$(_get_decision_log)

# Double quotes in values must be escaped as \"
if echo "$result" | grep -q '"decision":"Has \\"quotes\\""'; then
    pass "_get_decision_log escapes double quotes in decision"
else
    fail "_get_decision_log quote escaping failed: '${result}'"
fi

# =============================================================================
# _get_timing_breakdown
# =============================================================================
echo "=== Test: _get_timing_breakdown — no _STAGE_DURATION → '{}' ==="

# Ensure _STAGE_DURATION is not declared
unset _STAGE_DURATION 2>/dev/null || true
result=$(_get_timing_breakdown)
[[ "$result" = "{}" ]] && pass "_get_timing_breakdown with no array → '{}'" || fail "Expected '{}', got '${result}'"

echo "=== Test: _get_timing_breakdown — array with populated values ==="

declare -A _STAGE_DURATION=()
_STAGE_DURATION["coder"]=120
_STAGE_DURATION["reviewer"]=45

result=$(_get_timing_breakdown)

# Must contain the stage entries
if echo "$result" | grep -q '"coder":120'; then
    pass "_get_timing_breakdown contains coder:120"
else
    fail "_get_timing_breakdown missing coder entry: '${result}'"
fi

if echo "$result" | grep -q '"reviewer":45'; then
    pass "_get_timing_breakdown contains reviewer:45"
else
    fail "_get_timing_breakdown missing reviewer entry: '${result}'"
fi

# Must contain total
if echo "$result" | grep -q '"total":165'; then
    pass "_get_timing_breakdown total = 120+45 = 165"
else
    fail "_get_timing_breakdown wrong total: '${result}'"
fi

echo "=== Test: _get_timing_breakdown — skips zero-value stages ==="

declare -A _STAGE_DURATION=()
_STAGE_DURATION["coder"]=0
_STAGE_DURATION["reviewer"]=60

result=$(_get_timing_breakdown)

# coder:0 should be skipped, reviewer:60 should appear
if echo "$result" | grep -q '"coder"'; then
    fail "_get_timing_breakdown should skip zero-value stage 'coder': '${result}'"
else
    pass "_get_timing_breakdown skips zero-value stage 'coder'"
fi

if echo "$result" | grep -q '"reviewer":60'; then
    pass "_get_timing_breakdown includes non-zero stage 'reviewer'"
else
    fail "_get_timing_breakdown missing reviewer: '${result}'"
fi

echo "=== Test: _get_timing_breakdown — all-zero stages produces valid JSON ==="

declare -A _STAGE_DURATION=()
_STAGE_DURATION["coder"]=0
_STAGE_DURATION["reviewer"]=0

result=$(_get_timing_breakdown)

# All stages are zero → all skipped → output should be {}
if [[ "$result" = '{}' ]]; then
    pass "_get_timing_breakdown all-zero → '{}'"
else
    fail "_get_timing_breakdown all-zero expected '{}', got '${result}'"
fi

# =============================================================================
# progress_status — calls log() with stage info
# =============================================================================
echo "=== Test: progress_status — logs stage line ==="

> "$LOG_CAPTURE"
_DECISION_LOG=""
unset _STAGE_DURATION 2>/dev/null || true

progress_status 1 3 "Coder"

if grep -q "Stage 1/3: Coder" "$LOG_CAPTURE"; then
    pass "progress_status logs 'Stage 1/3: Coder'"
else
    fail "progress_status log output unexpected: '$(cat "$LOG_CAPTURE")'"
fi

echo "=== Test: progress_status — includes extra info when provided ==="

> "$LOG_CAPTURE"
progress_status 2 3 "Reviewer" "cycle 2"

if grep -q "cycle 2" "$LOG_CAPTURE"; then
    pass "progress_status includes extra info '(cycle 2)'"
else
    fail "progress_status missing extra info: '$(cat "$LOG_CAPTURE")'"
fi

echo "=== Test: progress_status — includes estimate string ==="

> "$LOG_CAPTURE"
progress_status 1 3 "Tester"

# Must include "no estimate" when no metrics file exists
if grep -q "no estimate" "$LOG_CAPTURE"; then
    pass "progress_status with no metrics → 'no estimate' in line"
else
    fail "progress_status missing estimate string: '$(cat "$LOG_CAPTURE")'"
fi

# =============================================================================
# progress_outcome — calls log() with result and elapsed
# =============================================================================
echo "=== Test: progress_outcome — logs name, result, elapsed ==="

> "$LOG_CAPTURE"
progress_outcome "Coder" "COMPLETE" 95

if grep -q "Coder: COMPLETE" "$LOG_CAPTURE"; then
    pass "progress_outcome logs 'Coder: COMPLETE'"
else
    fail "progress_outcome missing result: '$(cat "$LOG_CAPTURE")'"
fi

if grep -q "1m 35s" "$LOG_CAPTURE"; then
    pass "progress_outcome formats 95s as '1m 35s'"
else
    fail "progress_outcome wrong elapsed format: '$(cat "$LOG_CAPTURE")'"
fi

echo "=== Test: progress_outcome — includes next action when provided ==="

> "$LOG_CAPTURE"
progress_outcome "Reviewer" "CHANGES_REQUIRED" 30 "routing to rework"

if grep -q "routing to rework" "$LOG_CAPTURE"; then
    pass "progress_outcome includes next action"
else
    fail "progress_outcome missing next action: '$(cat "$LOG_CAPTURE")'"
fi

echo "=== Test: progress_outcome — omits next action when empty ==="

> "$LOG_CAPTURE"
progress_outcome "Scout" "DONE" 15

output=$(cat "$LOG_CAPTURE")
# Should have exactly one dash separator between result and elapsed, not a trailing one
if echo "$output" | grep -q "DONE — 15s$"; then
    pass "progress_outcome with no next_action ends after elapsed"
else
    fail "progress_outcome unexpected trailing content: '${output}'"
fi

# =============================================================================
# _estimate_stage_time — returns empty when no metrics file
# =============================================================================
echo "=== Test: _estimate_stage_time — no metrics file → empty ==="

unset _METRICS_FILE 2>/dev/null || true
PROJECT_DIR="$TEST_TMPDIR"

result=$(_estimate_stage_time "Coder")
if [[ -z "$result" ]]; then
    pass "_estimate_stage_time with no metrics file → empty string"
else
    fail "_estimate_stage_time expected empty, got '${result}'"
fi

echo "=== Test: _estimate_stage_time — reads metrics.jsonl and averages ==="

LOG_DIR="${TEST_TMPDIR}/.claude/logs"
mkdir -p "$LOG_DIR"
METRICS_FILE="${LOG_DIR}/metrics.jsonl"
_METRICS_FILE="$METRICS_FILE"

# Write 3 runs with "Coder" stage durations: 100, 200, 300 → average = 200
cat > "$METRICS_FILE" <<'EOF'
{"timestamp":"2026-01-01","stages":{"Coder":{"duration_s":100}}}
{"timestamp":"2026-01-02","stages":{"Coder":{"duration_s":200}}}
{"timestamp":"2026-01-03","stages":{"Coder":{"duration_s":300}}}
EOF

result=$(_estimate_stage_time "Coder")
if [[ "$result" -eq 200 ]]; then
    pass "_estimate_stage_time averages 3 entries → 200"
else
    fail "_estimate_stage_time expected 200, got '${result}'"
fi

echo "=== Test: _estimate_stage_time — unknown stage returns empty ==="

result=$(_estimate_stage_time "NonExistentStage")
if [[ -z "$result" ]]; then
    pass "_estimate_stage_time for unknown stage → empty"
else
    fail "_estimate_stage_time unknown stage expected empty, got '${result}'"
fi

# =============================================================================
# Results
# =============================================================================
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
exit "$FAIL"
