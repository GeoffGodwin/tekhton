#!/usr/bin/env bash
# =============================================================================
# test_tui_attribution.sh — M117 — Recent Events substage attribution.
#
# Verifies that log/warn/error calls routed through _out_emit reach the TUI
# ring buffer with a `source` field reflecting the active stage/substage, and
# that the attribution is TUI-only (never written to plaintext LOG_FILE output).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"
export TEKHTON_SESSION_DIR="$TMPDIR/session"
mkdir -p "$TEKHTON_SESSION_DIR"

# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/common.sh"
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
    _TUI_CURRENT_STAGE_LABEL=""
    _TUI_CURRENT_STAGE_MODEL=""
    _TUI_CURRENT_STAGE_NUM=0
    _TUI_CURRENT_STAGE_TOTAL=0
    _TUI_AGENT_TURNS_USED=0
    _TUI_AGENT_TURNS_MAX=0
    _TUI_AGENT_ELAPSED_SECS=0
    _TUI_AGENT_STATUS="idle"
    _TUI_STAGE_START_TS=0
    _TUI_COMPLETE=false
    _TUI_VERDICT=""
    _TUI_STAGE_CYCLE=()
    _TUI_CURRENT_LIFECYCLE_ID=""
    _TUI_CLOSED_LIFECYCLE_IDS=()
    _TUI_CURRENT_SUBSTAGE_LABEL=""
    _TUI_CURRENT_SUBSTAGE_START_TS=0
    TUI_LIFECYCLE_V2=true
    LOG_FILE="$TMPDIR/pipeline.log"
    : > "$LOG_FILE"
}

_last_event_json() {
    python3 -c "
import json, sys
d = json.load(open('$_TUI_STATUS_FILE'))
ev = (d.get('recent_events') or [])
if not ev:
    print('<EMPTY>')
    sys.exit(0)
# Print the last event as JSON so tests can assert on specific fields.
print(json.dumps(ev[-1], sort_keys=True))
" 2>/dev/null
}

_event_field() {
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
ev = (d.get('recent_events') or [])
if not ev:
    print('<MISSING>')
else:
    v = ev[-1].get('$1')
    print('<MISSING>' if v is None else v)
" 2>/dev/null
}

# =============================================================================
echo "=== M117-1: substage active → source='parent » substage' ==="
_activate
tui_stage_begin "coder" "claude-opus-4-7"
tui_substage_begin "scout" "claude-haiku-4-5"
log "scanning repo map"

got=$(_event_field source)
if [[ "$got" == "coder » scout" ]]; then
    pass "M117-1a: source='coder » scout' for event emitted during substage"
else
    fail "M117-1a" "expected 'coder » scout', got '$got'"
fi
got_msg=$(_event_field msg)
if [[ "$got_msg" == "scanning repo map" ]]; then
    pass "M117-1b: msg body unchanged by attribution"
else
    fail "M117-1b" "expected 'scanning repo map', got '$got_msg'"
fi

# =============================================================================
echo "=== M117-2: stage active, no substage → source=stage label ==="
_activate
tui_stage_begin "coder" "claude-opus-4-7"
log "coder starting"

got=$(_event_field source)
if [[ "$got" == "coder" ]]; then
    pass "M117-2: source='coder' for stage-only event"
else
    fail "M117-2" "expected 'coder', got '$got'"
fi

# =============================================================================
echo "=== M117-3: no stage active → no source field in JSON ==="
_activate
# No tui_stage_begin called — events emitted before any stage.
log "startup banner"

json=$(_last_event_json)
if [[ "$json" != *'"source"'* ]]; then
    pass "M117-3: source field absent in JSON when no stage/substage active"
else
    fail "M117-3" "expected no 'source' key in JSON, got: $json"
fi

# =============================================================================
echo "=== M117-4: substage ends → source reverts to stage label ==="
_activate
tui_stage_begin "coder" "claude-opus-4-7"
tui_substage_begin "scout" "claude-haiku-4-5"
log "during scout"
tui_substage_end "scout" "PASS"
log "after scout"

# Now check the last event (after substage ended).
got=$(_event_field source)
if [[ "$got" == "coder" ]]; then
    pass "M117-4: source reverts to 'coder' after substage ends"
else
    fail "M117-4" "expected 'coder', got '$got'"
fi

# =============================================================================
echo "=== M117-5: TUI_LIFECYCLE_V2=false disables attribution ==="
_activate
TUI_LIFECYCLE_V2=false
# Even with stage+substage set, attribution must be suppressed.
_TUI_CURRENT_STAGE_LABEL="coder"
_TUI_CURRENT_SUBSTAGE_LABEL="scout"
log "opt-out path"

json=$(_last_event_json)
if [[ "$json" != *'"source"'* ]]; then
    pass "M117-5: source field absent when TUI_LIFECYCLE_V2=false"
else
    fail "M117-5" "expected no 'source' in JSON under opt-out, got: $json"
fi

# =============================================================================
echo "=== M117-6: attribution not leaked into plaintext LOG_FILE ==="
_activate
tui_stage_begin "coder" "claude-opus-4-7"
tui_substage_begin "scout" "claude-haiku-4-5"
log "secret log line"

if grep -qF "[coder » scout]" "$LOG_FILE" 2>/dev/null; then
    fail "M117-6a" "attribution breadcrumb leaked into LOG_FILE"
elif grep -qF "secret log line" "$LOG_FILE" 2>/dev/null; then
    pass "M117-6a: LOG_FILE contains message body without breadcrumb"
else
    fail "M117-6a" "LOG_FILE did not capture the logged message (verify test setup)"
fi

# And the TUI status JSON DOES carry it.
got=$(_event_field source)
if [[ "$got" == "coder » scout" ]]; then
    pass "M117-6b: JSON event carries breadcrumb even though LOG_FILE does not"
else
    fail "M117-6b" "expected 'coder » scout' in JSON, got '$got'"
fi

# =============================================================================
echo "=== M117-7: event ring buffer depth honoured under new format ==="
_activate
export TUI_EVENT_LINES=3
tui_stage_begin "coder" "claude-opus-4-7"
log "event-1"
log "event-2"
log "event-3"
log "event-4"
log "event-5"

count=$(python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
print(len(d.get('recent_events') or []))
")
if [[ "$count" == "3" ]]; then
    pass "M117-7: ring buffer retained exactly 3 entries (TUI_EVENT_LINES)"
else
    fail "M117-7" "expected 3 events, got '$count'"
fi
first_msg=$(python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
ev = d.get('recent_events') or []
print(ev[0].get('msg', '') if ev else '')
")
if [[ "$first_msg" == "event-3" ]]; then
    pass "M117-7b: oldest retained event is event-3 (events 1–2 evicted)"
else
    fail "M117-7b" "expected 'event-3', got '$first_msg'"
fi

# =============================================================================
echo "=== M117-8: msg containing '|' round-trips intact under new format ==="
_activate
tui_stage_begin "coder" "claude-opus-4-7"
log "piped | message | with | pipes"

got_msg=$(_event_field msg)
if [[ "$got_msg" == "piped | message | with | pipes" ]]; then
    pass "M117-8: msg containing '|' preserved (msg is last field in serialisation)"
else
    fail "M117-8" "expected 'piped | message | with | pipes', got '$got_msg'"
fi

# =============================================================================
echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
