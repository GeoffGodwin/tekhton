#!/usr/bin/env bash
# =============================================================================
# test_quota.sh — Tests for quota management and rate-limit handling (M16)
#
# Tests:
# - is_rate_limit_error pattern detection
# - Pause/resume state transitions (globals)
# - Timeout disable/restore during pause
# - get_quota_stats_json output
# - format_quota_pause_summary output
# - check_quota_remaining (Tier 2, with mock)
# - should_pause_proactively threshold check
# - Milestone success counter reset (orchestrate integration)
# - Enhanced progress detection (_check_progress_causal_log)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals (minimal set for sourcing) ---
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/logs"
LOG_FILE="$TMPDIR/test.log"
TASK="Test quota"
MILESTONE_MODE=false
_CURRENT_MILESTONE=""
PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"
TEKHTON_SESSION_DIR="$TMPDIR"
AUTONOMOUS_TIMEOUT=7200
MAX_PIPELINE_ATTEMPTS=5
MAX_AUTONOMOUS_AGENT_CALLS=200
AUTONOMOUS_PROGRESS_CHECK=true
TOTAL_TURNS=0
VERDICT="unknown"
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
START_AT="coder"
TIMESTAMP="20260323_120000"
MAX_REVIEW_CYCLES=3
QUOTA_RETRY_INTERVAL=300
QUOTA_RESERVE_PCT=10
QUOTA_MAX_PAUSE_DURATION=18900
CLAUDE_QUOTA_CHECK_CMD=""
AGENT_ACTIVITY_TIMEOUT=600
CAUSAL_LOG_ENABLED=true
CAUSAL_LOG_FILE="$TMPDIR/.claude/logs/CAUSAL_LOG.jsonl"

export PROJECT_DIR LOG_DIR LOG_FILE TASK MILESTONE_MODE _CURRENT_MILESTONE
export PIPELINE_STATE_FILE TEKHTON_SESSION_DIR
export AUTONOMOUS_TIMEOUT MAX_PIPELINE_ATTEMPTS MAX_AUTONOMOUS_AGENT_CALLS
export AUTONOMOUS_PROGRESS_CHECK TOTAL_TURNS VERDICT
export AGENT_ERROR_CATEGORY AGENT_ERROR_SUBCATEGORY START_AT TIMESTAMP
export MAX_REVIEW_CYCLES AGENT_ACTIVITY_TIMEOUT
export QUOTA_RETRY_INTERVAL QUOTA_RESERVE_PCT QUOTA_MAX_PAUSE_DURATION
export CLAUDE_QUOTA_CHECK_CMD CAUSAL_LOG_ENABLED CAUSAL_LOG_FILE

mkdir -p "$LOG_DIR" "$TMPDIR/.claude" "$TMPDIR/.claude/logs"
touch "$LOG_FILE"

# Source common.sh for log/warn/success
source "${TEKHTON_HOME}/lib/common.sh"

# Source quota.sh under test
source "${TEKHTON_HOME}/lib/quota.sh"

# Source orchestrate_recovery.sh for _check_progress tests
# Mock dependencies
suggest_recovery() { echo "Check run log."; }
redact_sensitive() { cat; }
source "${TEKHTON_HOME}/lib/orchestrate_recovery.sh"

# --- Test helpers ---
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

# =============================================================================
echo "=== is_rate_limit_error ==="
# =============================================================================

# Test: rate limit pattern in stderr
stderr_file="$TMPDIR/test_stderr_ratelimit.txt"
echo "Error: rate limit exceeded for organization" > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 'rate limit' pattern" "$?"

# Test: 429 pattern
echo '{"status": 429, "error": "too many requests"}' > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 429 pattern" "$?"

# Test: quota exceeded
echo "Error: quota exceeded" > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 'quota exceeded' pattern" "$?"

# Test: overloaded
echo "Error: server overloaded, try again later" > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 'overloaded' pattern" "$?"

# Test: usage limit
echo "Error: usage limit reached" > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 'usage limit' pattern" "$?"

