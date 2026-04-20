#!/usr/bin/env bash
# =============================================================================
# test_tui_active_path.sh — M97 — verify active-path write cycle for TUI
# update functions.
#
# The fallback tests only check that inactive functions are no-ops. This file
# verifies that when _TUI_ACTIVE=true the update functions mutate the globals
# AND atomically write a valid JSON status file reflecting those mutations.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"
export TEKHTON_SESSION_DIR="$TMPDIR/session"
mkdir -p "$TEKHTON_SESSION_DIR"

log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/tui.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Shared JSON reader helper — requires python3 available (same as existing tests)
_read_json() {
    local file="$1" key="$2"
    python3 -c "import json,sys; d=json.load(open('$file')); print(d.get('$key',''))" 2>/dev/null
}
_read_json_int() {
    local file="$1" key="$2"
    python3 -c "import json,sys; d=json.load(open('$file')); print(int(d.get('$key',0)))" 2>/dev/null
}

# --- Shared activation setup -------------------------------------------------
_activate_tui() {
    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$TMPDIR/status.json"
    _TUI_STATUS_TMP="$TMPDIR/status.json.tmp"
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
    _CURRENT_MILESTONE="97"
    _CURRENT_RUN_ID="run-test"
}

# =============================================================================
echo "=== Test 1: tui_update_stage writes correct fields ==="
_activate_tui

tui_update_stage 2 5 "Tester" "claude-haiku-4-5"

if [[ ! -f "$_TUI_STATUS_FILE" ]]; then
    fail "tui_update_stage did not write status file" ""
else
    # Verify globals were updated
    if [[ "$_TUI_CURRENT_STAGE_NUM" -eq 2 ]]; then
        pass "tui_update_stage set _TUI_CURRENT_STAGE_NUM=2"
    else
        fail "_TUI_CURRENT_STAGE_NUM" "expected 2, got $_TUI_CURRENT_STAGE_NUM"
    fi

    if [[ "$_TUI_CURRENT_STAGE_LABEL" == "Tester" ]]; then
        pass "tui_update_stage set _TUI_CURRENT_STAGE_LABEL=Tester"
    else
        fail "_TUI_CURRENT_STAGE_LABEL" "expected Tester, got $_TUI_CURRENT_STAGE_LABEL"
    fi

    if [[ "$_TUI_AGENT_STATUS" == "running" ]]; then
        pass "tui_update_stage set agent_status=running"
    else
        fail "_TUI_AGENT_STATUS" "expected running, got $_TUI_AGENT_STATUS"
    fi

    # Verify JSON content
    label_val=$(_read_json "$_TUI_STATUS_FILE" "stage_label")
    if [[ "$label_val" == "Tester" ]]; then
        pass "status JSON stage_label=Tester after tui_update_stage"
    else
        fail "status JSON stage_label" "expected Tester, got $label_val"
    fi

    stage_num_val=$(_read_json_int "$_TUI_STATUS_FILE" "stage_num")
    if [[ "$stage_num_val" -eq 2 ]]; then
        pass "status JSON stage_num=2 after tui_update_stage"
    else
        fail "status JSON stage_num" "expected 2, got $stage_num_val"
    fi

    stage_total_val=$(_read_json_int "$_TUI_STATUS_FILE" "stage_total")
    if [[ "$stage_total_val" -eq 5 ]]; then
        pass "status JSON stage_total=5 after tui_update_stage"
    else
        fail "status JSON stage_total" "expected 5, got $stage_total_val"
    fi

    model_val=$(_read_json "$_TUI_STATUS_FILE" "agent_model")
    if [[ "$model_val" == "claude-haiku-4-5" ]]; then
        pass "status JSON agent_model=claude-haiku-4-5 after tui_update_stage"
    else
        fail "status JSON agent_model" "expected claude-haiku-4-5, got $model_val"
    fi

    # tui_update_stage resets turn counters to 0
    turns_val=$(_read_json_int "$_TUI_STATUS_FILE" "agent_turns_used")
    if [[ "$turns_val" -eq 0 ]]; then
        pass "status JSON agent_turns_used reset to 0 on stage start"
    else
        fail "status JSON agent_turns_used" "expected 0 after stage start, got $turns_val"
    fi
fi

# =============================================================================
echo "=== Test 2: tui_update_agent writes turn and elapsed fields ==="
_activate_tui
tui_update_stage 1 3 "Coder" "claude-opus-4-7"
tui_update_agent 15 60 88

