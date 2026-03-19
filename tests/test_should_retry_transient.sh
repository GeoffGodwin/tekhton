#!/usr/bin/env bash
# =============================================================================
# test_should_retry_transient.sh — Unit tests for _should_retry_transient()
#
# Tests:
#   1. TRANSIENT_RETRY_ENABLED=false → no retry, no sleep
#   2. AGENT_ERROR_TRANSIENT != "true" → no retry, no sleep
#   3. retry_attempt >= MAX_TRANSIENT_RETRIES → no retry, no sleep
#   4. Exponential backoff: attempt 0→30s, 1→60s, 2→120s
#   5. TRANSIENT_RETRY_MAX_DELAY cap
#   6. OOM subcategory uses exponential backoff with 15s floor
#   7. api_rate_limit enforces 60s minimum
#   8. api_overloaded enforces 60s minimum
#   9. retry-after header overrides delay when larger
#  10. retry-after smaller than minimum uses minimum
#  11. _reset_monitoring_state called on each retry
#  12. returns 0 (retry) for valid transient error under max
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"

# --- Mocks (override before sourcing so they take precedence after) -----------

SLEEP_ARG=""
SLEEP_CALL_COUNT=0
sleep() {
    SLEEP_CALL_COUNT=$(( SLEEP_CALL_COUNT + 1 ))
    SLEEP_ARG="$1"
}

REPORT_RETRY_CALL_COUNT=0
report_retry() {
    REPORT_RETRY_CALL_COUNT=$(( REPORT_RETRY_CALL_COUNT + 1 ))
}

RESET_MONITORING_CALL_COUNT=0
_reset_monitoring_state() {
    RESET_MONITORING_CALL_COUNT=$(( RESET_MONITORING_CALL_COUNT + 1 ))
}

source "${TEKHTON_HOME}/lib/agent_retry.sh"

# --- Test state --------------------------------------------------------------

SESSION_DIR="${TMPDIR}/session"
mkdir -p "$SESSION_DIR"
EXIT_FILE="${SESSION_DIR}/agent_exit"
TURNS_FILE="${SESSION_DIR}/agent_last_turns"

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

assert_returns_false() {
    local name="$1"; shift
    if "$@" 2>/dev/null; then
        echo "FAIL: $name — expected false (return 1), got true (return 0)"
        FAIL=1
    else
        echo "✓ $name"
    fi
}

assert_returns_true() {
    local name="$1"; shift
    if "$@" 2>/dev/null; then
        echo "✓ $name"
    else
        echo "FAIL: $name — expected true (return 0), got false (return 1)"
        FAIL=1
    fi
}

# Helper: reset temp files and counters between tests
reset_state() {
    touch "$EXIT_FILE" "$TURNS_FILE"
    SLEEP_ARG=""
    SLEEP_CALL_COUNT=0
    REPORT_RETRY_CALL_COUNT=0
    RESET_MONITORING_CALL_COUNT=0
    rm -f "${SESSION_DIR}/agent_last_output.txt"
}

# --- Baseline config ---------------------------------------------------------
TRANSIENT_RETRY_ENABLED=true
AGENT_ERROR_TRANSIENT=true
MAX_TRANSIENT_RETRIES=3
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=120
AGENT_ERROR_SUBCATEGORY=api_500

# =============================================================================
# Test 1: TRANSIENT_RETRY_ENABLED=false → no retry
# =============================================================================

reset_state
TRANSIENT_RETRY_ENABLED=false
assert_returns_false "1.1 no retry when TRANSIENT_RETRY_ENABLED=false" \
    _should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "1.2 sleep not called when disabled" "0" "$SLEEP_CALL_COUNT"

# restore
TRANSIENT_RETRY_ENABLED=true

# =============================================================================
# Test 2: AGENT_ERROR_TRANSIENT != "true" → no retry
# =============================================================================

reset_state
AGENT_ERROR_TRANSIENT=false
assert_returns_false "2.1 no retry when error is permanent (false)" \
    _should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "2.2 sleep not called for permanent error" "0" "$SLEEP_CALL_COUNT"

reset_state
AGENT_ERROR_TRANSIENT=""
assert_returns_false "2.3 no retry when AGENT_ERROR_TRANSIENT is empty" \
    _should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"

# restore
AGENT_ERROR_TRANSIENT=true

# =============================================================================
# Test 3: retry_attempt >= MAX_TRANSIENT_RETRIES → no retry
# =============================================================================

reset_state
# attempt equals max → no retry
assert_returns_false "3.1 no retry when attempt equals MAX_TRANSIENT_RETRIES" \
    _should_retry_transient "label" 3 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "3.2 sleep not called at exhausted retries" "0" "$SLEEP_CALL_COUNT"

reset_state
# attempt exceeds max → no retry
assert_returns_false "3.3 no retry when attempt exceeds MAX_TRANSIENT_RETRIES" \
    _should_retry_transient "label" 5 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"

# =============================================================================
# Test 4: Exponential backoff delays
# attempt N → next_attempt = N+1 → delay = base * 2^(N+1-1) = base * 2^N
# attempt 0 → delay = 30 * 2^0 = 30
# attempt 1 → delay = 30 * 2^1 = 60
# attempt 2 → delay = 30 * 2^2 = 120
# =============================================================================

AGENT_ERROR_SUBCATEGORY=api_500
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=300  # high cap so we see raw backoff

reset_state
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "4.1 attempt 0 → 30s delay" "30" "$SLEEP_ARG"

reset_state
_should_retry_transient "label" 1 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "4.2 attempt 1 → 60s delay" "60" "$SLEEP_ARG"

