#!/usr/bin/env bash
# =============================================================================
# test_tui_action_items.sh — M102 — verify TUI JSON action_items field flows
# from the Output Bus (_OUT_CTX[action_items]) rather than a hardcoded "[]".
#
# Primary fix of M102: before this milestone, lib/tui_helpers.sh emitted the
# literal "action_items":[], — so every hold-on-complete screen lost the
# action items accumulated by out_action_item. After M102, the items flow
# through _OUT_CTX[action_items] and appear in the sidecar hold screen.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Stub dependencies required before sourcing tui.sh
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# shellcheck source=../lib/tui.sh
source "${TEKHTON_HOME}/lib/tui.sh"

# output.sh expects these; tui.sh's stubs define them.
_tui_strip_ansi() { printf '%s' "$*"; }
_tui_notify()     { :; }
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""

# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"
# shellcheck source=../lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

_activate_tui_globals() {
    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$TMPDIR_TEST/status.json"
    _TUI_STATUS_TMP="$TMPDIR_TEST/status.json.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)
    _TUI_RECENT_EVENTS=()
    _TUI_STAGES_COMPLETE=()
    _TUI_CURRENT_STAGE_LABEL=""
    _TUI_CURRENT_STAGE_MODEL=""
    _TUI_CURRENT_STAGE_NUM=0
    _TUI_CURRENT_STAGE_TOTAL=0
    _TUI_AGENT_TURNS_USED=0
    _TUI_AGENT_TURNS_MAX=0
    _TUI_AGENT_ELAPSED_SECS=0
    _TUI_AGENT_STATUS="idle"
    _TUI_COMPLETE=false
    _TUI_VERDICT=""
    TASK="test-task"
    _CURRENT_MILESTONE="102"
    _CURRENT_RUN_ID="run-test"
    MAX_PIPELINE_ATTEMPTS=5
}

_write_status() {
    _tui_json_build_status 0 > "$_TUI_STATUS_FILE"
}

_read_json_action_items_count() {
    python3 -c "import json; d=json.load(open('$_TUI_STATUS_FILE')); print(len(d.get('action_items') or []))" 2>/dev/null
}

_read_json_first_action_msg() {
    python3 -c "import json; d=json.load(open('$_TUI_STATUS_FILE')); a=d.get('action_items') or []; print((a[0] if a else {}).get('msg', ''))" 2>/dev/null
}

_read_json_first_action_sev() {
    python3 -c "import json; d=json.load(open('$_TUI_STATUS_FILE')); a=d.get('action_items') or []; print((a[0] if a else {}).get('severity', ''))" 2>/dev/null
}

_is_valid_json() {
    python3 -c "import json, sys; json.load(open('$1'))" 2>/dev/null
}

# =============================================================================
echo "=== Test 1: empty _OUT_CTX[action_items] → JSON action_items=[] ==="

_activate_tui_globals
out_init
_write_status

if _is_valid_json "$_TUI_STATUS_FILE"; then
    pass "JSON is valid when action_items is empty"
else
    fail "JSON parse" "invalid JSON when _OUT_CTX[action_items] is empty"
fi

count=$(_read_json_action_items_count)
if [[ "$count" -eq 0 ]]; then
    pass "action_items is empty array when _OUT_CTX[action_items] is unset"
else
    fail "action_items count" "expected 0, got $count"
fi

# =============================================================================
echo "=== Test 2: out_action_item accumulates into JSON ==="

_activate_tui_globals
out_init
out_action_item "Fix the config" "warning"
_write_status

if ! _is_valid_json "$_TUI_STATUS_FILE"; then
    fail "JSON parse" "invalid JSON after one out_action_item call"
fi

count=$(_read_json_action_items_count)
if [[ "$count" -eq 1 ]]; then
    pass "JSON has 1 action item after one out_action_item call"
else
    fail "action_items count" "expected 1, got $count"
fi

msg=$(_read_json_first_action_msg)
if [[ "$msg" == "Fix the config" ]]; then
    pass "action item msg preserved in JSON"
else
    fail "action item msg" "expected 'Fix the config', got '$msg'"
fi

sev=$(_read_json_first_action_sev)
if [[ "$sev" == "warning" ]]; then
    pass "action item severity preserved in JSON"
else
    fail "action item severity" "expected 'warning', got '$sev'"
fi

# =============================================================================
echo "=== Test 3: multiple out_action_item calls produce valid JSON array ==="

_activate_tui_globals
out_init
out_action_item "First item" "normal"
out_action_item "Second item" "warning"
out_action_item "Third item" "critical"
_write_status

if ! _is_valid_json "$_TUI_STATUS_FILE"; then
    fail "JSON parse" "invalid JSON after three out_action_item calls"
fi

count=$(_read_json_action_items_count)
if [[ "$count" -eq 3 ]]; then
    pass "JSON has 3 action items after three out_action_item calls"
else
    fail "action_items count" "expected 3, got $count"
fi

# =============================================================================
echo "=== Test 4: JSON-escaped content survives round-trip ==="

_activate_tui_globals
out_init
out_action_item 'Item with "quotes" and \\backslashes' "critical"
_write_status

if ! _is_valid_json "$_TUI_STATUS_FILE"; then
    fail "JSON parse" "JSON-escaped action item produced invalid JSON"
fi

msg=$(_read_json_first_action_msg)
# Bash string 'Item with "quotes" and \\backslashes' is a literal with two
# backslashes; _out_json_escape doubles each, Python json re-halves each back.
if [[ "$msg" == 'Item with "quotes" and \\backslashes' ]]; then
    pass "JSON escaping round-trips quotes and backslashes"
else
    fail "escaped msg" "expected quotes/backslashes preserved, got '$msg'"
fi

# =============================================================================
echo "=== Test 5: without _OUT_CTX defined, action_items falls back to [] ==="

_activate_tui_globals
if declare -p _OUT_CTX &>/dev/null; then
    unset _OUT_CTX
fi
_write_status

if _is_valid_json "$_TUI_STATUS_FILE"; then
    pass "JSON valid when _OUT_CTX is undefined"
else
    fail "JSON parse" "invalid JSON when _OUT_CTX missing"
fi

count=$(_read_json_action_items_count)
if [[ "$count" -eq 0 ]]; then
    pass "action_items falls back to [] when _OUT_CTX is undefined"
else
    fail "action_items fallback" "expected 0, got $count"
fi

# =============================================================================
echo "=== Test 6: no hardcoded 'action_items:[]' emission in tui_helpers.sh ==="

# M102 acceptance criterion: the literal string "action_items":[] must no
# longer appear in lib/tui_helpers.sh — the value is computed at call time.
if grep -q 'action_items.*\[\]' "${TEKHTON_HOME}/lib/tui_helpers.sh"; then
    fail "hardcoded empty action_items" "grep found 'action_items.*\[\]' in lib/tui_helpers.sh"
else
    pass "no hardcoded action_items:[] pattern in lib/tui_helpers.sh"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