if [[ ! -f "$_TUI_STATUS_FILE" ]]; then
    fail "tui_update_agent did not write status file" ""
else
    # Verify globals
    if [[ "$_TUI_AGENT_TURNS_USED" -eq 15 ]]; then
        pass "tui_update_agent set _TUI_AGENT_TURNS_USED=15"
    else
        fail "_TUI_AGENT_TURNS_USED" "expected 15, got $_TUI_AGENT_TURNS_USED"
    fi

    if [[ "$_TUI_AGENT_TURNS_MAX" -eq 60 ]]; then
        pass "tui_update_agent set _TUI_AGENT_TURNS_MAX=60"
    else
        fail "_TUI_AGENT_TURNS_MAX" "expected 60, got $_TUI_AGENT_TURNS_MAX"
    fi

    if [[ "$_TUI_AGENT_ELAPSED_SECS" -eq 88 ]]; then
        pass "tui_update_agent set _TUI_AGENT_ELAPSED_SECS=88"
    else
        fail "_TUI_AGENT_ELAPSED_SECS" "expected 88, got $_TUI_AGENT_ELAPSED_SECS"
    fi

    if [[ "$_TUI_AGENT_STATUS" == "running" ]]; then
        pass "tui_update_agent set _TUI_AGENT_STATUS=running"
    else
        fail "_TUI_AGENT_STATUS" "expected running, got $_TUI_AGENT_STATUS"
    fi

    # Verify JSON reflects the update
    turns_used_val=$(_read_json_int "$_TUI_STATUS_FILE" "agent_turns_used")
    if [[ "$turns_used_val" -eq 15 ]]; then
        pass "status JSON agent_turns_used=15 after tui_update_agent"
    else
        fail "status JSON agent_turns_used" "expected 15, got $turns_used_val"
    fi

    turns_max_val=$(_read_json_int "$_TUI_STATUS_FILE" "agent_turns_max")
    if [[ "$turns_max_val" -eq 60 ]]; then
        pass "status JSON agent_turns_max=60 after tui_update_agent"
    else
        fail "status JSON agent_turns_max" "expected 60, got $turns_max_val"
    fi

    elapsed_val=$(_read_json_int "$_TUI_STATUS_FILE" "agent_elapsed_secs")
    if [[ "$elapsed_val" -eq 88 ]]; then
        pass "status JSON agent_elapsed_secs=88 after tui_update_agent"
    else
        fail "status JSON agent_elapsed_secs" "expected 88, got $elapsed_val"
    fi

    # current_agent_status should be "running"
    status_val=$(_read_json "$_TUI_STATUS_FILE" "current_agent_status")
    if [[ "$status_val" == "running" ]]; then
        pass "status JSON current_agent_status=running after tui_update_agent"
    else
        fail "status JSON current_agent_status" "expected running, got $status_val"
    fi
fi

# =============================================================================
echo "=== Test 3: tui_finish_stage appends stage to stages_complete ==="
_activate_tui
tui_update_stage 1 2 "Reviewer" "claude-sonnet-4-6"
tui_finish_stage "Reviewer" "claude-sonnet-4-6" "8/20" "45s" "APPROVED"

if [[ ! -f "$_TUI_STATUS_FILE" ]]; then
    fail "tui_finish_stage did not write status file" ""
else
    # Verify global array was updated
    if [[ "${#_TUI_STAGES_COMPLETE[@]}" -eq 1 ]]; then
        pass "tui_finish_stage appended one entry to _TUI_STAGES_COMPLETE"
    else
        fail "_TUI_STAGES_COMPLETE length" "expected 1, got ${#_TUI_STAGES_COMPLETE[@]}"
    fi

    # agent status should return to idle
    if [[ "$_TUI_AGENT_STATUS" == "idle" ]]; then
        pass "tui_finish_stage set _TUI_AGENT_STATUS=idle"
    else
        fail "_TUI_AGENT_STATUS after finish" "expected idle, got $_TUI_AGENT_STATUS"
    fi

    # JSON stages_complete must be an array of length 1 with correct fields
    python3 -c "
import json, sys
d = json.load(open('$_TUI_STATUS_FILE'))
stages = d.get('stages_complete', [])
if len(stages) != 1:
    sys.exit(1)