# Test: too many requests
echo "too many requests" > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 'too many requests' pattern" "$?"

# Test: rate_limit_error
echo '{"type":"error","error":{"type":"rate_limit_error"}}' > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 'rate_limit_error' pattern" "$?"

# Test: capacity
echo "Error: at capacity, please wait" > "$stderr_file"
is_rate_limit_error 1 "$stderr_file"
assert "detects 'capacity' pattern" "$?"

# Test: non-rate-limit error
echo "Error: internal server error" > "$stderr_file"
rc=0; is_rate_limit_error 1 "$stderr_file" || rc=$?
assert "rejects non-rate-limit error" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# Test: exit code 0 always returns 1
echo "rate limit" > "$stderr_file"
rc=0; is_rate_limit_error 0 "$stderr_file" || rc=$?
assert "exit code 0 always returns 1 (not rate limited)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# Test: empty stderr
: > "$stderr_file"
rc=0; is_rate_limit_error 1 "$stderr_file" || rc=$?
assert "empty stderr returns 1" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# Test: missing stderr file
rc=0; is_rate_limit_error 1 "$TMPDIR/nonexistent_file.txt" || rc=$?
assert "missing stderr file returns 1" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# =============================================================================
echo "=== Quota state globals ==="
# =============================================================================

# Test: initial state
assert "_QUOTA_PAUSE_COUNT starts at 0" "$([ "$_QUOTA_PAUSE_COUNT" -eq 0 ] && echo 0 || echo 1)"
assert "_QUOTA_TOTAL_PAUSE_TIME starts at 0" "$([ "$_QUOTA_TOTAL_PAUSE_TIME" -eq 0 ] && echo 0 || echo 1)"
assert "_QUOTA_PAUSED starts false" "$([ "$_QUOTA_PAUSED" = false ] && echo 0 || echo 1)"

# =============================================================================
echo "=== get_quota_stats_json ==="
# =============================================================================

# Test: no pauses
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
json=$(get_quota_stats_json)
assert "no-pause JSON has was_quota_limited:false" "$(echo "$json" | grep -q '"was_quota_limited":false' && echo 0 || echo 1)"
assert "no-pause JSON has pause_count:0" "$(echo "$json" | grep -q '"pause_count":0' && echo 0 || echo 1)"

# Test: with pauses
_QUOTA_PAUSE_COUNT=2
_QUOTA_TOTAL_PAUSE_TIME=754
json=$(get_quota_stats_json)
assert "paused JSON has was_quota_limited:true" "$(echo "$json" | grep -q '"was_quota_limited":true' && echo 0 || echo 1)"
assert "paused JSON has pause_count:2" "$(echo "$json" | grep -q '"pause_count":2' && echo 0 || echo 1)"
assert "paused JSON has total_pause_time_s:754" "$(echo "$json" | grep -q '"total_pause_time_s":754' && echo 0 || echo 1)"

# Reset
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0

# =============================================================================
echo "=== format_quota_pause_summary ==="
# =============================================================================

# Test: no pauses returns empty
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
result=$(format_quota_pause_summary)
assert "no pauses returns empty string" "$([ -z "$result" ] && echo 0 || echo 1)"

# Test: with pauses formats correctly
_QUOTA_PAUSE_COUNT=2
_QUOTA_TOTAL_PAUSE_TIME=754
result=$(format_quota_pause_summary)
assert "formats with minutes and seconds" "$(echo "$result" | grep -q '12m 34s' && echo 0 || echo 1)"
assert "shows pause count" "$(echo "$result" | grep -q 'Quota pauses: 2' && echo 0 || echo 1)"

# Test: seconds only
_QUOTA_PAUSE_COUNT=1
_QUOTA_TOTAL_PAUSE_TIME=45
result=$(format_quota_pause_summary)
assert "formats seconds only" "$(echo "$result" | grep -q '45s' && echo 0 || echo 1)"

# Reset
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0

# =============================================================================
echo "=== check_quota_remaining (Tier 2) ==="
# =============================================================================

