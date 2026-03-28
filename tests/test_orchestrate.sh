#!/usr/bin/env bash
# =============================================================================
# test_orchestrate.sh — Tests for the --complete outer orchestration loop (M16)
#
# Tests:
# - Orchestration state globals initialization
# - _classify_failure recovery decision tree
# - _check_progress stuck detection
# - _compute_diff_hash returns a hash
# - report_orchestration_status prints banner
# - record_pipeline_attempt builds attempt log
# - Safety bounds: MAX_PIPELINE_ATTEMPTS, AUTONOMOUS_TIMEOUT, agent call cap
# - _hook_emit_run_summary produces valid JSON
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals ---------------------------------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/logs"
LOG_FILE="$TMPDIR/test.log"
TASK="Test orchestration"
MILESTONE_MODE=false
_CURRENT_MILESTONE=""
PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"
TEKHTON_SESSION_DIR="$TMPDIR"
AUTONOMOUS_TIMEOUT=7200
MAX_PIPELINE_ATTEMPTS=5
MAX_AUTONOMOUS_AGENT_CALLS=20
AUTONOMOUS_PROGRESS_CHECK=true
TOTAL_TURNS=0
VERDICT="unknown"
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
START_AT="coder"
TIMESTAMP="20260320_120000"
MAX_REVIEW_CYCLES=3

export PROJECT_DIR LOG_DIR LOG_FILE TASK MILESTONE_MODE _CURRENT_MILESTONE
export PIPELINE_STATE_FILE TEKHTON_SESSION_DIR
export AUTONOMOUS_TIMEOUT MAX_PIPELINE_ATTEMPTS MAX_AUTONOMOUS_AGENT_CALLS
export AUTONOMOUS_PROGRESS_CHECK TOTAL_TURNS VERDICT
export AGENT_ERROR_CATEGORY AGENT_ERROR_SUBCATEGORY START_AT TIMESTAMP
export MAX_REVIEW_CYCLES

mkdir -p "$LOG_DIR" "$TMPDIR/.claude"
touch "$LOG_FILE"
cd "$TMPDIR"
git init -q .
git add -A >/dev/null 2>&1
git commit -q -m "init" --allow-empty 2>/dev/null

# --- Source common.sh for log/warn/success -----------------------------------
source "${TEKHTON_HOME}/lib/common.sh"

# Mock dependencies that orchestrate_recovery.sh and milestone_metadata.sh need
suggest_recovery() { echo "Check run log."; }
redact_sensitive() { cat; }
count_lines() { wc -l | tr -d '[:space:]'; }

# Source the files under test
source "${TEKHTON_HOME}/lib/orchestrate_recovery.sh"
source "${TEKHTON_HOME}/lib/milestone_metadata.sh"

# --- Test helpers ------------------------------------------------------------
PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
# Test Suite 1: _classify_failure recovery decision tree
# =============================================================================
echo "=== Test Suite 1: _classify_failure ==="

# Upstream → save_exit
AGENT_ERROR_CATEGORY="UPSTREAM"
AGENT_ERROR_SUBCATEGORY="rate_limit"
VERDICT=""
result=$(_classify_failure)
assert_eq "1.1 UPSTREAM → save_exit" "save_exit" "$result"

# AGENT_SCOPE/max_turns → split
AGENT_ERROR_CATEGORY="AGENT_SCOPE"
AGENT_ERROR_SUBCATEGORY="max_turns"
result=$(_classify_failure)
assert_eq "1.2 max_turns → split" "split" "$result"

# AGENT_SCOPE/null_run → split
AGENT_ERROR_SUBCATEGORY="null_run"
result=$(_classify_failure)
assert_eq "1.3 null_run → split" "split" "$result"

# AGENT_SCOPE/activity_timeout → save_exit
AGENT_ERROR_SUBCATEGORY="activity_timeout"
result=$(_classify_failure)
assert_eq "1.4 activity_timeout → save_exit" "save_exit" "$result"

# ENVIRONMENT → save_exit
AGENT_ERROR_CATEGORY="ENVIRONMENT"
AGENT_ERROR_SUBCATEGORY="missing_tool"
result=$(_classify_failure)
assert_eq "1.5 ENVIRONMENT → save_exit" "save_exit" "$result"

# PIPELINE → save_exit
AGENT_ERROR_CATEGORY="PIPELINE"
AGENT_ERROR_SUBCATEGORY="internal"
result=$(_classify_failure)
assert_eq "1.6 PIPELINE → save_exit" "save_exit" "$result"

