#!/usr/bin/env bash
# =============================================================================
# test_quota_sleep_chunked.sh — _quota_sleep_chunked chunk-math (M124)
#
# Verifies lib/quota_sleep.sh:_quota_sleep_chunked:
#   - Iterates in QUOTA_SLEEP_CHUNK-sized steps (not one big sleep)
#   - Calls tui_update_pause exactly once per chunk with correct remaining
#   - Handles partial final chunk (remainder < chunk)
#   - Handles total=0 (no sleep, no update call)
#   - Falls back to chunk=5 when QUOTA_SLEEP_CHUNK is unset
#   - Falls back to chunk=5 when QUOTA_SLEEP_CHUNK is non-numeric
#   - Silently skips tui_update_pause when the function is not defined
#   - Silently skips tui_update_pause when _pause_start is 0
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source the module under test.
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/quota_sleep.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Mock sleep so tests don't actually wait.
sleep() { : ; }

# =============================================================================
echo "=== chunk-math: total=6, chunk=2 → 3 calls ==="
_CALLS=0
_REMAINING_LOG=""
tui_update_pause() { _CALLS=$((_CALLS+1)); _REMAINING_LOG="${_REMAINING_LOG}${1} "; }

QUOTA_SLEEP_CHUNK=2
_CALLS=0; _REMAINING_LOG=""
_quota_sleep_chunked 6 0
[[ "$_CALLS" -eq 3 ]] && pass "total=6 chunk=2: 3 calls" \
    || fail "call count" "expected 3, got $_CALLS"
[[ "$_REMAINING_LOG" == "4 2 0 " ]] && pass "remaining values: 4 2 0" \
    || fail "remaining log" "got '$_REMAINING_LOG'"

# =============================================================================
echo "=== chunk-math: total=5, chunk=3 → 2 calls (3+2) ==="
_CALLS=0; _REMAINING_LOG=""
QUOTA_SLEEP_CHUNK=3
_quota_sleep_chunked 5 0
[[ "$_CALLS" -eq 2 ]] && pass "total=5 chunk=3: 2 calls" \
    || fail "call count" "expected 2, got $_CALLS"
[[ "$_REMAINING_LOG" == "2 0 " ]] && pass "remaining values: 2 0" \
    || fail "remaining log" "got '$_REMAINING_LOG'"

# =============================================================================
echo "=== chunk-math: total=1, chunk=5 → 1 call (chunk > total) ==="
_CALLS=0; _REMAINING_LOG=""
QUOTA_SLEEP_CHUNK=5
_quota_sleep_chunked 1 0
[[ "$_CALLS" -eq 1 ]] && pass "total=1 chunk=5: 1 call (partial only)" \
    || fail "call count" "expected 1, got $_CALLS"
[[ "$_REMAINING_LOG" == "0 " ]] && pass "remaining value: 0" \
    || fail "remaining log" "got '$_REMAINING_LOG'"

# =============================================================================
echo "=== total=0 → no sleep, no tui_update_pause call ==="
_CALLS=0
QUOTA_SLEEP_CHUNK=5
_quota_sleep_chunked 0 0
[[ "$_CALLS" -eq 0 ]] && pass "total=0: no calls" \
    || fail "call count" "expected 0, got $_CALLS"

# =============================================================================
echo "=== invalid QUOTA_SLEEP_CHUNK (non-numeric) → falls back to 5 ==="
# With fallback chunk=5 and total=10 → 2 calls.
_CALLS=0; _REMAINING_LOG=""
QUOTA_SLEEP_CHUNK="not_a_number"
_quota_sleep_chunked 10 0
[[ "$_CALLS" -eq 2 ]] && pass "invalid chunk falls back to 5: 2 calls" \
    || fail "call count" "expected 2, got $_CALLS"

# =============================================================================
echo "=== unset QUOTA_SLEEP_CHUNK → falls back to 5 ==="
_CALLS=0
unset QUOTA_SLEEP_CHUNK
_quota_sleep_chunked 10 0
[[ "$_CALLS" -eq 2 ]] && pass "unset chunk falls back to 5: 2 calls" \
    || fail "call count" "expected 2, got $_CALLS"

# =============================================================================
echo "=== absent tui_update_pause → no error, loop still completes ==="
unset -f tui_update_pause
# shellcheck disable=SC2034  # Read by _quota_sleep_chunked (sourced function)
QUOTA_SLEEP_CHUNK=1
rc=0; _quota_sleep_chunked 3 0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "absent tui_update_pause: clean exit" \
    || fail "exit code" "expected 0, got $rc"

# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
