#!/usr/bin/env bash
# =============================================================================
# test_tui_multipass_lifecycle.sh — M111 — sidecar lifecycle must span the
# outer tekhton.sh invocation, not individual pipeline passes.
#
# Regression for: in --complete / --fix-nb / --fix-drift modes, the per-pass
# finalize_run() chain used to flip _TUI_ACTIVE=false (via out_complete →
# tui_complete → tui_stop) before the outer loop re-entered the next pass.
# That caused agent_spinner.sh to fall through to its /dev/tty spinner path,
# drawing "[tekhton] ⠦ ..." lines over the TUI layout between passes.
#
# Fix contract (M111):
#   - _hook_tui_complete closes the wrap-up pill and emits a summary event
#     but does NOT call out_complete.
#   - _TUI_ACTIVE remains true across per-pass finalize_run() calls.
#   - Only the top-level dispatch site in tekhton.sh calls out_complete.
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

# Activate TUI without spawning a real Python sidecar.
_activate_tui() {
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
    _TUI_COMPLETE=false
    _TUI_VERDICT=""
}

# Load _hook_tui_complete from the real source file (same awk extraction used
# by test_out_complete.sh) so the regression is tied to production code.
_load_hook_tui_complete() {
    local fn
    fn=$(awk '
        /^_hook_tui_complete\(\)/ { p=1 }
        p { print }
        p && /^\}[[:space:]]*$/ { exit }
    ' "${TEKHTON_HOME}/lib/finalize_dashboard_hooks.sh")
    [[ -z "$fn" ]] && { fail "extract" "empty awk result"; exit 1; }
    eval "$fn"
}
_load_hook_tui_complete

# =============================================================================
echo "=== Test 1: _hook_tui_complete 0 keeps _TUI_ACTIVE=true ==="
_activate_tui
_TUI_STAGE_ORDER=("wrap-up")
tui_stage_begin "wrap-up"

_hook_tui_complete 0

if [[ "$_TUI_ACTIVE" == "true" ]]; then
    pass "sidecar stays active after successful pass"
else
    fail "sidecar state after pass success" "_TUI_ACTIVE=$_TUI_ACTIVE (expected true)"
fi

if [[ "$_TUI_COMPLETE" == "false" ]]; then
    pass "_TUI_COMPLETE not flipped by per-pass hook"
else
    fail "_TUI_COMPLETE" "expected false, got $_TUI_COMPLETE"
fi

# =============================================================================
echo "=== Test 2: _hook_tui_complete 1 keeps _TUI_ACTIVE=true ==="
_activate_tui
_TUI_STAGE_ORDER=("wrap-up")
tui_stage_begin "wrap-up"

_hook_tui_complete 1

if [[ "$_TUI_ACTIVE" == "true" ]]; then
    pass "sidecar stays active after failing pass"
else
    fail "sidecar state after pass fail" "_TUI_ACTIVE=$_TUI_ACTIVE (expected true)"
fi

# =============================================================================
echo "=== Test 3: multi-pass simulation — three finalize_run calls in a row ==="
_activate_tui
_TUI_STAGE_ORDER=("wrap-up")

for i in 1 2 3; do
    tui_stage_begin "wrap-up"
    _hook_tui_complete 0

    if [[ "$_TUI_ACTIVE" != "true" ]]; then
        fail "multi-pass pass $i" "_TUI_ACTIVE flipped to false mid-loop"
        break
    fi
done

if [[ "$_TUI_ACTIVE" == "true" ]]; then
    pass "sidecar remains active across 3 simulated finalize_run passes"
fi

# =============================================================================
echo "=== Test 4: each pass appends a summary event 'Pass complete: SUCCESS' ==="
_activate_tui
_TUI_STAGE_ORDER=("wrap-up")

for _ in 1 2 3; do
    tui_stage_begin "wrap-up"
    _hook_tui_complete 0
done

# Count summary events — M117 5-field shape is "ts|level|summary|source|msg";
# source is empty for events emitted outside any open stage/substage.
summary_count=0
for ev in "${_TUI_RECENT_EVENTS[@]}"; do
    if [[ "$ev" == *"|summary|"*"|Pass complete: SUCCESS" ]]; then
        summary_count=$((summary_count + 1))
    fi
done

if [[ "$summary_count" -eq 3 ]]; then
    pass "three passes emitted three 'Pass complete: SUCCESS' summary events"
else
    fail "summary event count" "expected 3, got $summary_count"
fi

# =============================================================================
echo "=== Test 5: mixed-verdict passes emit correct levels ==="
_activate_tui
_TUI_STAGE_ORDER=("wrap-up")

tui_stage_begin "wrap-up"; _hook_tui_complete 0  # SUCCESS
tui_stage_begin "wrap-up"; _hook_tui_complete 1  # FAIL
tui_stage_begin "wrap-up"; _hook_tui_complete 0  # SUCCESS

success_count=0; fail_count=0
# M117 5-field shape: "ts|level|type|source|msg" — source empty for
# events emitted outside any open stage/substage.
for ev in "${_TUI_RECENT_EVENTS[@]}"; do
    [[ "$ev" == *"|success|summary|"*"|Pass complete: SUCCESS" ]] && success_count=$((success_count + 1))
    [[ "$ev" == *"|error|summary|"*"|Pass complete: FAIL"    ]] && fail_count=$((fail_count + 1))
done

if [[ "$success_count" -eq 2 ]] && [[ "$fail_count" -eq 1 ]]; then
    pass "mixed-verdict passes emit 2 success + 1 error summary events"
else
    fail "mixed summary level counts" "success=$success_count fail=$fail_count (expected 2 + 1)"
fi

# =============================================================================
echo "=== Test 6: _hook_tui_complete is a no-op when _TUI_ACTIVE=false ==="
_activate_tui
_TUI_ACTIVE=false
_TUI_RECENT_EVENTS=()

_hook_tui_complete 0

if [[ "$_TUI_ACTIVE" == "false" ]] && [[ "${#_TUI_RECENT_EVENTS[@]}" -eq 0 ]]; then
    pass "hook does not resurrect an inactive sidecar or emit events"
else
    fail "inactive hook" "_TUI_ACTIVE=$_TUI_ACTIVE events=${#_TUI_RECENT_EVENTS[@]}"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