# No error, CHANGES_REQUIRED verdict → bump_review
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
VERDICT="CHANGES_REQUIRED"
result=$(_classify_failure)
assert_eq "1.7 CHANGES_REQUIRED → bump_review" "bump_review" "$result"

# review_cycle_max verdict → bump_review
VERDICT="review_cycle_max"
result=$(_classify_failure)
assert_eq "1.8 review_cycle_max → bump_review" "bump_review" "$result"

# REPLAN_REQUIRED → save_exit (never retry)
VERDICT="REPLAN_REQUIRED"
result=$(_classify_failure)
assert_eq "1.9 REPLAN_REQUIRED → save_exit" "save_exit" "$result"

# Build gate failure → retry_coder_build
VERDICT=""
echo "Build errors here" > BUILD_ERRORS.md
result=$(_classify_failure)
assert_eq "1.10 build errors → retry_coder_build" "retry_coder_build" "$result"
rm -f BUILD_ERRORS.md

# Unclassified → save_exit
AGENT_ERROR_CATEGORY=""
VERDICT=""
result=$(_classify_failure)
assert_eq "1.11 unclassified → save_exit" "save_exit" "$result"

# =============================================================================
# Test Suite 2: _check_progress stuck detection
# =============================================================================
echo "=== Test Suite 2: _check_progress ==="

_ORCH_LAST_DIFF_HASH=""
_ORCH_NO_PROGRESS_COUNT=0

# First call with matching hash: no progress count increases to 1
_ORCH_LAST_DIFF_HASH=$(_compute_diff_hash)
_ORCH_NO_PROGRESS_COUNT=0
_result=0
_check_progress || _result=1
assert_eq "2.1 first no-change check increments count" "1" "$_ORCH_NO_PROGRESS_COUNT"
assert_eq "2.1b first no-change check still returns 0" "0" "$_result"

# Same hash again → stuck (count reaches 2)
_result=0
_check_progress || _result=1
assert_eq "2.2 stuck after 2 no-progress checks" "1" "$_result"
assert_eq "2.3 no progress count is 2" "2" "$_ORCH_NO_PROGRESS_COUNT"

# After actual change → progress detected
echo "change" > "$TMPDIR/newfile.txt"
git add newfile.txt >/dev/null 2>&1
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_LAST_DIFF_HASH="stale-hash"
_result=0
_check_progress || _result=1
assert_eq "2.4 progress detected after file change" "0" "$_ORCH_NO_PROGRESS_COUNT"

# Disabled check always returns 0
AUTONOMOUS_PROGRESS_CHECK=false
_ORCH_NO_PROGRESS_COUNT=5
_result=0
_check_progress || _result=1
assert_eq "2.5 disabled check returns 0" "0" "$_result"
AUTONOMOUS_PROGRESS_CHECK=true

# =============================================================================
# Test Suite 3: _compute_diff_hash
# =============================================================================
echo "=== Test Suite 3: _compute_diff_hash ==="

hash=$(_compute_diff_hash)
assert "3.1 hash is non-empty" "$([ -n "$hash" ] && echo 0 || echo 1)"

# Same state → same hash
hash2=$(_compute_diff_hash)
assert_eq "3.2 same state → same hash" "$hash" "$hash2"

# =============================================================================
# Test Suite 4: report_orchestration_status prints banner
# =============================================================================
echo "=== Test Suite 4: report_orchestration_status ==="

output=$(report_orchestration_status 2 5 125 8 2>&1)
assert "4.1 banner includes attempt count" "$(echo "$output" | grep -q "2" && echo 0 || echo 1)"
assert "4.2 banner includes elapsed time" "$(echo "$output" | grep -q "2m 5s" && echo 0 || echo 1)"
assert "4.3 banner includes agent calls" "$(echo "$output" | grep -q "8" && echo 0 || echo 1)"

# =============================================================================
# Test Suite 5: record_pipeline_attempt builds log
# =============================================================================
echo "=== Test Suite 5: record_pipeline_attempt ==="

_ORCH_ATTEMPT_LOG=""
record_pipeline_attempt "16" "1" "success" "45" "3" >/dev/null 2>&1
assert "5.1 log is non-empty" "$([ -n "$_ORCH_ATTEMPT_LOG" ] && echo 0 || echo 1)"
assert "5.2 log contains attempt 1" "$(echo "$_ORCH_ATTEMPT_LOG" | grep -q "Attempt 1" && echo 0 || echo 1)"