# Test: not configured returns empty
CLAUDE_QUOTA_CHECK_CMD=""
result=$(check_quota_remaining)
assert "empty cmd returns empty string" "$([ -z "$result" ] && echo 0 || echo 1)"

# Test: valid command returns number
CLAUDE_QUOTA_CHECK_CMD="echo 75"
result=$(check_quota_remaining)
assert "valid cmd returns 75" "$([ "$result" = "75" ] && echo 0 || echo 1)"

# Test: invalid output returns empty
CLAUDE_QUOTA_CHECK_CMD="echo 'not a number'"
result=$(check_quota_remaining)
assert "non-numeric output returns empty" "$([ -z "$result" ] && echo 0 || echo 1)"

# Test: out of range returns empty
CLAUDE_QUOTA_CHECK_CMD="echo 150"
result=$(check_quota_remaining)
assert "out-of-range returns empty" "$([ -z "$result" ] && echo 0 || echo 1)"

# Reset
CLAUDE_QUOTA_CHECK_CMD=""

# =============================================================================
echo "=== should_pause_proactively ==="
# =============================================================================

# Test: no check command — always returns 1
CLAUDE_QUOTA_CHECK_CMD=""
rc=0; should_pause_proactively || rc=$?
assert "no cmd = no proactive pause" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# Test: above threshold — no pause
CLAUDE_QUOTA_CHECK_CMD="echo 50"
QUOTA_RESERVE_PCT=10
rc=0; should_pause_proactively || rc=$?
assert "50% remaining > 10% threshold = no pause" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# Test: below threshold — pause
CLAUDE_QUOTA_CHECK_CMD="echo 5"
QUOTA_RESERVE_PCT=10
should_pause_proactively
assert "5% remaining < 10% threshold = pause" "$?"

# Reset
CLAUDE_QUOTA_CHECK_CMD=""

# =============================================================================
echo "=== exit_quota_pause (state restoration) ==="
# =============================================================================

# Test: timeout restoration
_QUOTA_SAVED_ACTIVITY_TIMEOUT="600"
AGENT_ACTIVITY_TIMEOUT=0
_QUOTA_PAUSED=true
marker="$TMPDIR/.claude/QUOTA_PAUSED"
touch "$marker"

exit_quota_pause "$marker"

assert "activity timeout restored to 600" "$([ "$AGENT_ACTIVITY_TIMEOUT" = "600" ] && echo 0 || echo 1)"
assert "_QUOTA_PAUSED reset to false" "$([ "$_QUOTA_PAUSED" = "false" ] && echo 0 || echo 1)"
assert "marker file removed" "$([ ! -f "$marker" ] && echo 0 || echo 1)"

# =============================================================================
echo "=== _check_progress_causal_log ==="
# =============================================================================

# Test: no causal log file — returns 1
CAUSAL_LOG_FILE="$TMPDIR/nonexistent.jsonl"
rc=0; _check_progress_causal_log || rc=$?
assert "no causal log file returns 1" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# Test: with progress events — returns 0
CAUSAL_LOG_FILE="$TMPDIR/.claude/logs/CAUSAL_LOG.jsonl"
echo '{"type":"verdict","detail":"APPROVED"}' > "$CAUSAL_LOG_FILE"
_check_progress_causal_log
assert "verdict APPROVED detected as progress" "$?"

# Test: with milestone advance
echo '{"type":"milestone_advance","detail":"m01"}' > "$CAUSAL_LOG_FILE"
_check_progress_causal_log
assert "milestone_advance detected as progress" "$?"

# Test: only error events — returns 1
: > "$CAUSAL_LOG_FILE"
for i in $(seq 1 3); do
    echo '{"type":"error","detail":"something failed"}' >> "$CAUSAL_LOG_FILE"
done
rc=0; _check_progress_causal_log || rc=$?
assert "only error events = no progress" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# Test: causal log disabled — returns 1
CAUSAL_LOG_ENABLED=false
rc=0; _check_progress_causal_log || rc=$?
assert "disabled causal log returns 1" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
CAUSAL_LOG_ENABLED=true

