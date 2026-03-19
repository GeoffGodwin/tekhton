#!/usr/bin/env bash
# =============================================================================
# test_run_with_retry_loop.sh — Integration tests for _run_with_retry() loop
#
# Tests:
#   1. Permanent error: no retry, LAST_AGENT_RETRY_COUNT=0, _RWR_EXIT preserved
#   2. Transient error hits max retries: LAST_AGENT_RETRY_COUNT=MAX
#   3. Transient error resolves on 2nd attempt: LAST_AGENT_RETRY_COUNT=1, _RWR_EXIT=0
#   4. TRANSIENT_RETRY_ENABLED=false: no retry even for transient errors
#   5. Success on first try: LAST_AGENT_RETRY_COUNT=0, _RWR_EXIT=0
#   6. _RWR_TURNS reflects actual turn count from final invocation
#   7. UPSTREAM category set correctly by classify path when API error detected
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/agent_retry.sh"

# --- Test infrastructure ------------------------------------------------------

SESSION_DIR="${TMPDIR}/session"
mkdir -p "$SESSION_DIR"
EXIT_FILE="${SESSION_DIR}/agent_exit"
TURNS_FILE="${SESSION_DIR}/agent_last_turns"
PRERUN_MARKER="${SESSION_DIR}/prerun_marker"
LOG_FILE="${TMPDIR}/agent.log"
PROJECT_DIR="$TMPDIR"

touch "$PRERUN_MARKER" "$LOG_FILE"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "✓ $name"
    fi
}

# --- Config defaults -----------------------------------------------------------
TRANSIENT_RETRY_ENABLED=true
MAX_TRANSIENT_RETRIES=3
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=120
TEKHTON_TEST_MODE=1  # Suppress spinner in run_agent()

# --- Mock: sleep (fast tests, no actual delays) --------------------------------
SLEEP_TOTAL=0
sleep() { SLEEP_TOTAL=$(( SLEEP_TOTAL + "${1:-0}" )); }

# --- Mock: report_retry (noop) ------------------------------------------------
report_retry() { :; }

# --- Mock: _reset_monitoring_state (noop) -------------------------------------
_reset_monitoring_state() { :; }

# --- Mock: _IM_PERM_FLAGS (needed by _invoke_and_monitor stub) ----------------
_IM_PERM_FLAGS=()

# =============================================================================
# Shared mock control variables
# =============================================================================

_INVOKE_CALL_COUNT=0       # How many times _invoke_and_monitor was called
_MOCK_ALWAYS_EXIT=0        # Exit code returned by every invocation
_MOCK_ALWAYS_TURNS=5       # Turns reported by every invocation
_MOCK_FAIL_ON_FIRST=false  # When true: first call exits 1, subsequent exit 0
_MOCK_TRANSIENT=false      # Whether _classify_agent_exit marks error as transient
_API_ERROR_DETECTED=false  # Global used by _classify_agent_exit
_API_ERROR_TYPE=""

# Mock _invoke_and_monitor: simulates agent invocation by writing to files
# and setting _MONITOR_* globals. Behaviour controlled by _MOCK_* variables.
_invoke_and_monitor() {
    local _turns_file="${9}"

    _INVOKE_CALL_COUNT=$(( _INVOKE_CALL_COUNT + 1 ))

    if [[ "$_MOCK_FAIL_ON_FIRST" = true ]] && [[ "$_INVOKE_CALL_COUNT" -eq 1 ]]; then
        _MONITOR_EXIT_CODE=1
    else
        _MONITOR_EXIT_CODE="$_MOCK_ALWAYS_EXIT"
    fi
    _MONITOR_WAS_ACTIVITY_TIMEOUT=false

    echo "$_MOCK_ALWAYS_TURNS" > "$_turns_file"
}