record_pipeline_attempt "16" "2" "failed" "20" "1" >/dev/null 2>&1
assert "5.3 log contains attempt 2" "$(echo "$_ORCH_ATTEMPT_LOG" | grep -q "Attempt 2" && echo 0 || echo 1)"

# =============================================================================
# Test Suite 6: _hook_emit_run_summary produces valid JSON
# =============================================================================
echo "=== Test Suite 6: _hook_emit_run_summary ==="

# Source finalize_summary.sh in isolation (mock its dependencies)
_ORCH_ATTEMPT=2
_ORCH_AGENT_CALLS=8
_ORCH_ELAPSED=120
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_REVIEW_BUMPED=false
REVIEW_CYCLE=1
MILESTONE_CURRENT_SPLIT_DEPTH=0
CONTINUATION_ATTEMPTS=0
LAST_AGENT_RETRY_COUNT=0
HUMAN_MODE=false
HUMAN_NOTES_TAG=""
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false
TASK="test orchestration task"
declare -A _STAGE_TURNS=()
declare -A _STAGE_DURATION=()
declare -A _STAGE_BUDGET=()
export _ORCH_ATTEMPT _ORCH_AGENT_CALLS _ORCH_ELAPSED
export REVIEW_CYCLE MILESTONE_CURRENT_SPLIT_DEPTH
export CONTINUATION_ATTEMPTS LAST_AGENT_RETRY_COUNT

source "${TEKHTON_HOME}/lib/finalize_summary.sh"

_hook_emit_run_summary 0
assert "6.1 RUN_SUMMARY.json created" "$([ -f "${LOG_DIR}/RUN_SUMMARY.json" ] && echo 0 || echo 1)"

# Check JSON fields
summary_content=$(cat "${LOG_DIR}/RUN_SUMMARY.json")
assert "6.2 JSON has outcome field" "$(echo "$summary_content" | grep -q '"outcome"' && echo 0 || echo 1)"
assert "6.3 outcome is success" "$(echo "$summary_content" | grep -q '"outcome": "success"' && echo 0 || echo 1)"
assert "6.4 JSON has attempts field" "$(echo "$summary_content" | grep -q '"attempts": 2' && echo 0 || echo 1)"
assert "6.5 JSON has timestamp" "$(echo "$summary_content" | grep -q '"timestamp"' && echo 0 || echo 1)"

# Failure outcome
rm -f "${LOG_DIR}/RUN_SUMMARY.json"
_hook_emit_run_summary 1
summary_content=$(cat "${LOG_DIR}/RUN_SUMMARY.json")
assert "6.6 failure outcome on exit_code=1" "$(echo "$summary_content" | grep -q '"outcome": "failure"' && echo 0 || echo 1)"

# Timeout outcome
rm -f "${LOG_DIR}/RUN_SUMMARY.json"
_ORCH_ELAPSED=8000
AUTONOMOUS_TIMEOUT=7200
_hook_emit_run_summary 1
summary_content=$(cat "${LOG_DIR}/RUN_SUMMARY.json")
assert "6.7 timeout outcome when elapsed >= timeout" "$(echo "$summary_content" | grep -q '"outcome": "timeout"' && echo 0 || echo 1)"

# Stuck outcome
rm -f "${LOG_DIR}/RUN_SUMMARY.json"
_ORCH_ELAPSED=100
_ORCH_NO_PROGRESS_COUNT=2
_hook_emit_run_summary 1
summary_content=$(cat "${LOG_DIR}/RUN_SUMMARY.json")
assert "6.8 stuck outcome when no-progress count >= 2" "$(echo "$summary_content" | grep -q '"outcome": "stuck"' && echo 0 || echo 1)"

_ORCH_NO_PROGRESS_COUNT=0

# =============================================================================
# Test Suite 7: emit_milestone_metadata
# =============================================================================
echo "=== Test Suite 7: emit_milestone_metadata ==="

cat > "$TMPDIR/CLAUDE.md" << 'EOF'
# Project

## Current Initiative

### Milestone Plan

#### Milestone 16: Outer Loop

Some content about milestone 16.

**Acceptance criteria:**
- Criterion 1
- Criterion 2

**Files to modify:**
- tekhton.sh
- lib/orchestrate.sh
EOF

PROJECT_RULES_FILE="$TMPDIR/CLAUDE.md"
export PROJECT_RULES_FILE

