#!/usr/bin/env bash
# =============================================================================
# test_tui_attempt_counter.sh — M99 — verify TUI JSON attempt field is driven
# by _OUT_CTX[attempt] rather than the old PIPELINE_ATTEMPT ghost variable.
#
# Primary fix of M99: the TUI header previously showed "Pass 1/N" for every
# retry because PIPELINE_ATTEMPT was never set anywhere. After M99, the attempt
# counter is stored in _OUT_CTX[attempt] via out_set_context and read by
# _tui_json_build_status via `_OUT_CTX[attempt]`.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

# Also source output.sh so _OUT_CTX + out_set_context are available.
# _tui_strip_ansi and _tui_notify are already defined in tui.sh's stubs above.
_tui_strip_ansi() { printf '%s' "$*"; }
_tui_notify()     { :; }
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""
# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"

# --- Shared setup helpers -----------------------------------------------------

_activate_tui_globals() {
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
    _CURRENT_MILESTONE="99"
    _CURRENT_RUN_ID="run-test"
    MAX_PIPELINE_ATTEMPTS=5
}

_read_json_int() {
    local file="$1" key="$2"
    python3 -c "import json; d=json.load(open('$file')); print(int(d.get('$key', 0)))" 2>/dev/null
}

_write_status() {
    local elapsed=0
    _tui_json_build_status "$elapsed" > "$_TUI_STATUS_FILE"
}

# =============================================================================
echo "=== Test 1: attempt=1 in _OUT_CTX → JSON attempt=1 ==="

_activate_tui_globals
out_init
out_set_context attempt "1"
_write_status

attempt_val=$(_read_json_int "$_TUI_STATUS_FILE" "attempt")
if [[ "$attempt_val" -eq 1 ]]; then
    pass "JSON attempt=1 when _OUT_CTX[attempt]=1"
else
    fail "JSON attempt field" "expected 1, got $attempt_val"
fi

# =============================================================================
echo "=== Test 2: attempt=2 in _OUT_CTX → JSON attempt=2 (primary M99 fix) ==="

_activate_tui_globals
out_init
out_set_context attempt "2"
_write_status

attempt_val=$(_read_json_int "$_TUI_STATUS_FILE" "attempt")
if [[ "$attempt_val" -eq 2 ]]; then
    pass "JSON attempt=2 when _OUT_CTX[attempt]=2 (second loop iteration)"
else
    fail "JSON attempt field on second iteration" "expected 2, got $attempt_val"
fi

# =============================================================================
echo "=== Test 3: attempt=3 in _OUT_CTX → JSON attempt=3 ==="

_activate_tui_globals
out_init
out_set_context attempt "3"
_write_status

attempt_val=$(_read_json_int "$_TUI_STATUS_FILE" "attempt")
if [[ "$attempt_val" -eq 3 ]]; then
    pass "JSON attempt=3 when _OUT_CTX[attempt]=3"
else
    fail "JSON attempt field" "expected 3, got $attempt_val"
fi

# =============================================================================
echo "=== Test 4: simulated orchestrate loop — attempt increments correctly ==="

_activate_tui_globals
out_init

# Simulate what _orch_complete_run does: increment and call out_set_context
_ORCH_ATTEMPT=0
for expected in 1 2 3; do
    _ORCH_ATTEMPT=$(( _ORCH_ATTEMPT + 1 ))
    out_set_context attempt "$_ORCH_ATTEMPT"
    out_set_context max_attempts "5"
    _write_status

    attempt_val=$(_read_json_int "$_TUI_STATUS_FILE" "attempt")
    if [[ "$attempt_val" -eq "$expected" ]]; then
        pass "loop iteration $expected: JSON attempt=$expected"
    else
        fail "loop iteration $expected attempt" "expected $expected, got $attempt_val"
    fi
done

# =============================================================================
echo "=== Test 5: PIPELINE_ATTEMPT is not referenced in lib/ or tekhton.sh ==="

# The ghost variable PIPELINE_ATTEMPT (standalone, not MAX_PIPELINE_ATTEMPTS)
# must be absent from all shell files. M99 replaced it with _OUT_CTX[attempt].
# We exclude MAX_PIPELINE_ATTEMPTS (a legitimate config variable) from results.
ghost_matches=$(grep -r "PIPELINE_ATTEMPT" \
    "${TEKHTON_HOME}/lib/" \
    "${TEKHTON_HOME}/tekhton.sh" \
    "${TEKHTON_HOME}/stages/" 2>/dev/null \
    | grep -v "MAX_PIPELINE_ATTEMPTS" \
    | grep -v "^Binary" \
    | grep -v "#.*PIPELINE_ATTEMPT" \
    || true)

if [[ -z "$ghost_matches" ]]; then
    pass "PIPELINE_ATTEMPT ghost variable is not referenced in lib/, stages/, or tekhton.sh"
else
    fail "PIPELINE_ATTEMPT still referenced" "$ghost_matches"
fi

# =============================================================================
echo "=== Test 6: without _OUT_CTX defined, attempt falls back to 1 ==="

# Simulate a context where output.sh wasn't sourced (standalone tui test).
# _tui_json_build_status guards with 'declare -p _OUT_CTX &>/dev/null'.
_activate_tui_globals
# Temporarily unset _OUT_CTX to test the fallback path
if declare -p _OUT_CTX &>/dev/null; then
    unset _OUT_CTX
fi
_write_status

attempt_val=$(_read_json_int "$_TUI_STATUS_FILE" "attempt")
if [[ "$attempt_val" -eq 1 ]]; then
    pass "attempt falls back to 1 when _OUT_CTX is not defined"
else
    fail "attempt fallback" "expected 1, got $attempt_val"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
