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

# =============================================================================
# Per-milestone state isolation — tui_reset_for_next_milestone is called by
# _run_auto_advance_chain before re-entering run_complete_loop so milestone 2+
# start with grey pills instead of inheriting the prior milestone's green row.
# =============================================================================
echo "=== Test 7: reset clears per-milestone completion + progress state ==="
_activate_tui
_TUI_STAGE_ORDER=("intake" "coder" "review" "tester" "wrap-up")
for label in intake coder review tester wrap-up; do
    tui_stage_begin "$label"
    tui_stage_end "$label" "" "" "" "PASS"
done
pre_complete=${#_TUI_STAGES_COMPLETE[@]}
tui_reset_for_next_milestone

if [[ "$pre_complete" -ge 5 ]] && [[ "${#_TUI_STAGES_COMPLETE[@]}" -eq 0 ]] \
   && [[ "${#_TUI_RECENT_EVENTS[@]}" -eq 0 ]] && [[ "$_TUI_ACTIVE" == "true" ]] \
   && [[ "${#_TUI_STAGE_ORDER[@]}" -eq 5 ]] && [[ -z "$_TUI_CURRENT_STAGE_LABEL" ]] \
   && [[ "$_TUI_CURRENT_STAGE_NUM" -eq 0 ]] && [[ "$_TUI_AGENT_STATUS" == "idle" ]] \
   && [[ "$_TUI_AGENT_TURNS_USED" -eq 0 ]]; then
    pass "reset clears stages_complete+events+progress, keeps sidecar+pill list"
else
    fail "reset invariants" \
         "stages=${#_TUI_STAGES_COMPLETE[@]} events=${#_TUI_RECENT_EVENTS[@]} active=$_TUI_ACTIVE order=${#_TUI_STAGE_ORDER[@]} label='$_TUI_CURRENT_STAGE_LABEL' num=$_TUI_CURRENT_STAGE_NUM status='$_TUI_AGENT_STATUS'"
fi

# =============================================================================
echo "=== Test 8: reset preserves monotonic lifecycle-id counter ==="
_activate_tui
# Clear the cross-test global so cycle numbers start from a known baseline.
_TUI_STAGE_CYCLE=()
_TUI_CLOSED_LIFECYCLE_IDS=()
_TUI_STAGE_ORDER=("coder")
tui_stage_begin "coder"; tui_stage_end "coder" "" "" "" "PASS"
cycle_before="${_TUI_STAGE_CYCLE[coder]:-0}"

tui_reset_for_next_milestone
cycle_after_reset="${_TUI_STAGE_CYCLE[coder]:-0}"

tui_stage_begin "coder"
next_id="${_TUI_CURRENT_LIFECYCLE_ID:-}"

if [[ "$cycle_before" -eq 1 ]] && [[ "$cycle_after_reset" -eq 1 ]] \
   && [[ "$next_id" == "coder#2" ]]; then
    pass "reset retains counter at 1; next begin allocates coder#2"
else
    fail "cycle advance" \
         "before=$cycle_before after_reset=$cycle_after_reset next='$next_id' (expected 1,1,coder#2)"
fi

# =============================================================================
echo "=== Test 9: reset is a no-op when _TUI_ACTIVE=false ==="
_activate_tui
_TUI_STAGES_COMPLETE=('{"label":"coder"}')
_TUI_RECENT_EVENTS=("12:00:00|info|runtime||hello")
_TUI_ACTIVE=false
tui_reset_for_next_milestone

if [[ "${#_TUI_STAGES_COMPLETE[@]}" -eq 1 ]] && [[ "${#_TUI_RECENT_EVENTS[@]}" -eq 1 ]]; then
    pass "inactive reset does not clear state"
else
    fail "inactive noop" "stages=${#_TUI_STAGES_COMPLETE[@]} events=${#_TUI_RECENT_EVENTS[@]} (expected 1 + 1)"
fi

# =============================================================================
echo "=== Test 10: auto-advance simulation — pills reset across milestones ==="
_activate_tui
_TUI_STAGE_ORDER=("intake" "coder" "review" "tester" "wrap-up")

# Milestone 1: run all stages to completion (mirrors a real pipeline pass)
for label in intake coder review tester; do
    tui_stage_begin "$label"
    tui_stage_end "$label" "" "" "" "PASS"
done
tui_stage_begin "wrap-up"
_hook_tui_complete 0
m1_count=${#_TUI_STAGES_COMPLETE[@]}

# Transition: _run_auto_advance_chain calls this before re-entering
# run_complete_loop for milestone 2.
tui_reset_for_next_milestone

# Milestone 2: intake starts — pills must be grey, not inherit M1's green row.
tui_stage_begin "intake"

if [[ "$m1_count" -ge 5 ]] && [[ "${#_TUI_STAGES_COMPLETE[@]}" -eq 0 ]] \
   && [[ "$_TUI_CURRENT_STAGE_LABEL" == "intake" ]]; then
    pass "M1 recorded ${m1_count} stages; M2 starts fresh with active stage=intake"
else
    fail "auto-advance isolation" \
         "m1=$m1_count m2_stages=${#_TUI_STAGES_COMPLETE[@]} m2_label='$_TUI_CURRENT_STAGE_LABEL'"
fi

# =============================================================================
echo "=== Test 11: reset silently clears substage even if still open at transition ==="
_activate_tui
_TUI_STAGE_ORDER=("coder")
tui_stage_begin "coder"
# Simulate a substage still open at milestone transition (production impossible
# but guards against regression if call site moves). Contract: silent clear,
# not emitted as auto-close warn event.
tui_substage_begin "scout"
_TUI_RECENT_EVENTS=()  # Clear events so we can verify reset doesn't emit warn

tui_reset_for_next_milestone

if [[ -z "$_TUI_CURRENT_SUBSTAGE_LABEL" ]] && [[ "$_TUI_CURRENT_SUBSTAGE_START_TS" -eq 0 ]] \
   && [[ "${#_TUI_RECENT_EVENTS[@]}" -eq 0 ]]; then
    pass "reset silently zeroes substage without emitting auto-close warn"
else
    fail "silent substage clear" \
         "label='$_TUI_CURRENT_SUBSTAGE_LABEL' ts=$_TUI_CURRENT_SUBSTAGE_START_TS events=${#_TUI_RECENT_EVENTS[@]} (expected empty)"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
