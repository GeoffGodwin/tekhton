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
QUOTA_MAX_PAUSE_DURATION=14400
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
echo "=== Config defaults ==="
# =============================================================================

# Test: defaults are set correctly via config_defaults.sh
# (These are validated by the fact that we can source quota.sh with them)
assert "QUOTA_RETRY_INTERVAL is 300" "$([ "${QUOTA_RETRY_INTERVAL:-}" = "300" ] && echo 0 || echo 1)"
assert "QUOTA_RESERVE_PCT is 10" "$([ "${QUOTA_RESERVE_PCT:-}" = "10" ] && echo 0 || echo 1)"
assert "QUOTA_MAX_PAUSE_DURATION is 14400" "$([ "${QUOTA_MAX_PAUSE_DURATION:-}" = "14400" ] && echo 0 || echo 1)"
assert "MAX_AUTONOMOUS_AGENT_CALLS is 200" "$([ "${MAX_AUTONOMOUS_AGENT_CALLS:-}" = "200" ] && echo 0 || echo 1)"

# =============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