# =============================================================================
echo "=== M124: enter_quota_pause calls TUI helpers ==="
# =============================================================================

# Stub TUI helpers as counting shell functions and a stub _quota_probe that
# always reports rate-limited so the loop runs to the max-duration timeout.
_TUI_ENTER_CALLS=0
_TUI_UPDATE_CALLS=0
_TUI_EXIT_CALLS=0
_TUI_EXIT_RESULT=""
tui_enter_pause()  { _TUI_ENTER_CALLS=$(( _TUI_ENTER_CALLS + 1 )); }
tui_update_pause() { _TUI_UPDATE_CALLS=$(( _TUI_UPDATE_CALLS + 1 )); }
tui_exit_pause()   {
    _TUI_EXIT_CALLS=$(( _TUI_EXIT_CALLS + 1 ))
    _TUI_EXIT_RESULT="${1:-}"
}
_quota_probe() { return 1; }

# Tight bounds so the loop terminates fast.
QUOTA_RETRY_INTERVAL=1
QUOTA_MAX_PAUSE_DURATION=2
# shellcheck disable=SC2034  # Read inside _quota_sleep_chunked
QUOTA_SLEEP_CHUNK=1
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_PAUSED=false

# enter_quota_pause should return 1 on max-duration timeout.
rc=0; enter_quota_pause "test rate limit" || rc=$?

assert "enter_quota_pause returns 1 on timeout" \
    "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
assert "tui_enter_pause called exactly once" \
    "$([ "$_TUI_ENTER_CALLS" -eq 1 ] && echo 0 || echo 1)"
assert "tui_update_pause called >= 1 time" \
    "$([ "$_TUI_UPDATE_CALLS" -ge 1 ] && echo 0 || echo 1)"
assert "tui_exit_pause called exactly once" \
    "$([ "$_TUI_EXIT_CALLS" -eq 1 ] && echo 0 || echo 1)"
assert "tui_exit_pause result is 'timeout'" \
    "$([ "$_TUI_EXIT_RESULT" = "timeout" ] && echo 0 || echo 1)"

# Restore probe behaviour so subsequent tests aren't affected.
unset -f _quota_probe
unset -f tui_enter_pause tui_update_pause tui_exit_pause
QUOTA_RETRY_INTERVAL=300
QUOTA_MAX_PAUSE_DURATION=18900
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_PAUSED=false

# =============================================================================
echo "=== M124: enter_quota_pause does not error when TUI helpers absent ==="
# =============================================================================

# No tui_* helpers defined — `command -v` guards must keep enter_quota_pause
# safe. Use the same tight loop bounds + always-fail probe.
_quota_probe() { return 1; }
QUOTA_RETRY_INTERVAL=1
QUOTA_MAX_PAUSE_DURATION=2
# shellcheck disable=SC2034  # Read inside _quota_sleep_chunked
QUOTA_SLEEP_CHUNK=1

rc=0; enter_quota_pause "test rate limit (no tui)" || rc=$?
assert "enter_quota_pause exits cleanly without TUI helpers" \
    "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

unset -f _quota_probe
QUOTA_RETRY_INTERVAL=300
QUOTA_MAX_PAUSE_DURATION=18900
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_PAUSED=false

# =============================================================================
echo "=== Module compatibility with canonical default values ==="
# =============================================================================

# This block verifies quota.sh operates correctly under the canonical default
# values declared in config_defaults.sh. The test fixture primes each variable
# at file top (lines 42–44) rather than sourcing config_defaults.sh, so the
# assertions below confirm the fixture primes match the canonical defaults —
# update both sites together when a default is changed.
assert "QUOTA_RETRY_INTERVAL matches canonical default (300)" "$([ "${QUOTA_RETRY_INTERVAL:-}" = "300" ] && echo 0 || echo 1)"
assert "QUOTA_RESERVE_PCT matches canonical default (10)" "$([ "${QUOTA_RESERVE_PCT:-}" = "10" ] && echo 0 || echo 1)"
assert "QUOTA_MAX_PAUSE_DURATION matches canonical default (18900)" "$([ "${QUOTA_MAX_PAUSE_DURATION:-}" = "18900" ] && echo 0 || echo 1)"
assert "MAX_AUTONOMOUS_AGENT_CALLS matches canonical default (200)" "$([ "${MAX_AUTONOMOUS_AGENT_CALLS:-}" = "200" ] && echo 0 || echo 1)"