s = stages[0]
assert s['label'] == 'Reviewer', f'label={s[\"label\"]}'
assert s['model'] == 'claude-sonnet-4-6', f'model={s[\"model\"]}'
assert s['turns'] == '8/20', f'turns={s[\"turns\"]}'
assert s['time'] == '45s', f'time={s[\"time\"]}'
assert s['verdict'] == 'APPROVED', f'verdict={s[\"verdict\"]}'
" 2>/dev/null && pass "status JSON stages_complete[0] has correct label/model/turns/time/verdict" \
    || fail "stages_complete JSON fields" "$(python3 -c "import json; d=json.load(open('$_TUI_STATUS_FILE')); print(d.get('stages_complete'))" 2>/dev/null)"

    status_val=$(_read_json "$_TUI_STATUS_FILE" "current_agent_status")
    if [[ "$status_val" == "idle" ]]; then
        pass "status JSON current_agent_status=idle after tui_finish_stage"
    else
        fail "status JSON current_agent_status after finish" "expected idle, got $status_val"
    fi
fi

# =============================================================================
echo "=== Test 4: tui_finish_stage accumulates multiple stages ==="
_activate_tui
tui_update_stage 1 3 "Coder" "claude-opus-4-7"
tui_finish_stage "Coder" "claude-opus-4-7" "30/70" "120s" "PASS"
tui_update_stage 2 3 "Reviewer" "claude-sonnet-4-6"
tui_finish_stage "Reviewer" "claude-sonnet-4-6" "5/15" "30s" "APPROVED"

if [[ "${#_TUI_STAGES_COMPLETE[@]}" -eq 2 ]]; then
    pass "two tui_finish_stage calls produced two _TUI_STAGES_COMPLETE entries"
else
    fail "_TUI_STAGES_COMPLETE length" "expected 2, got ${#_TUI_STAGES_COMPLETE[@]}"
fi

python3 -c "
import json, sys
d = json.load(open('$_TUI_STATUS_FILE'))
stages = d.get('stages_complete', [])
if len(stages) != 2:
    sys.exit(1)
assert stages[0]['label'] == 'Coder'
assert stages[1]['label'] == 'Reviewer'
" 2>/dev/null && pass "stages_complete JSON contains both stages in order" \
    || fail "stages_complete order" "$(python3 -c "import json; d=json.load(open('$_TUI_STATUS_FILE')); print([s.get('label') for s in d.get('stages_complete',[])])" 2>/dev/null)"

# =============================================================================
echo "=== Test 5: tui_finish_stage with empty verdict produces null ==="
_activate_tui
tui_update_stage 1 1 "Scout" "claude-haiku-4-5"
tui_finish_stage "Scout" "claude-haiku-4-5" "3/10" "10s" ""

python3 -c "
import json, sys
d = json.load(open('$_TUI_STATUS_FILE'))
stages = d.get('stages_complete', [])
assert len(stages) == 1
assert stages[0]['verdict'] is None, f'expected null verdict, got {stages[0][\"verdict\"]}'
" 2>/dev/null && pass "empty verdict produces null in stages_complete JSON" \
    || fail "empty verdict JSON" "$(python3 -c "import json; d=json.load(open('$_TUI_STATUS_FILE')); print(d.get('stages_complete'))" 2>/dev/null)"

# =============================================================================
echo "=== Test 6: tui_stage_begin appends a new label to _TUI_STAGE_ORDER ==="
_activate_tui
_TUI_STAGE_ORDER=("intake" "coder" "tester")

tui_stage_begin "rework" "claude-opus-4-7"

if [[ "${#_TUI_STAGE_ORDER[@]}" -eq 4 ]]; then
    pass "tui_stage_begin appended new label (length 4)"
else
    fail "_TUI_STAGE_ORDER length" "expected 4, got ${#_TUI_STAGE_ORDER[@]}"
fi

if [[ "${_TUI_STAGE_ORDER[3]}" == "rework" ]]; then
    pass "tui_stage_begin appended 'rework' at end"
else
    fail "_TUI_STAGE_ORDER[3]" "expected rework, got ${_TUI_STAGE_ORDER[3]}"
fi

if [[ "$_TUI_CURRENT_STAGE_NUM" -eq 4 ]]; then
    pass "tui_stage_begin set stage_num to 1-based index (4)"