# Mock _classify_agent_exit: sets AGENT_ERROR_* based on mock control vars.
# Avoids the real implementation which calls classify_error, _detect_file_changes, etc.
_classify_agent_exit() {
    local agent_exit="$1"

    if [[ "$agent_exit" -ne 0 ]] || [[ "$_API_ERROR_DETECTED" = true ]]; then
        AGENT_ERROR_TRANSIENT="$_MOCK_TRANSIENT"
        if [[ "$_MOCK_TRANSIENT" = true ]]; then
            AGENT_ERROR_CATEGORY="UPSTREAM"
            AGENT_ERROR_SUBCATEGORY="api_500"
            AGENT_ERROR_MESSAGE="HTTP 500 Server Error"
        else
            AGENT_ERROR_CATEGORY="AGENT_SCOPE"
            AGENT_ERROR_SUBCATEGORY="null_run"
            AGENT_ERROR_MESSAGE="Agent completed without meaningful work"
        fi
    else
        AGENT_ERROR_CATEGORY=""
        AGENT_ERROR_SUBCATEGORY=""
        AGENT_ERROR_TRANSIENT=""
        AGENT_ERROR_MESSAGE=""
    fi
}

# Helper: reset invocation state between test phases
reset_invoke_state() {
    _INVOKE_CALL_COUNT=0
    _MOCK_ALWAYS_EXIT=0
    _MOCK_ALWAYS_TURNS=5
    _MOCK_FAIL_ON_FIRST=false
    _MOCK_TRANSIENT=false
    _API_ERROR_DETECTED=false
    _API_ERROR_TYPE=""
    LAST_AGENT_RETRY_COUNT=0
    _RWR_EXIT=0
    _RWR_TURNS=0
    _RWR_WAS_ACTIVITY_TIMEOUT=false
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_TRANSIENT=""
    AGENT_ERROR_MESSAGE=""
    SLEEP_TOTAL=0
    touch "$EXIT_FILE" "$TURNS_FILE" "$PRERUN_MARKER"
}

# Helper: call _run_with_retry with standard test arguments
call_run_with_retry() {
    _run_with_retry "TestLabel" "" "claude-test" "10" "test prompt" \
        "$LOG_FILE" "600" "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE" \
        "$PRERUN_MARKER" "7200"
}

# =============================================================================
# Test 1: Permanent error — no retry, LAST_AGENT_RETRY_COUNT stays 0
# =============================================================================

reset_invoke_state
_MOCK_ALWAYS_EXIT=1
_MOCK_TRANSIENT=false  # permanent error

call_run_with_retry
assert_eq "1.1 permanent error: _RWR_EXIT is 1"               "1"     "$_RWR_EXIT"
assert_eq "1.2 permanent error: LAST_AGENT_RETRY_COUNT is 0"  "0"     "$LAST_AGENT_RETRY_COUNT"
assert_eq "1.3 permanent error: _invoke_and_monitor called once" "1"  "$_INVOKE_CALL_COUNT"
assert_eq "1.4 permanent error: no sleeping"                   "0"     "$SLEEP_TOTAL"
assert_eq "1.5 permanent error: AGENT_ERROR_CATEGORY = AGENT_SCOPE" \
          "AGENT_SCOPE" "$AGENT_ERROR_CATEGORY"

# =============================================================================
# Test 2: Transient error hits MAX_TRANSIENT_RETRIES — retries N times then stops
# =============================================================================

reset_invoke_state
_MOCK_ALWAYS_EXIT=1
_MOCK_TRANSIENT=true
MAX_TRANSIENT_RETRIES=2
TRANSIENT_RETRY_BASE_DELAY=1  # tiny delays for test speed

call_run_with_retry
assert_eq "2.1 exhausted retries: _RWR_EXIT is 1"              "1"  "$_RWR_EXIT"
assert_eq "2.2 exhausted retries: LAST_AGENT_RETRY_COUNT = 2"  "2"  "$LAST_AGENT_RETRY_COUNT"
# Total invocations = initial + 2 retries = 3
assert_eq "2.3 exhausted retries: _invoke called 3 times"      "3"  "$_INVOKE_CALL_COUNT"
assert_eq "2.4 exhausted retries: AGENT_ERROR_CATEGORY = UPSTREAM" \
          "UPSTREAM" "$AGENT_ERROR_CATEGORY"

MAX_TRANSIENT_RETRIES=3  # restore
TRANSIENT_RETRY_BASE_DELAY=30

# =============================================================================
# Test 3: Transient error resolves on 2nd attempt
# =============================================================================

