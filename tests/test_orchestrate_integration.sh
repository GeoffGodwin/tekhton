#!/usr/bin/env bash
# =============================================================================
# test_orchestrate_integration.sh — Integration test for run_complete_loop
#
# Covers the reviewer-identified gap: a wiring-level test that verifies
# finalize_run is called with exit 0 when the pipeline succeeds on attempt 2.
#
# Scenario:
#   - Attempt 1: _run_pipeline_stages fails with CHANGES_REQUIRED verdict
#                → bump_review recovery → loop continues
#   - Attempt 2: _run_pipeline_stages succeeds → finalize_run 0 called
#                → _ORCH_ATTEMPT = 2 at completion
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals --------------------------------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/logs"
LOG_FILE="$TMPDIR/test.log"
TASK="Test complete loop integration"
MILESTONE_MODE=false
_CURRENT_MILESTONE=""
PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"
TEKHTON_SESSION_DIR="$TMPDIR"
AUTONOMOUS_TIMEOUT=7200
MAX_PIPELINE_ATTEMPTS=5
MAX_AUTONOMOUS_AGENT_CALLS=20
AUTONOMOUS_PROGRESS_CHECK=true
TOTAL_TURNS=0
TOTAL_AGENT_INVOCATIONS=0
VERDICT=""
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
START_AT="coder"
TIMESTAMP="20260320_120000"
MAX_REVIEW_CYCLES=3
SKIP_FINAL_CHECKS=false
TEST_CMD="true"         # neutralize pre-finalization test gate (runs in tmpdir with no project)
USAGE_THRESHOLD_PCT=0   # disable usage threshold check (no claude binary needed)
REVIEW_CYCLE=0
MILESTONE_CURRENT_SPLIT_DEPTH=0
CONTINUATION_ATTEMPTS=0
LAST_AGENT_RETRY_COUNT=0

export PROJECT_DIR LOG_DIR LOG_FILE TASK MILESTONE_MODE _CURRENT_MILESTONE
export PIPELINE_STATE_FILE TEKHTON_SESSION_DIR
export AUTONOMOUS_TIMEOUT MAX_PIPELINE_ATTEMPTS MAX_AUTONOMOUS_AGENT_CALLS
export AUTONOMOUS_PROGRESS_CHECK TOTAL_TURNS TOTAL_AGENT_INVOCATIONS VERDICT
export AGENT_ERROR_CATEGORY AGENT_ERROR_SUBCATEGORY START_AT TIMESTAMP
export MAX_REVIEW_CYCLES SKIP_FINAL_CHECKS TEST_CMD USAGE_THRESHOLD_PCT
export REVIEW_CYCLE MILESTONE_CURRENT_SPLIT_DEPTH CONTINUATION_ATTEMPTS
export LAST_AGENT_RETRY_COUNT

mkdir -p "$LOG_DIR" "$TMPDIR/.claude"
touch "$LOG_FILE"
cd "$TMPDIR"
git init -q .
git commit -q -m "init" --allow-empty 2>/dev/null

# --- Mock external dependencies BEFORE sourcing orchestrate.sh ---------------

# Capture what finalize_run was called with
_FINALIZE_RUN_CALLED=false
_FINALIZE_RUN_EXIT=-1
finalize_run() {
    _FINALIZE_RUN_CALLED=true
    _FINALIZE_RUN_EXIT="$1"
}

# write_pipeline_state — called by _save_orchestration_state on error paths
write_pipeline_state() { :; }

# write_milestone_disposition — called on success/failure in milestone mode
write_milestone_disposition() { :; }

# check_milestone_acceptance — only called when MILESTONE_MODE=true (not our test)
check_milestone_acceptance() { return 0; }

# find_next_milestone — only called on success in milestone mode
find_next_milestone() { echo ""; }

# should_auto_advance — prevent auto-advance chain
should_auto_advance() { return 1; }

# record_pipeline_attempt — use real implementation (just updates _ORCH_ATTEMPT_LOG)
# We source milestone_metadata.sh below so this is provided.

# --- Source dependencies in correct order ------------------------------------

source "${TEKHTON_HOME}/lib/common.sh"

# Provide record_pipeline_attempt and emit_milestone_metadata
source "${TEKHTON_HOME}/lib/milestone_metadata.sh"

# Source orchestrate.sh (which sources orchestrate_recovery.sh and
# orchestrate_helpers.sh internally)
source "${TEKHTON_HOME}/lib/orchestrate.sh"

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
# Test Suite 1: run_complete_loop round trip — pipeline succeeds on attempt 2
# =============================================================================
echo "=== Integration Test Suite 1: run_complete_loop round trip ==="

