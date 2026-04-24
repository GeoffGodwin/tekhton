#!/usr/bin/env bash
# =============================================================================
# test_run_op_lifecycle.sh — M104 (lifecycle) + M115 (substage migration).
#
# run_op wraps a long-running shell command in TUI "working" state. In M115
# the operation label is registered via the M113 substage API; the legacy
# bash global and JSON override it replaced are both gone. These tests verify:
#   - passthrough behavior when _TUI_ACTIVE=false (zero TUI overhead)
#   - exit code preservation (success and failure paths)
#   - agent_status transitions: idle → working → idle
#   - current_substage_label in the JSON reflects the run_op label while the
#     wrapped command executes, and clears to "" after return
#   - the parent stage's current_stage_label is never mutated by run_op
#   - background heartbeat subprocess is cleaned up
#   - common.sh stub passthrough still works when tui.sh is not loaded
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# ── Stubs required before sourcing tui.sh ─────────────────────────────────────
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/tui.sh"

# output.sh requires _tui_strip_ansi and _tui_notify from common.sh
_tui_strip_ansi() { printf '%s' "$*"; }
_tui_notify()     { :; }
# shellcheck disable=SC2034
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/output.sh"

# ── Shared helpers ─────────────────────────────────────────────────────────────

_setup_tui_active() {
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
    _TUI_CURRENT_SUBSTAGE_LABEL=""
    _TUI_CURRENT_SUBSTAGE_START_TS=0
    _TUI_COMPLETE=false
    _TUI_VERDICT=""
    _TUI_RUN_MODE="task"
    _TUI_CLI_FLAGS=""
    # shellcheck disable=SC2034
    TASK="test-task"
    # shellcheck disable=SC2034
    _CURRENT_MILESTONE="115"
    # shellcheck disable=SC2034
    _CURRENT_RUN_ID="run-test"
    # shellcheck disable=SC2034
    MAX_PIPELINE_ATTEMPTS=3
    rm -f "$TMPDIR_TEST/status.json" "$TMPDIR_TEST/status.json.tmp"
}

_json_field() {
    local file="$1" field="$2"
    python3 -c "import json; d=json.load(open('$file')); print(d.get('$field', ''))" 2>/dev/null
}

# =============================================================================
echo "=== Test 1: passthrough — run_op is transparent when TUI inactive ==="

_TUI_ACTIVE=false
output=$(run_op "ignored label" echo "hello world")
if [[ "$output" == "hello world" ]]; then
    pass "passthrough: output of wrapped command is returned unchanged"
else
    fail "passthrough output" "expected 'hello world', got '$output'"
fi

# =============================================================================
echo "=== Test 2: passthrough — label is consumed, not forwarded to wrapped command ==="

_TUI_ACTIVE=false
# If label were passed to the command, args would be: "label text" "count"
output=$(run_op "label text" printf '%s\n' "count")
if [[ "$output" == "count" ]]; then
    pass "passthrough: label is consumed by run_op, not forwarded to command"
else
    fail "passthrough label consumed" "expected 'count', got '$output'"
fi

# =============================================================================
echo "=== Test 3: passthrough — exit code of wrapped command is preserved (success) ==="

_TUI_ACTIVE=false
rc=0
run_op "label" true || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "passthrough: exit code 0 preserved for successful command"
else
    fail "passthrough exit code success" "expected 0, got $rc"
fi

# =============================================================================
echo "=== Test 4: passthrough — exit code of wrapped command is preserved (failure) ==="

_TUI_ACTIVE=false
rc=0
run_op "label" false || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "passthrough: exit code 1 preserved for failing command"
else
    fail "passthrough exit code failure" "expected 1, got $rc"
fi

# =============================================================================
echo "=== Test 5: no status file written during passthrough ==="

_TUI_ACTIVE=false
status_file="$TMPDIR_TEST/no_write_status.json"
rm -f "$status_file"
_TUI_STATUS_FILE="$status_file"
_TUI_STATUS_TMP="${status_file}.tmp"
run_op "label" true || true
if [[ ! -f "$status_file" ]]; then
    pass "passthrough: no status file written when TUI inactive"
