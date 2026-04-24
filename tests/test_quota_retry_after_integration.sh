#!/usr/bin/env bash
# =============================================================================
# test_quota_retry_after_integration.sh — End-to-end Retry-After → quota pause
#
# M125: verifies the full signal chain from a rate-limit error carrying a
# Retry-After header all the way through to the enter_quota_pause first-probe
# scheduling. Uses the internal helpers to drive the pause loop with a
# synthetic rate-limit payload (rather than a real claude invocation, which
# would require network + an exhausted quota). Focuses on the integration
# points:
#
#   1. _extract_retry_after_seconds lifts the value from agent_last_output.txt
#      written by a synthetic agent call.
#   2. enter_quota_pause receives that value as its second argument.
#   3. The first probe fires at ~retry_after seconds after pause entry (±2s).
#   4. _QUOTA_PAUSE_COUNT and _QUOTA_TOTAL_PAUSE_TIME record one pause.
#   5. get_quota_stats_json reports pause_count=1 and a coherent total.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/logs"
LOG_FILE="$TMPDIR/test.log"
TEKHTON_SESSION_DIR="$TMPDIR/session"
AUTONOMOUS_TIMEOUT=7200
QUOTA_RETRY_INTERVAL=300
QUOTA_RESERVE_PCT=10
QUOTA_MAX_PAUSE_DURATION=60
QUOTA_PROBE_MIN_INTERVAL=5     # Small floor so retry_after=6 isn't clamped up.
QUOTA_PROBE_MAX_INTERVAL=1800
# shellcheck disable=SC2034  # Consumed by _quota_sleep_chunked in sourced lib
QUOTA_SLEEP_CHUNK=1
CLAUDE_QUOTA_CHECK_CMD=""
AGENT_ACTIVITY_TIMEOUT=600

export PROJECT_DIR LOG_DIR LOG_FILE TEKHTON_SESSION_DIR
export AUTONOMOUS_TIMEOUT QUOTA_RETRY_INTERVAL QUOTA_RESERVE_PCT
export QUOTA_MAX_PAUSE_DURATION QUOTA_PROBE_MIN_INTERVAL QUOTA_PROBE_MAX_INTERVAL
export QUOTA_SLEEP_CHUNK CLAUDE_QUOTA_CHECK_CMD AGENT_ACTIVITY_TIMEOUT

mkdir -p "$LOG_DIR" "$TEKHTON_SESSION_DIR" "$TMPDIR/.claude"
touch "$LOG_FILE"

# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=../lib/quota.sh
source "${TEKHTON_HOME}/lib/quota.sh"

# Source the shared test helper (canonical source: lib/agent_retry.sh).
# This avoids duplicating the function across multiple test files.
# shellcheck source=helpers/retry_after_extract.sh
source "${TEKHTON_HOME}/tests/helpers/retry_after_extract.sh"

# --- Test helpers ---
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# =============================================================================
echo "=== M125 integration: synthetic rate-limit → Retry-After propagation ==="
# =============================================================================

# 1. Write a synthetic rate-limit payload with retry_after=6 to the session.
cat > "$TEKHTON_SESSION_DIR/agent_last_output.txt" <<'JSON'
{"type":"error","error":{"type":"rate_limit_error","message":"rate limit exceeded","retry_after": 6}}
JSON
echo "rate limit exceeded" > "$TEKHTON_SESSION_DIR/agent_stderr.txt"

# 2. Extract Retry-After via the helper — verify the integration surface.
extracted=$(_extract_retry_after_seconds "$TEKHTON_SESSION_DIR" || echo "")
if [[ "$extracted" == "6" ]]; then
    pass "Retry-After=6 extracted from synthetic session payload"
else
    fail "Retry-After extraction" "expected '6', got '$extracted'"
fi

# 3. Stub _quota_probe to succeed on the first call and record its timestamp.
_PROBE_TIMES=()
_PROBE_CALLS=0
_quota_probe() {
    _PROBE_TIMES+=("$(date +%s)")
    _PROBE_CALLS=$(( _PROBE_CALLS + 1 ))
    return 0
}

# Also stub the TUI pause API so the loop doesn't fail when tui_ops_pause
# isn't sourced. Capture first_probe_delay to verify threading.
_TUI_RECEIVED_DELAY=""
tui_enter_pause()  { _TUI_RECEIVED_DELAY="${4:-}"; }
tui_update_pause() { :; }
tui_exit_pause()   { :; }

_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_PAUSED=false

# 4. Drive enter_quota_pause with the extracted Retry-After.
pause_start_ts=$(date +%s)
enter_quota_pause "Rate limited (integration test)" "$extracted" >/dev/null 2>&1
pause_end_ts=$(date +%s)

# 5. First-probe delay: expected ~6s after pause entry, ±2s slop.
probe_delay=0
if [[ "$_PROBE_CALLS" -gt 0 ]]; then
    probe_delay=$(( _PROBE_TIMES[0] - pause_start_ts ))
fi
if [[ "$_PROBE_CALLS" -eq 1 ]] && [[ "$probe_delay" -ge 4 ]] && [[ "$probe_delay" -le 9 ]]; then
    pass "first probe fired ~6s after entry (actual ${probe_delay}s)"
else
    fail "first probe timing" "calls=${_PROBE_CALLS} delay=${probe_delay}s"
fi

# 6. TUI received first_probe_delay threaded through (allowing for clamp).
if [[ -n "$_TUI_RECEIVED_DELAY" ]] && [[ "$_TUI_RECEIVED_DELAY" -ge 6 ]]; then
    pass "tui_enter_pause received first_probe_delay=${_TUI_RECEIVED_DELAY}"
else
    fail "tui first_probe_delay" "expected >=6, got '$_TUI_RECEIVED_DELAY'"
fi

# 7. Pause stats: exactly one pause recorded.
if [[ "$_QUOTA_PAUSE_COUNT" -eq 1 ]]; then
    pass "_QUOTA_PAUSE_COUNT incremented to 1"
else
    fail "_QUOTA_PAUSE_COUNT" "expected 1, got ${_QUOTA_PAUSE_COUNT}"
fi

pause_total_expected=$(( pause_end_ts - pause_start_ts ))
if [[ "$_QUOTA_TOTAL_PAUSE_TIME" -ge $(( pause_total_expected - 1 )) ]] \
   && [[ "$_QUOTA_TOTAL_PAUSE_TIME" -le $(( pause_total_expected + 1 )) ]]; then
    pass "_QUOTA_TOTAL_PAUSE_TIME within ±1s of wall-clock"
else
    fail "_QUOTA_TOTAL_PAUSE_TIME" \
        "expected ~${pause_total_expected}, got ${_QUOTA_TOTAL_PAUSE_TIME}"
fi

# 8. get_quota_stats_json reflects the pause.
json=$(get_quota_stats_json)
if echo "$json" | grep -q '"pause_count":1'; then
    pass "get_quota_stats_json reports pause_count=1"
else
    fail "get_quota_stats_json" "pause_count missing/wrong: $json"
fi
if echo "$json" | grep -q '"was_quota_limited":true'; then
    pass "get_quota_stats_json reports was_quota_limited=true"
else
    fail "was_quota_limited" "not set in JSON: $json"
fi

unset -f _quota_probe tui_enter_pause tui_update_pause tui_exit_pause

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
