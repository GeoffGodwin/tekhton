#!/usr/bin/env bash
# =============================================================================
# test_output_tui_sync.sh — M103 — TUI JSON correctness across the six run
# modes supported by tekhton.sh (task, milestone, complete, fix-nb, fix-drift,
# human). Also covers the Output Bus fields that now feed the JSON status:
# stage_order, action_items, attempt.
#
# _tui_json_build_status is the single source of truth for the sidecar
# payload. These tests exercise it directly instead of spawning the pipeline.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# ── Stub log/warn/etc. that tui.sh expects from common.sh ─────────────────────
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# shellcheck source=../lib/tui.sh
source "${TEKHTON_HOME}/lib/tui.sh"

# Dependencies for output.sh
_tui_strip_ansi() { printf '%s' "$*"; }
_tui_notify()     { :; }
# shellcheck disable=SC2034
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""

# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"
# shellcheck source=../lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

# ── Test helpers ──────────────────────────────────────────────────────────────
_reset_tui_globals() {
    _TUI_ACTIVE=true
    _TUI_STATUS_FILE="$TMPDIR_TEST/status.json"
    _TUI_STATUS_TMP="$TMPDIR_TEST/status.json.tmp"
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
    _TUI_COMPLETE=false
    _TUI_VERDICT=""
    _TUI_RUN_MODE="task"
    _TUI_CLI_FLAGS=""
    # shellcheck disable=SC2034  # consumed by _tui_json_build_status via sourced tui_helpers.sh
    TASK="sync-test"
    # shellcheck disable=SC2034
    _CURRENT_MILESTONE="103"
    # shellcheck disable=SC2034
    _CURRENT_RUN_ID="run-test"
    # shellcheck disable=SC2034  # fallback path used when _OUT_CTX[max_attempts] unset
    MAX_PIPELINE_ATTEMPTS=5
}

# assert_json_field EXPECTED FIELD JSON LABEL
# Extracts a JSON field value using python3 (robust against the shape of
# _tui_json_build_status's printf output).
assert_json_field() {
    local expected="$1" field="$2" json="$3" label="$4"
    local actual
    actual=$(python3 -c "
import json, sys
d=json.loads(sys.stdin.read())
v=d.get('${field}')
print('' if v is None else v)
" <<< "$json" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        pass "$label (${field}=${expected})"
    else
        fail "$label" "${field}: expected='${expected}' actual='${actual}'"
    fi
}

# =============================================================================
echo "=== TC-TUI-01: default run_mode is 'task' ==="
_reset_tui_globals
out_init
out_set_context mode "task"
out_set_context attempt 1
# _TUI_RUN_MODE already defaults to "task" from _reset_tui_globals.
json=$(_tui_json_build_status 0)
assert_json_field "task" "run_mode" "$json" "default run_mode"

# =============================================================================
echo "=== TC-TUI-02: run_mode=fix-nb with attempt/max_attempts counters ==="
_reset_tui_globals
out_init
out_set_context mode "fix-nb"
out_set_context attempt 2
out_set_context max_attempts 3
# tui.sh reads run_mode from _TUI_RUN_MODE; tekhton.sh sets both together
# via `out_set_context mode` + `tui_set_context`. Mirror that here.
_TUI_RUN_MODE="fix-nb"
json=$(_tui_json_build_status 0)
assert_json_field "fix-nb" "run_mode"     "$json" "fix-nb run_mode"
assert_json_field "2"      "attempt"      "$json" "attempt counter synced"
assert_json_field "3"      "max_attempts" "$json" "max_attempts synced"

# =============================================================================
echo "=== TC-TUI-03: stage_order falls back to _OUT_CTX when _TUI_STAGE_ORDER empty ==="
_reset_tui_globals
out_init
out_set_context stage_order "intake scout coder security review tester"
# _TUI_STAGE_ORDER is empty from _reset_tui_globals — fallback should fire.
json=$(_tui_json_build_status 0)
# stage_order is a JSON array; assert first + last elements are present.
if [[ "$json" == *'"intake"'* ]] && [[ "$json" == *'"tester"'* ]]; then
    pass "stage_order fallback includes intake and tester"
else
    fail "stage_order fallback" "stage_order array missing expected entries in JSON"
fi

# =============================================================================
echo "=== TC-TUI-04: action_items populated from _OUT_CTX (M102) ==="
_reset_tui_globals
out_init
out_action_item "fix tests" "critical"
out_action_item "review drift" "warning"
json=$(_tui_json_build_status 0)
if [[ "$json" == *'"fix tests"'* ]] && [[ "$json" == *'"critical"'* ]]; then
    pass "critical action item appears in JSON"
else
    fail "critical action_items field" "'fix tests'/'critical' not found in JSON"
fi
if [[ "$json" == *'"review drift"'* ]] && [[ "$json" == *'"warning"'* ]]; then
    pass "warning action item appears in JSON"
else
    fail "warning action_items field" "'review drift'/'warning' not found in JSON"
fi

# =============================================================================
echo "=== TC-TUI-05: attempt reads from _OUT_CTX, not PIPELINE_ATTEMPT ==="
_reset_tui_globals
out_init
unset PIPELINE_ATTEMPT 2>/dev/null || true
out_set_context attempt 4
json=$(_tui_json_build_status 0)
assert_json_field "4" "attempt" "$json" "_OUT_CTX[attempt] drives JSON attempt"

# =============================================================================
echo "=== TC-TUI-06: all six run modes produce their labelled run_mode ==="
# Bonus coverage — every mode listed in the §3 table must round-trip cleanly.
for mode in task milestone complete fix-nb fix-drift human; do
    _reset_tui_globals
    out_init
    out_set_context mode "$mode"
    _TUI_RUN_MODE="$mode"
    json=$(_tui_json_build_status 0)
    assert_json_field "$mode" "run_mode" "$json" "run_mode=$mode"
done

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