else
    fail "passthrough no status file" "status file was written unexpectedly"
fi

# =============================================================================
echo "=== Test 6: current_operation field absent from _tui_json_build_status output ==="

# M115: the current_operation field is retired. The JSON must not carry it.
_setup_tui_active
_TUI_AGENT_STATUS="working"
json=$(_tui_json_build_status 0)

if printf '%s' "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'current_operation' not in d else 1)" 2>/dev/null; then
    pass "JSON schema: current_operation field is absent (retired in M115)"
else
    fail "JSON schema" "current_operation field still emitted by _tui_json_build_status"
fi

# =============================================================================
echo "=== Test 7: current_substage_label carries the run_op label during execution ==="

_setup_tui_active
export _STATUS_FILE_FOR_TEST="$_TUI_STATUS_FILE"

# The wrapped command reads the status file AFTER run_op has written the
# substage state into it. run_op writes the status file, then runs "$@", so
# the file is already in "working"+substage state when the command executes.
# shellcheck disable=SC2016  # single-quoted intentionally; expands in subshell where var is exported
during_json=$(run_op "Running test baseline" bash -c 'cat "$_STATUS_FILE_FOR_TEST"')

sub_val=$(printf '%s' "$during_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_substage_label',''))" 2>/dev/null)
if [[ "$sub_val" == "Running test baseline" ]]; then
    pass "run_op: current_substage_label=LABEL in status file during execution"
else
    fail "run_op current_substage_label during execution" "expected 'Running test baseline', got '$sub_val'"
fi

# =============================================================================
echo "=== Test 8: agent_status is 'working' during run_op execution ==="

_setup_tui_active
export _STATUS_FILE_FOR_TEST="$_TUI_STATUS_FILE"

# shellcheck disable=SC2016
during_json=$(run_op "Running test baseline" bash -c 'cat "$_STATUS_FILE_FOR_TEST"')
agent_status=$(printf '%s' "$during_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_agent_status',''))" 2>/dev/null)
if [[ "$agent_status" == "working" ]]; then
    pass "run_op: current_agent_status=working in status file during execution"
else
    fail "run_op working status during execution" "expected 'working', got '$agent_status'"
fi

# =============================================================================
echo "=== Test 9: parent stage_label is NOT mutated by run_op ==="

# The core M115 invariant: run_op registers as a substage, never as a stage.
# If a parent stage is already open (stage_label=coder) the wrapped command
# must observe the parent label unchanged.
_setup_tui_active
_TUI_CURRENT_STAGE_LABEL="coder"
_TUI_STAGE_START_TS=$(date +%s)
export _STATUS_FILE_FOR_TEST="$_TUI_STATUS_FILE"

# shellcheck disable=SC2016
during_json=$(run_op "Running completion tests" bash -c 'cat "$_STATUS_FILE_FOR_TEST"')
parent_label=$(printf '%s' "$during_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('stage_label',''))" 2>/dev/null)
if [[ "$parent_label" == "coder" ]]; then
    pass "run_op: parent stage_label preserved (coder) during run_op"
else
    fail "run_op parent stage preservation" "expected 'coder', got '$parent_label'"
fi

# =============================================================================
echo "=== Test 10: stages_complete is NOT appended to by run_op ==="

# A run_op is a substage; it must never produce a stages_complete entry.
_setup_tui_active
_TUI_CURRENT_STAGE_LABEL="coder"
_TUI_STAGE_START_TS=$(date +%s)

run_op "Running completion tests" true

stages_count=$(python3 -c "import json; print(len(json.load(open('$_TUI_STATUS_FILE'))['stages_complete']))")
if [[ "$stages_count" == "0" ]]; then
    pass "run_op: stages_complete is not appended to (run_op is a substage, not a stage)"
else
    fail "run_op stages_complete untouched" "expected 0 entries, got $stages_count"
fi

# =============================================================================
echo "=== Test 11: run_op restores idle status after successful command ==="

_setup_tui_active

run_op "label" true