# Controlled _run_pipeline_stages: fails first call, succeeds second
_PIPELINE_CALL_COUNT=0
_run_pipeline_stages() {
    _PIPELINE_CALL_COUNT=$(( _PIPELINE_CALL_COUNT + 1 ))
    if [[ "$_PIPELINE_CALL_COUNT" -eq 1 ]]; then
        # First call: fail with CHANGES_REQUIRED to trigger bump_review recovery
        VERDICT="CHANGES_REQUIRED"
        AGENT_ERROR_CATEGORY=""
        AGENT_ERROR_SUBCATEGORY=""
        return 1
    fi
    # Second call: succeed
    VERDICT=""
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    return 0
}

# Reset orchestration state from any prior tests
_ORCH_ATTEMPT=0
_ORCH_AGENT_CALLS=0
_ORCH_ELAPSED=0
_ORCH_ATTEMPT_LOG=""
_ORCH_REVIEW_BUMPED=false
_ORCH_LAST_DIFF_HASH=""
_ORCH_NO_PROGRESS_COUNT=0
_FINALIZE_RUN_CALLED=false
_FINALIZE_RUN_EXIT=-1

loop_exit=0
run_complete_loop || loop_exit=$?

assert_eq "1.1 run_complete_loop returns 0 on success" "0" "$loop_exit"
assert_eq "1.2 _run_pipeline_stages called twice (attempt 1 fail, attempt 2 succeed)" "2" "$_PIPELINE_CALL_COUNT"
assert_eq "1.3 _ORCH_ATTEMPT is 2 at completion" "2" "$_ORCH_ATTEMPT"
assert "1.4 finalize_run was called" "$([ "$_FINALIZE_RUN_CALLED" = true ] && echo 0 || echo 1)"
assert_eq "1.5 finalize_run called with exit code 0 (success)" "0" "$_FINALIZE_RUN_EXIT"
assert "1.6 _ORCH_REVIEW_BUMPED is true (review was bumped on attempt 1)" \
    "$([ "$_ORCH_REVIEW_BUMPED" = true ] && echo 0 || echo 1)"

# =============================================================================
# Test Suite 2: max-attempts safety bound exits before acceptance
# =============================================================================
echo "=== Integration Test Suite 2: MAX_PIPELINE_ATTEMPTS safety bound ==="

_PIPELINE_CALL_COUNT=0
_FINALIZE_RUN_CALLED=false
_FINALIZE_RUN_EXIT=-1

# Always fail — loop should exit after MAX_PIPELINE_ATTEMPTS
_run_pipeline_stages() {
    _PIPELINE_CALL_COUNT=$(( _PIPELINE_CALL_COUNT + 1 ))
    VERDICT="CHANGES_REQUIRED"
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    return 1
}

_ORCH_ATTEMPT=0
_ORCH_AGENT_CALLS=0
_ORCH_ELAPSED=0
_ORCH_ATTEMPT_LOG=""
_ORCH_REVIEW_BUMPED=false
_ORCH_LAST_DIFF_HASH=""
_ORCH_NO_PROGRESS_COUNT=0
MAX_PIPELINE_ATTEMPTS=3

loop_exit=0
run_complete_loop || loop_exit=$?

assert_eq "2.1 run_complete_loop returns 1 when max attempts exhausted" "1" "$loop_exit"
assert "2.2 finalize_run called on failure path" \
    "$([ "$_FINALIZE_RUN_CALLED" = true ] && echo 0 || echo 1)"
assert_eq "2.3 finalize_run called with exit code 1 (failure)" "1" "$_FINALIZE_RUN_EXIT"

# Restore
MAX_PIPELINE_ATTEMPTS=5

# =============================================================================
# Test Suite 3: wall-clock timeout exits immediately
# =============================================================================
echo "=== Integration Test Suite 3: AUTONOMOUS_TIMEOUT wall-clock kill switch ==="

_PIPELINE_CALL_COUNT=0
_FINALIZE_RUN_CALLED=false
_FINALIZE_RUN_EXIT=-1

_run_pipeline_stages() {
    _PIPELINE_CALL_COUNT=$(( _PIPELINE_CALL_COUNT + 1 ))
    return 0
}

_ORCH_ATTEMPT=0
_ORCH_AGENT_CALLS=0
_ORCH_ELAPSED=0
_ORCH_ATTEMPT_LOG=""
_ORCH_REVIEW_BUMPED=false
_ORCH_LAST_DIFF_HASH=""
_ORCH_NO_PROGRESS_COUNT=0
# AUTONOMOUS_TIMEOUT=0 means elapsed(0) >= timeout(0) → fires immediately at
# the top of the first loop iteration, before _run_pipeline_stages is called.
AUTONOMOUS_TIMEOUT=0

loop_exit=0
run_complete_loop || loop_exit=$?

assert_eq "3.1 run_complete_loop returns 1 on timeout" "1" "$loop_exit"
assert_eq "3.2 _run_pipeline_stages not called after timeout" "0" "$_PIPELINE_CALL_COUNT"
assert "3.3 finalize_run called on timeout path" \
    "$([ "$_FINALIZE_RUN_CALLED" = true ] && echo 0 || echo 1)"

# Restore
AUTONOMOUS_TIMEOUT=7200

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  orchestrate_integration: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All orchestrate integration tests passed"