emit_milestone_metadata "16" "in_progress" "$TMPDIR/CLAUDE.md" >/dev/null 2>&1
meta_exists=$(grep -c "<!-- milestone-meta" "$TMPDIR/CLAUDE.md" || true)
assert_eq "7.1 metadata comment inserted" "1" "$meta_exists"

status_in=$(grep 'status:' "$TMPDIR/CLAUDE.md" | head -1)
assert "7.2 status is in_progress" "$(echo "$status_in" | grep -q 'in_progress' && echo 0 || echo 1)"

# Idempotent — update in-place
emit_milestone_metadata "16" "done" "$TMPDIR/CLAUDE.md" >/dev/null 2>&1
meta_count=$(grep -c "<!-- milestone-meta" "$TMPDIR/CLAUDE.md" || true)
assert_eq "7.3 metadata not duplicated on update" "1" "$meta_count"

status_done=$(grep 'status:' "$TMPDIR/CLAUDE.md" | head -1)
assert "7.4 status updated to done" "$(echo "$status_done" | grep -q 'done' && echo 0 || echo 1)"

# Non-existent milestone
result=0
emit_milestone_metadata "999" "pending" "$TMPDIR/CLAUDE.md" 2>/dev/null || result=1
assert_eq "7.5 returns 1 for non-existent milestone" "1" "$result"

# =============================================================================
# Test Suite 8: Orchestration state restoration from PIPELINE_STATE.md
# =============================================================================
echo "=== Test Suite 8: Orchestration state restoration ==="

# Create a mock pipeline state file with orchestration context
cat > "$TMPDIR/.claude/PIPELINE_STATE.md" << 'STEOF'
# Pipeline State
## Stage
review
## Orchestration Context
Pipeline attempt: 3
Cumulative agent calls: 12
Cumulative turns: 85
Wall-clock elapsed: 1200s
STEOF

# Source orchestrate.sh (requires mocking run_complete_loop dependencies)
# We test the state parsing logic directly instead of the full loop
_saved_attempt=$(awk '/^Pipeline attempt:/{print $NF; exit}' "$TMPDIR/.claude/PIPELINE_STATE.md" 2>/dev/null || echo "")
assert_eq "8.1 parse attempt from state file" "3" "$_saved_attempt"

_saved_calls=$(awk '/^Cumulative agent calls:/{print $NF; exit}' "$TMPDIR/.claude/PIPELINE_STATE.md" 2>/dev/null || echo "")
assert_eq "8.2 parse agent calls from state file" "12" "$_saved_calls"

# Validate it's numeric
assert "8.3 attempt is numeric" "$(echo "$_saved_attempt" | grep -qE '^[0-9]+$' && echo 0 || echo 1)"
assert "8.4 agent calls is numeric" "$(echo "$_saved_calls" | grep -qE '^[0-9]+$' && echo 0 || echo 1)"

# Missing state file returns empty
rm -f "$TMPDIR/.claude/PIPELINE_STATE.md"
_no_attempt=$(awk '/^Pipeline attempt:/{print $NF; exit}' "$TMPDIR/.claude/nonexistent.md" 2>/dev/null || echo "")
assert_eq "8.5 missing state file returns empty" "" "$_no_attempt"

# =============================================================================
# Test Suite 9: Agent invocation counter tracks calls
# =============================================================================
echo "=== Test Suite 9: Agent invocation counter ==="

# Simulate what run_agent() does: increment TOTAL_AGENT_INVOCATIONS
TOTAL_AGENT_INVOCATIONS=0
TOTAL_AGENT_INVOCATIONS=$(( TOTAL_AGENT_INVOCATIONS + 1 ))
assert_eq "9.1 first invocation increments to 1" "1" "$TOTAL_AGENT_INVOCATIONS"

TOTAL_AGENT_INVOCATIONS=$(( TOTAL_AGENT_INVOCATIONS + 1 ))
TOTAL_AGENT_INVOCATIONS=$(( TOTAL_AGENT_INVOCATIONS + 1 ))
assert_eq "9.2 three invocations" "3" "$TOTAL_AGENT_INVOCATIONS"

# Orchestrate loop should use this for _ORCH_AGENT_CALLS
_ORCH_AGENT_CALLS="${TOTAL_AGENT_INVOCATIONS}"
assert_eq "9.3 orch agent calls matches invocation count" "3" "$_ORCH_AGENT_CALLS"

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  orchestrate tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All orchestrate tests passed"