else
    fail "_TUI_CURRENT_STAGE_NUM" "expected 4, got $_TUI_CURRENT_STAGE_NUM"
fi

if [[ "$_TUI_CURRENT_STAGE_LABEL" == "rework" ]]; then
    pass "tui_stage_begin set label to 'rework'"
else
    fail "_TUI_CURRENT_STAGE_LABEL" "expected rework, got $_TUI_CURRENT_STAGE_LABEL"
fi

# =============================================================================
echo "=== Test 7: tui_stage_begin does not duplicate existing label ==="
_activate_tui
_TUI_STAGE_ORDER=("intake" "coder")

tui_stage_begin "coder" "claude-opus-4-7"

if [[ "${#_TUI_STAGE_ORDER[@]}" -eq 2 ]]; then
    pass "tui_stage_begin did not duplicate existing label"
else
    fail "_TUI_STAGE_ORDER length" "expected 2, got ${#_TUI_STAGE_ORDER[@]}"
fi

if [[ "$_TUI_CURRENT_STAGE_NUM" -eq 2 ]]; then
    pass "tui_stage_begin returned correct 1-based index for existing label"
else
    fail "_TUI_CURRENT_STAGE_NUM" "expected 2, got $_TUI_CURRENT_STAGE_NUM"
fi

# =============================================================================
echo "=== Test 8: tui_stage_end freezes timer and stores elapsed ==="
_activate_tui
_TUI_STAGE_ORDER=("coder")
tui_stage_begin "coder" "claude-opus-4-7"
# Simulate 3 seconds of elapsed time
_TUI_STAGE_START_TS=$(( $(date +%s) - 3 ))

tui_stage_end "coder" "claude-opus-4-7" "5/10" "3s" "PASS"

if [[ "$_TUI_STAGE_START_TS" -eq 0 ]]; then
    pass "tui_stage_end zeroed _TUI_STAGE_START_TS"
else
    fail "_TUI_STAGE_START_TS after end" "expected 0, got $_TUI_STAGE_START_TS"
fi

if [[ "$_TUI_AGENT_ELAPSED_SECS" -ge 3 ]]; then
    pass "tui_stage_end stored positive elapsed (${_TUI_AGENT_ELAPSED_SECS}s)"
else
    fail "_TUI_AGENT_ELAPSED_SECS" "expected >= 3, got $_TUI_AGENT_ELAPSED_SECS"
fi

if [[ "${#_TUI_STAGES_COMPLETE[@]}" -eq 1 ]]; then
    pass "tui_stage_end delegated to tui_finish_stage (stages_complete length=1)"
else
    fail "_TUI_STAGES_COMPLETE length after end" "expected 1, got ${#_TUI_STAGES_COMPLETE[@]}"
fi

# =============================================================================
echo "=== Test 9: repeat tui_stage_begin after tui_stage_end does not duplicate ==="
_activate_tui
_TUI_STAGE_ORDER=()
tui_stage_begin "rework" "claude-opus-4-7"
tui_stage_end "rework" "claude-opus-4-7" "3/10" "5s" "PASS"
tui_stage_begin "rework" "claude-opus-4-7"

if [[ "${#_TUI_STAGE_ORDER[@]}" -eq 1 ]]; then
    pass "second tui_stage_begin with same label did not duplicate"
else
    fail "_TUI_STAGE_ORDER length (multi-rework)" "expected 1, got ${#_TUI_STAGE_ORDER[@]}"
fi

# =============================================================================
echo "=== Test 10: tui_stage_begin is a no-op when _TUI_ACTIVE=false ==="
_activate_tui
_TUI_ACTIVE=false
rm -f "$_TUI_STATUS_FILE"
_TUI_STAGE_ORDER=()

tui_stage_begin "rework" "claude-opus-4-7"

if [[ ! -f "$_TUI_STATUS_FILE" ]]; then
    pass "tui_stage_begin no-op when _TUI_ACTIVE=false (no status file write)"
else
    fail "tui_stage_begin" "wrote status file despite _TUI_ACTIVE=false"
fi

if [[ "${#_TUI_STAGE_ORDER[@]}" -eq 0 ]]; then
    pass "tui_stage_begin no-op did not mutate _TUI_STAGE_ORDER"
else
    fail "_TUI_STAGE_ORDER inactive" "expected 0, got ${#_TUI_STAGE_ORDER[@]}"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