# =============================================================================
echo "=== M125: _extract_retry_after_seconds ==="
# =============================================================================

# Source the shared test helper (canonical source: lib/agent_retry.sh).
# This avoids duplicating the function across multiple test files.
# shellcheck source=helpers/retry_after_extract.sh
source "${TEKHTON_HOME}/tests/helpers/retry_after_extract.sh"

_M125_SESS_DIR="$TMPDIR/m125_session"
mkdir -p "$_M125_SESS_DIR"

# Test: JSON form in agent_last_output.txt
echo '{"error":{"type":"rate_limit_error","retry_after": 47}}' > "$_M125_SESS_DIR/agent_last_output.txt"
: > "$_M125_SESS_DIR/agent_stderr.txt"
result=$(_extract_retry_after_seconds "$_M125_SESS_DIR" || echo "MISS")
assert "parses JSON form retry_after:47" "$([ "$result" = "47" ] && echo 0 || echo 1)"

# Test: dash form "retry-after": "12"
echo '{"retry-after": "12"}' > "$_M125_SESS_DIR/agent_last_output.txt"
result=$(_extract_retry_after_seconds "$_M125_SESS_DIR" || echo "MISS")
assert "parses JSON retry-after with string value" "$([ "$result" = "12" ] && echo 0 || echo 1)"

# Test: stderr plain-text form
: > "$_M125_SESS_DIR/agent_last_output.txt"
echo "Rate limited. Retry after 180 seconds." > "$_M125_SESS_DIR/agent_stderr.txt"
result=$(_extract_retry_after_seconds "$_M125_SESS_DIR" || echo "MISS")
assert "parses stderr plain-text form 'Retry after 180'" "$([ "$result" = "180" ] && echo 0 || echo 1)"

# Test: stderr Retry-After header form
echo "HTTP/1.1 429 Too Many Requests\nRetry-After: 90" > "$_M125_SESS_DIR/agent_stderr.txt"
result=$(_extract_retry_after_seconds "$_M125_SESS_DIR" || echo "MISS")
assert "parses stderr 'Retry-After: 90' header" "$([ "$result" = "90" ] && echo 0 || echo 1)"

# Test: no match → non-zero exit
: > "$_M125_SESS_DIR/agent_last_output.txt"
echo "some unrelated error message" > "$_M125_SESS_DIR/agent_stderr.txt"
rc=0; result=$(_extract_retry_after_seconds "$_M125_SESS_DIR") || rc=$?
assert "absent Retry-After returns non-zero" "$([ "$rc" -ne 0 ] && [ -z "$result" ] && echo 0 || echo 1)"

# Test: missing session dir
rc=0; _extract_retry_after_seconds "" >/dev/null || rc=$?
assert "missing session dir returns non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# =============================================================================
echo "=== M125: enter_quota_pause honours Retry-After ==="
# =============================================================================

# Stub TUI helpers (reset from earlier section) and a controllable probe.
tui_enter_pause()  { _TUI_FIRST_PROBE_DELAY="${4:-}"; }
tui_update_pause() { :; }
tui_exit_pause()   { :; }

# Probe stub: record wall-clock of each call and succeed on the first one.
_PROBE_CALL_TIMES=()
_PROBE_START_TS=0
_quota_probe() {
    local now
    now=$(date +%s)
    _PROBE_CALL_TIMES+=("$now")
    return 0  # quota refreshed on first probe
}

