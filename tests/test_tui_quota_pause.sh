#!/usr/bin/env bash
# =============================================================================
# test_tui_quota_pause.sh — TUI quota-pause state machine (M124)
#
# Verifies the public pause API in lib/tui_ops_pause.sh:
#   tui_enter_pause / tui_update_pause / tui_exit_pause
#
# Specifically:
# - tui_enter_pause sets _TUI_AGENT_STATUS to "paused" and writes the
#   pause_* fields into tui_status.json with the values supplied by the
#   caller (reason, retry interval, max duration).
# - tui_update_pause refreshes pause_next_probe_at without appending a new
#   recent_events entry (rate-limited update path).
# - tui_exit_pause clears pause_* fields and reverts _TUI_AGENT_STATUS to
#   "idle" (so the next supervisor run can re-set it to "running") and
#   appends one summary event.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"
export TEKHTON_SESSION_DIR="$TMPDIR/session"
mkdir -p "$TEKHTON_SESSION_DIR"

# Silence common.sh logging — tests assert on JSON, not stdout.
log()         { :; }
warn()        { :; }
error()      { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/tui.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

_activate() {
    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$TMPDIR/status.json"
    _TUI_STATUS_TMP="$TMPDIR/status.json.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)
    _TUI_RECENT_EVENTS=()
    _TUI_STAGES_COMPLETE=()
    _TUI_STAGE_ORDER=()
    _TUI_CURRENT_STAGE_LABEL="coder"
    _TUI_CURRENT_STAGE_MODEL="claude-opus-4-7"
    _TUI_CURRENT_STAGE_NUM=1
    _TUI_CURRENT_STAGE_TOTAL=4
    _TUI_AGENT_TURNS_USED=10
    _TUI_AGENT_TURNS_MAX=80
    _TUI_AGENT_ELAPSED_SECS=0
    _TUI_AGENT_STATUS="running"
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_COMPLETE=false
    _TUI_VERDICT=""
    _TUI_PAUSE_REASON=""
    _TUI_PAUSE_RETRY_INTERVAL=0
    _TUI_PAUSE_MAX_DURATION=0
    _TUI_PAUSE_STARTED_AT=0
    _TUI_PAUSE_NEXT_PROBE_AT=0
    _TUI_CURRENT_LIFECYCLE_ID=""
    _TUI_CURRENT_SUBSTAGE_LABEL=""
    _TUI_CURRENT_SUBSTAGE_START_TS=0
    # shellcheck disable=SC2034  # Read by lib/tui_ops_substage.sh on each call
    TUI_LIFECYCLE_V2=true
}

_json_field() {
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
v = d.get('$1')
print('<MISSING>' if v is None else v)
" 2>/dev/null
}

_json_event_count() {
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
print(len(d.get('recent_events', [])))
" 2>/dev/null
}

# =============================================================================
echo "=== M124-1: tui_enter_pause sets paused state and pause_* fields ==="
_activate
tui_enter_pause "Rate limited (test)" 300 14400

status=$(_json_field current_agent_status)
[[ "$status" == "paused" ]] && pass "current_agent_status=paused" \
    || fail "current_agent_status" "expected 'paused', got '$status'"

reason=$(_json_field pause_reason)
[[ "$reason" == "Rate limited (test)" ]] && pass "pause_reason serialized" \
    || fail "pause_reason" "got '$reason'"

interval=$(_json_field pause_retry_interval)
[[ "$interval" == "300" ]] && pass "pause_retry_interval=300" \
    || fail "pause_retry_interval" "got '$interval'"

maxdur=$(_json_field pause_max_duration)
[[ "$maxdur" == "14400" ]] && pass "pause_max_duration=14400" \
    || fail "pause_max_duration" "got '$maxdur'"

started=$(_json_field pause_started_at)
[[ "$started" =~ ^[0-9]+$ ]] && [[ "$started" -gt 0 ]] \
    && pass "pause_started_at is non-zero unix ts" \
    || fail "pause_started_at" "got '$started'"

next_probe=$(_json_field pause_next_probe_at)
diff=$(( next_probe - started ))
[[ "$diff" == "300" ]] && pass "pause_next_probe_at = started + interval" \
    || fail "pause_next_probe_at" "expected started+300, diff=$diff"

# =============================================================================
echo "=== M124-2: tui_update_pause refreshes countdown, no new event ==="
_activate
tui_enter_pause "Rate limited" 300 14400
events_after_enter=$(_json_event_count)
sleep 1
tui_update_pause 120 60
events_after_update=$(_json_event_count)

[[ "$events_after_enter" == "$events_after_update" ]] \
    && pass "tui_update_pause appended no event" \
    || fail "events count" "enter=$events_after_enter update=$events_after_update"

next_probe=$(_json_field pause_next_probe_at)
now_ts=$(date +%s)
diff=$(( next_probe - now_ts ))
# Allow a 2s window for execution slop on slow systems
[[ "$diff" -ge 118 ]] && [[ "$diff" -le 122 ]] \
    && pass "pause_next_probe_at advanced to ~120s from now" \
    || fail "pause_next_probe_at" "diff=$diff (expected ~120)"

# =============================================================================
echo "=== M124-3: tui_exit_pause clears state and reverts to idle ==="
_activate
tui_enter_pause "Rate limited" 300 14400
tui_exit_pause "refreshed"

status=$(_json_field current_agent_status)
[[ "$status" == "idle" ]] && pass "current_agent_status reverts to idle" \
    || fail "current_agent_status" "expected 'idle', got '$status'"

for f in pause_reason pause_retry_interval pause_max_duration \
         pause_started_at pause_next_probe_at; do
    val=$(_json_field "$f")
    case "$f" in
        pause_reason)
            [[ -z "$val" ]] && pass "$f cleared" \
                || fail "$f" "expected empty, got '$val'" ;;
        *)
            [[ "$val" == "0" ]] && pass "$f cleared to 0" \
                || fail "$f" "expected '0', got '$val'" ;;
    esac
done

# =============================================================================
echo "=== M124-4: pause_* JSON keys always present (schema stability) ==="
_activate
# Never paused — call _tui_write_status directly.
_tui_write_status

for f in pause_reason pause_retry_interval pause_max_duration \
         pause_started_at pause_next_probe_at; do
    val=$(_json_field "$f")
    [[ "$val" == "<MISSING>" ]] && fail "$f present in default output" \
        "key was missing" \
        || pass "$f present in default JSON"
done

# =============================================================================
echo "=== M124-5: tui_*pause are no-ops when _TUI_ACTIVE is false ==="
_activate
_TUI_ACTIVE=false
# Reset status file so we can detect any spurious write.
rm -f "$_TUI_STATUS_FILE"
tui_enter_pause "should be ignored" 300 14400
tui_update_pause 60
tui_exit_pause "refreshed"

[[ ! -f "$_TUI_STATUS_FILE" ]] \
    && pass "no status writes when inactive" \
    || fail "no status writes when inactive" "status file exists"

# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