reset_invoke_state
_MOCK_FAIL_ON_FIRST=true   # first call exits 1, subsequent exit 0
_MOCK_TRANSIENT=true       # first call classified as transient
TRANSIENT_RETRY_BASE_DELAY=1  # fast

# After first retry, _MOCK_FAIL_ON_FIRST causes 2nd call to succeed.
# But _classify_agent_exit checks exit code: on success, sets AGENT_ERROR_TRANSIENT="".
# _should_retry_transient checks AGENT_ERROR_TRANSIENT != "true" → stops.
call_run_with_retry
assert_eq "3.1 resolved on retry: _RWR_EXIT is 0"            "0"  "$_RWR_EXIT"
assert_eq "3.2 resolved on retry: LAST_AGENT_RETRY_COUNT = 1" "1"  "$LAST_AGENT_RETRY_COUNT"
assert_eq "3.3 resolved on retry: _invoke called twice"       "2"  "$_INVOKE_CALL_COUNT"

TRANSIENT_RETRY_BASE_DELAY=30  # restore

# =============================================================================
# Test 4: TRANSIENT_RETRY_ENABLED=false — no retry even on transient errors
# =============================================================================

reset_invoke_state
_MOCK_ALWAYS_EXIT=1
_MOCK_TRANSIENT=true
TRANSIENT_RETRY_ENABLED=false

call_run_with_retry
assert_eq "4.1 disabled: _RWR_EXIT is 1"                     "1"  "$_RWR_EXIT"
assert_eq "4.2 disabled: LAST_AGENT_RETRY_COUNT = 0"          "0"  "$LAST_AGENT_RETRY_COUNT"
assert_eq "4.3 disabled: _invoke called only once"            "1"  "$_INVOKE_CALL_COUNT"
assert_eq "4.4 disabled: no sleeping"                         "0"  "$SLEEP_TOTAL"

TRANSIENT_RETRY_ENABLED=true  # restore

# =============================================================================
# Test 5: Success on first try — no retry needed
# =============================================================================

reset_invoke_state
_MOCK_ALWAYS_EXIT=0
_MOCK_TRANSIENT=false

call_run_with_retry
assert_eq "5.1 success first try: _RWR_EXIT is 0"            "0"  "$_RWR_EXIT"
assert_eq "5.2 success first try: LAST_AGENT_RETRY_COUNT = 0" "0"  "$LAST_AGENT_RETRY_COUNT"
assert_eq "5.3 success first try: _invoke called once"        "1"  "$_INVOKE_CALL_COUNT"
assert_eq "5.4 success first try: no sleeping"                "0"  "$SLEEP_TOTAL"
assert_eq "5.5 success first try: AGENT_ERROR_CATEGORY empty" ""   "$AGENT_ERROR_CATEGORY"

# =============================================================================
# Test 6: _RWR_TURNS reflects turn count from the turns_file
# =============================================================================

reset_invoke_state
_MOCK_ALWAYS_EXIT=0
_MOCK_ALWAYS_TURNS=42

call_run_with_retry
assert_eq "6.1 _RWR_TURNS reflects turns file value" "42" "$_RWR_TURNS"

# =============================================================================
# Test 7: Retry count of 3 with base_delay=30 → sleep was called 3 times
# (total sleep = 30+60+120 = 210 with exponential backoff)
# =============================================================================

reset_invoke_state
_MOCK_ALWAYS_EXIT=1
_MOCK_TRANSIENT=true
MAX_TRANSIENT_RETRIES=3
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=120
AGENT_ERROR_SUBCATEGORY=api_500  # needed for subcategory-specific logic in real _should_retry_transient

call_run_with_retry
# Delay schedule: attempt 0→30, 1→60, 2→120 = total 210
assert_eq "7.1 retry x3: total sleep = 30+60+120 = 210" "210" "$SLEEP_TOTAL"
assert_eq "7.2 retry x3: LAST_AGENT_RETRY_COUNT = 3"    "3"   "$LAST_AGENT_RETRY_COUNT"
# 4 invocations: original + 3 retries
assert_eq "7.3 retry x3: _invoke called 4 times"        "4"   "$_INVOKE_CALL_COUNT"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PASS"