QUOTA_RETRY_INTERVAL=2
QUOTA_PROBE_MIN_INTERVAL=5
QUOTA_PROBE_MAX_INTERVAL=1800
QUOTA_MAX_PAUSE_DURATION=60
# shellcheck disable=SC2034  # Read inside _quota_sleep_chunked
QUOTA_SLEEP_CHUNK=1
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_PAUSED=false
_TUI_FIRST_PROBE_DELAY=""

_PROBE_START_TS=$(date +%s)
enter_quota_pause "Test retry-after" 8 >/dev/null 2>&1

assert "retry_after=8 triggers first probe ~8s later" \
    "$([ "${#_PROBE_CALL_TIMES[@]}" -eq 1 ] && \
       [ "$(( _PROBE_CALL_TIMES[0] - _PROBE_START_TS ))" -ge 7 ] && \
       [ "$(( _PROBE_CALL_TIMES[0] - _PROBE_START_TS ))" -le 10 ] && echo 0 || echo 1)"

assert "tui_enter_pause received first_probe_delay=8" \
    "$([ "$_TUI_FIRST_PROBE_DELAY" = "8" ] && echo 0 || echo 1)"

# Test: clamp retry_after below floor
_PROBE_CALL_TIMES=()
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_PAUSED=false
_TUI_FIRST_PROBE_DELAY=""
QUOTA_PROBE_MIN_INTERVAL=6

_PROBE_START_TS=$(date +%s)
enter_quota_pause "Test floor clamp" 1 >/dev/null 2>&1

assert "retry_after=1 clamped up to floor=6" \
    "$([ "$_TUI_FIRST_PROBE_DELAY" = "6" ] && echo 0 || echo 1)"

# Test: absent retry_after → first probe at QUOTA_RETRY_INTERVAL
_PROBE_CALL_TIMES=()
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_PAUSED=false
_TUI_FIRST_PROBE_DELAY=""
QUOTA_RETRY_INTERVAL=4
QUOTA_PROBE_MIN_INTERVAL=600  # back to default

enter_quota_pause "No retry-after" "" >/dev/null 2>&1

assert "absent retry_after uses QUOTA_RETRY_INTERVAL=4" \
    "$([ "$_TUI_FIRST_PROBE_DELAY" = "4" ] && echo 0 || echo 1)"

unset -f _quota_probe tui_enter_pause tui_update_pause tui_exit_pause

# =============================================================================
echo "=== M125: probe mode detection + back-off ==="
# =============================================================================

# Source quota_probe.sh helpers in isolation (already sourced via quota.sh,
# but reset the cached mode for these tests).
_QUOTA_PROBE_MODE=""

# Stub a fake claude binary that exits 0 on --version — should pick 'version' mode.
_M125_BIN_DIR="$TMPDIR/bin_version"
mkdir -p "$_M125_BIN_DIR"
cat > "$_M125_BIN_DIR/claude" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
    --version) echo "claude-cli 99.0.0"; exit 0 ;;
    *) exit 1 ;;
esac
SHIM
chmod +x "$_M125_BIN_DIR/claude"

_OLD_PATH="$PATH"
PATH="$_M125_BIN_DIR:$PATH"
_QUOTA_PROBE_MODE=""
_quota_detect_probe_mode
assert "probe mode prefers 'version' when claude --version works" \
    "$([ "$_QUOTA_PROBE_MODE" = "version" ] && echo 0 || echo 1)"
PATH="$_OLD_PATH"

# Stub a fake claude that fails --version but shows --max-turns in help.
_M125_BIN_DIR2="$TMPDIR/bin_zeroturn"
mkdir -p "$_M125_BIN_DIR2"
cat > "$_M125_BIN_DIR2/claude" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
    --version) exit 1 ;;
    --help) echo "Usage: claude [--max-turns N] [-p PROMPT]"; exit 0 ;;
    *) exit 1 ;;
esac
SHIM
chmod +x "$_M125_BIN_DIR2/claude"