after_status=$(_json_field "$_TUI_STATUS_FILE" "current_agent_status")
if [[ "$after_status" == "idle" ]]; then
    pass "run_op: current_agent_status=idle in status file after success"
else
    fail "run_op idle after success" "expected 'idle', got '$after_status'"
fi

# =============================================================================
echo "=== Test 12: run_op clears current_substage_label after successful command ==="

_setup_tui_active

run_op "My Operation" true

after_sub=$(_json_field "$_TUI_STATUS_FILE" "current_substage_label")
if [[ "$after_sub" == "" ]]; then
    pass "run_op: current_substage_label='' in status file after success"
else
    fail "run_op current_substage_label cleared after success" "expected '', got '$after_sub'"
fi

# =============================================================================
echo "=== Test 13: run_op restores idle status after failing command ==="

_setup_tui_active

rc=0
run_op "My Operation" false || rc=$?

after_status=$(_json_field "$_TUI_STATUS_FILE" "current_agent_status")
if [[ "$after_status" == "idle" ]]; then
    pass "run_op: current_agent_status=idle in status file after failure"
else
    fail "run_op idle after failure" "expected 'idle', got '$after_status'"
fi

# =============================================================================
echo "=== Test 14: run_op preserves exit code from failing command (TUI active) ==="

_setup_tui_active

rc=0
run_op "My Operation" false || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "run_op: exit code 1 preserved for failing command when TUI active"
else
    fail "run_op exit code preserved on failure" "expected 1, got $rc"
fi

# =============================================================================
echo "=== Test 15: run_op clears current_substage_label after failing command ==="

_setup_tui_active

run_op "My Operation" false || true

after_sub=$(_json_field "$_TUI_STATUS_FILE" "current_substage_label")
if [[ "$after_sub" == "" ]]; then
    pass "run_op: current_substage_label='' cleared after failure"
else
    fail "run_op current_substage_label cleared after failure" "expected '', got '$after_sub'"
fi

# =============================================================================
echo "=== Test 16: run_op leaves no background processes after completion ==="

_setup_tui_active

run_op "label" true

# Count jobs in current shell — heartbeat must be cleaned up
job_count=$(jobs -r | wc -l | tr -d ' ')
if [[ "$job_count" -eq 0 ]]; then
    pass "run_op: no background processes remain after successful call"
else
    fail "run_op background cleanup" "expected 0 background jobs, got $job_count"
fi

# =============================================================================
echo "=== Test 17: common.sh stub is overridden by tui_ops.sh implementation ==="

# In normal pipeline execution: common.sh is sourced first (defines stub),
# then tui.sh is sourced (which sources tui_ops.sh, redefining run_op with
# the full TUI implementation). Verify the final definition references the
# TUI guard (_TUI_ACTIVE) and the substage API (tui_substage_begin).
fn_body=$(declare -f run_op)
if printf '%s' "$fn_body" | grep -q "_TUI_ACTIVE" \
   && printf '%s' "$fn_body" | grep -q "tui_substage_begin"; then
    pass "run_op definition (after tui.sh sourced) is the TUI + substage implementation"
else
    fail "run_op override" "tui.sh implementation not active; missing _TUI_ACTIVE or tui_substage_begin in declare -f run_op"
fi

# =============================================================================
echo "=== Test 18: stub in common.sh alone provides transparent passthrough ==="

# Source common.sh fresh (without tui.sh). The stub must work as a passthrough.
# Command substitution creates a subshell; no filesystem dependency.
stub_result=$(
    _TUI_ACTIVE=false
    # Stub functions common.sh expects from earlier in the chain
    _out_json_escape() { printf '%s' "$*"; }
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    rc=0
    output=$(run_op "ignored" echo "stub works") || rc=$?
    if [[ "$output" == "stub works" && "$rc" -eq 0 ]]; then
        echo "STUB_PASS"
    else
        echo "STUB_FAIL:rc=$rc:out=$output"
    fi
)

if [[ "$stub_result" == "STUB_PASS" ]]; then
    pass "common.sh stub: run_op is a transparent passthrough when common.sh sourced alone"
else
    fail "common.sh stub" "$stub_result"
fi

# =============================================================================
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