reset_state
_should_retry_transient "label" 2 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "4.3 attempt 2 → 120s delay" "120" "$SLEEP_ARG"

# =============================================================================
# Test 5: TRANSIENT_RETRY_MAX_DELAY cap
# =============================================================================

TRANSIENT_RETRY_MAX_DELAY=60
AGENT_ERROR_SUBCATEGORY=api_500

# attempt 1 → 60, at cap → 60 (no change)
reset_state
_should_retry_transient "label" 1 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "5.1 delay at cap is exactly max" "60" "$SLEEP_ARG"

# attempt 2 → 120, exceeds cap of 60 → capped at 60
reset_state
_should_retry_transient "label" 2 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "5.2 delay capped at TRANSIENT_RETRY_MAX_DELAY (60)" "60" "$SLEEP_ARG"

# restore
TRANSIENT_RETRY_MAX_DELAY=120

# =============================================================================
# Test 6: OOM subcategory uses exponential backoff with 15s floor
# =============================================================================

AGENT_ERROR_SUBCATEGORY=oom
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=120

# attempt 0 → calculated 30, OOM floor 15 → 30 (already above floor)
reset_state
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "6.1 OOM at attempt 0: backoff 30s (above 15s floor)" "30" "$SLEEP_ARG"

# attempt 1 → calculated 60, OOM floor 15 → 60
reset_state
_should_retry_transient "label" 1 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "6.2 OOM at attempt 1: backoff 60s (above 15s floor)" "60" "$SLEEP_ARG"

# attempt 2 → calculated 120, OOM floor 15 → 120
reset_state
_should_retry_transient "label" 2 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "6.3 OOM at attempt 2: backoff 120s (above 15s floor)" "120" "$SLEEP_ARG"

# =============================================================================
# Test 7: api_rate_limit enforces 60s minimum
# =============================================================================

AGENT_ERROR_SUBCATEGORY=api_rate_limit
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=300

# attempt 0 → calculated 30, min is 60
reset_state
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "7.1 api_rate_limit enforces 60s minimum (attempt 0 → was 30)" "60" "$SLEEP_ARG"

# attempt 1 → calculated 60, already at minimum
reset_state
_should_retry_transient "label" 1 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "7.2 api_rate_limit at 60s stays 60s" "60" "$SLEEP_ARG"

# attempt 2 → calculated 120, above minimum — use calculated
reset_state
_should_retry_transient "label" 2 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "7.3 api_rate_limit at 120s uses 120s (above minimum)" "120" "$SLEEP_ARG"

# =============================================================================
# Test 8: api_overloaded enforces 60s minimum
# =============================================================================

AGENT_ERROR_SUBCATEGORY=api_overloaded
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=300

reset_state
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "8.1 api_overloaded enforces 60s minimum (attempt 0 → was 30)" "60" "$SLEEP_ARG"

reset_state
_should_retry_transient "label" 2 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "8.2 api_overloaded at 120s uses 120s" "120" "$SLEEP_ARG"

# =============================================================================
# Test 9: retry-after header overrides delay when larger
# =============================================================================

AGENT_ERROR_SUBCATEGORY=api_rate_limit
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=300

# retry-after=90 > calculated 30 and > minimum 60 → use 90
reset_state
cat > "${SESSION_DIR}/agent_last_output.txt" << 'EOEOF'
{"error":{"type":"rate_limit_error"},"retry-after":"90"}
EOEOF
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "9.1 retry-after 90 overrides calculated 30 and minimum 60" "90" "$SLEEP_ARG"

# retry-after=10 < minimum 60 → use minimum 60
reset_state
cat > "${SESSION_DIR}/agent_last_output.txt" << 'EOEOF'
{"error":{"type":"rate_limit_error"},"retry-after":"10"}
EOEOF
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "9.2 retry-after 10 < minimum 60 → uses minimum 60" "60" "$SLEEP_ARG"

rm -f "${SESSION_DIR}/agent_last_output.txt"

# =============================================================================
# Test 10: retry-after larger than calculated but no file — uses minimum
# =============================================================================

AGENT_ERROR_SUBCATEGORY=api_rate_limit
rm -f "${SESSION_DIR}/agent_last_output.txt"

reset_state
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "10.1 no last_output file → minimum 60s for rate_limit" "60" "$SLEEP_ARG"

# =============================================================================
# Test 11: _reset_monitoring_state called on successful retry decision
# =============================================================================

AGENT_ERROR_SUBCATEGORY=api_500
TRANSIENT_RETRY_BASE_DELAY=30
TRANSIENT_RETRY_MAX_DELAY=120

reset_state
_should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "11.1 _reset_monitoring_state called once per retry" "1" "$RESET_MONITORING_CALL_COUNT"

reset_state
_should_retry_transient "label" 1 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"
assert_eq "11.2 _reset_monitoring_state called again on next retry" "1" "$RESET_MONITORING_CALL_COUNT"

# =============================================================================
# Test 12: returns 0 (true) for valid transient error under max retries
# =============================================================================

AGENT_ERROR_SUBCATEGORY=api_500
TRANSIENT_RETRY_ENABLED=true
AGENT_ERROR_TRANSIENT=true
MAX_TRANSIENT_RETRIES=3

reset_state
assert_returns_true "12.1 returns true for transient error at attempt 0" \
    _should_retry_transient "label" 0 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"

reset_state
assert_returns_true "12.2 returns true for transient error at attempt 2 (max-1)" \
    _should_retry_transient "label" 2 "$SESSION_DIR" "$EXIT_FILE" "$TURNS_FILE"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PASS"