PATH="$_M125_BIN_DIR2:$PATH"
_QUOTA_PROBE_MODE=""
_quota_detect_probe_mode
assert "probe mode falls through to 'zero_turn' when --max-turns supported" \
    "$([ "$_QUOTA_PROBE_MODE" = "zero_turn" ] && echo 0 || echo 1)"
PATH="$_OLD_PATH"

# Stub a claude without --max-turns in help → fallback mode.
_M125_BIN_DIR3="$TMPDIR/bin_fallback"
mkdir -p "$_M125_BIN_DIR3"
cat > "$_M125_BIN_DIR3/claude" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
    --version) exit 1 ;;
    --help) echo "Usage: claude [-p PROMPT]"; exit 0 ;;
    *) exit 1 ;;
esac
SHIM
chmod +x "$_M125_BIN_DIR3/claude"

PATH="$_M125_BIN_DIR3:$PATH"
_QUOTA_PROBE_MODE=""
_quota_detect_probe_mode
assert "probe mode selects 'fallback' when neither --version nor --max-turns works" \
    "$([ "$_QUOTA_PROBE_MODE" = "fallback" ] && echo 0 || echo 1)"
PATH="$_OLD_PATH"

# Test: back-off formula
# Probe 1..2 use QUOTA_RETRY_INTERVAL (with jitter). Probe 3+ uses 1.5x prev.
QUOTA_RETRY_INTERVAL=100
QUOTA_PROBE_MAX_INTERVAL=1000

# Run several trials and check the base-line (before jitter) falls in the
# expected ±10% envelope.
delay1=$(_quota_next_probe_delay 2 0)
assert "probe 2 delay in [90..110] of RETRY_INTERVAL" \
    "$([ "$delay1" -ge 90 ] && [ "$delay1" -le 110 ] && echo 0 || echo 1)"

# Probe 3 off a prev_delay=100 → 100 * 1.5 = 150 → ±10% → [135..165]
delay2=$(_quota_next_probe_delay 3 100)
assert "probe 3 delay in [135..165] (1.5x with jitter)" \
    "$([ "$delay2" -ge 135 ] && [ "$delay2" -le 165 ] && echo 0 || echo 1)"

# Cap check: prev_delay=900 → 900*1.5=1350 → capped at 1000 → ±10% → [900..1100]
delay3=$(_quota_next_probe_delay 4 900)
assert "back-off capped at QUOTA_PROBE_MAX_INTERVAL" \
    "$([ "$delay3" -ge 900 ] && [ "$delay3" -le 1100 ] && echo 0 || echo 1)"

# _quota_fmt_duration
assert "_quota_fmt_duration 18900 → 5h15m" \
    "$([ "$(_quota_fmt_duration 18900)" = "5h15m" ] && echo 0 || echo 1)"
assert "_quota_fmt_duration 2820 → 47m" \
    "$([ "$(_quota_fmt_duration 2820)" = "47m" ] && echo 0 || echo 1)"
assert "_quota_fmt_duration 30 → 30s" \
    "$([ "$(_quota_fmt_duration 30)" = "30s" ] && echo 0 || echo 1)"
assert "_quota_fmt_duration 3600 → 1h" \
    "$([ "$(_quota_fmt_duration 3600)" = "1h" ] && echo 0 || echo 1)"

# =============================================================================
echo "=== M125: fallback-mode throttle (min-interval not yet elapsed) ==="
# =============================================================================

# Prior test stubs called `unset -f _quota_probe`, removing the real function.
# Re-source to restore all four helpers without resetting already-set globals.
# shellcheck source=../lib/quota_probe.sh
source "${TEKHTON_HOME}/lib/quota_probe.sh"

# The fallback branch inside _quota_probe throttles itself: if _QUOTA_PROBE_LAST_TS
# is set and (now - last_ts) < QUOTA_PROBE_MIN_INTERVAL it returns 1 immediately
# WITHOUT calling claude.  This branch (quota_probe.sh:76-79) had no coverage.

# --- Test 1: throttle fires when interval has not elapsed ---
_QUOTA_PROBE_MODE="fallback"
_QUOTA_PROBE_LAST_TS=$(date +%s)   # "just now" — interval cannot have elapsed
QUOTA_PROBE_MIN_INTERVAL=600

rc=0; _quota_probe 2>/dev/null || rc=$?
assert "fallback probe returns 1 when min-interval not yet elapsed (throttle branch)" \
    "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# _QUOTA_PROBE_LAST_TS must NOT change — we returned before the update line.
_ts_saved="$_QUOTA_PROBE_LAST_TS"
_quota_probe 2>/dev/null || true
assert "_QUOTA_PROBE_LAST_TS unchanged on throttled fallback call" \
    "$([ "$_QUOTA_PROBE_LAST_TS" = "$_ts_saved" ] && echo 0 || echo 1)"

# --- Test 2: no throttle when interval HAS elapsed — probe runs and updates TS ---
# Use a stub claude so the real network call never fires.
_M125_FB_DIR="$TMPDIR/bin_fallback_probe"
mkdir -p "$_M125_FB_DIR"
cat > "$_M125_FB_DIR/claude" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$_M125_FB_DIR/claude"

_OLD_PATH="$PATH"
PATH="$_M125_FB_DIR:$PATH"

_QUOTA_PROBE_MODE="fallback"
_QUOTA_PROBE_LAST_TS=1          # epoch start — guaranteed > QUOTA_PROBE_MIN_INTERVAL ago
QUOTA_PROBE_MIN_INTERVAL=600

_ts_before=$(date +%s)
_quota_probe 2>/dev/null || true
assert "fallback probe updates _QUOTA_PROBE_LAST_TS when interval has elapsed" \
    "$([ "$_QUOTA_PROBE_LAST_TS" -ge "$_ts_before" ] && echo 0 || echo 1)"

PATH="$_OLD_PATH"
_QUOTA_PROBE_MODE=""
_QUOTA_PROBE_LAST_TS=0
QUOTA_PROBE_MIN_INTERVAL=600

# =============================================================================
echo "=== M125: _QUOTA_PROBE_MODE cache reuse (early-exit on second call) ==="
# =============================================================================

# _quota_detect_probe_mode has a [[ -n "$_QUOTA_PROBE_MODE" ]] && return 0 guard
# at the top so mode detection only runs once per pipeline session.  No test
# previously verified that second call actually hit that guard.

_M125_CACHE_DIR="$TMPDIR/bin_cache_reuse"
mkdir -p "$_M125_CACHE_DIR"
echo "0" > "$_M125_CACHE_DIR/call_count"
cat > "$_M125_CACHE_DIR/claude" <<'SHIM'
#!/usr/bin/env bash
cnt_file="$(dirname "$0")/call_count"
c=$(cat "$cnt_file")
echo $(( c + 1 )) > "$cnt_file"
case "$1" in
    --version) echo "claude-cli 99.0.0"; exit 0 ;;
    *) exit 1 ;;
esac
SHIM
chmod +x "$_M125_CACHE_DIR/claude"

_OLD_PATH="$PATH"
PATH="$_M125_CACHE_DIR:$PATH"
_QUOTA_PROBE_MODE=""

# First call: detection runs, calls the stub's --version branch.
_quota_detect_probe_mode
_mode_after_first="$_QUOTA_PROBE_MODE"
_calls_after_first=$(cat "$_M125_CACHE_DIR/call_count")

# Second call: early-exit should fire; claude should NOT be called again.
_quota_detect_probe_mode
_calls_after_second=$(cat "$_M125_CACHE_DIR/call_count")

assert "_QUOTA_PROBE_MODE is non-empty after first detection" \
    "$([ -n "$_mode_after_first" ] && echo 0 || echo 1)"
assert "second _quota_detect_probe_mode does not re-detect (call count unchanged)" \
    "$([ "$_calls_after_second" -eq "$_calls_after_first" ] && echo 0 || echo 1)"

PATH="$_OLD_PATH"
_QUOTA_PROBE_MODE=""
_QUOTA_PROBE_LAST_TS=0

# =============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
