#!/usr/bin/env bash
# =============================================================================
# test_tui_stage_wiring.sh — M107 — verify pipeline stage wiring to the TUI
# protocol API (tui_stage_begin / tui_stage_end).
#
# Covers the labels emitted by tekhton.sh, stages/coder.sh, stages/review.sh,
# and lib/finalize.sh after M107 wiring, plus a regression guard that raw
# internal stage names (e.g. "test_verify") do not silently produce pills
# that mismatch the labels get_display_stage_order advertises.
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
error()      { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/tui.sh"
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/pipeline_order.sh"

# M110: source output.sh for out_reset_pass and _OUT_CTX.
# Stubs required by output.sh (normally provided by common.sh).
_tui_strip_ansi() { printf '%s' "${1:-}"; }
_tui_notify()     { :; }
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/output.sh"

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
}

_stages_complete_labels_csv() {
    # Extracts the label field from each stages_complete JSON entry in order.
    python3 -c "
import json, sys
d = json.load(open('$_TUI_STATUS_FILE'))
labels = [s.get('label','') for s in d.get('stages_complete', [])]
print(','.join(labels))
" 2>/dev/null
}

# =============================================================================
echo "=== Test 1: intake stage produces an 'intake' entry in stages_complete ==="
_activate
tui_stage_begin "intake" "claude-sonnet-4-6"
tui_stage_end "intake" "claude-sonnet-4-6" "5/10" "12s" "PASS"

labels=$(_stages_complete_labels_csv)
if [[ "$labels" == "intake" ]]; then
    pass "intake stage emitted with label='intake'"
else
    fail "intake stage label" "expected 'intake', got '$labels'"
fi

# =============================================================================
echo "=== Test 2: raw internal 'test_verify' label is a regression guard ==="
# Simulate a buggy caller that passes the raw internal stage name instead of
# the display label. The pill bar MUST NOT end up with a 'tester' entry —
# callers are required to go through get_stage_display_label.
_activate
tui_stage_begin "test_verify" "claude-sonnet-4-6"
tui_stage_end "test_verify" "claude-sonnet-4-6" "10/30" "60s" ""

labels=$(_stages_complete_labels_csv)
if [[ "$labels" == "tester" ]]; then
    fail "raw internal name regression" \
         "tui_stage_begin 'test_verify' created a 'tester' pill (should not)"
elif [[ "$labels" == "test_verify" ]]; then
    pass "raw internal name 'test_verify' does not silently alias to 'tester'"
else
    fail "test_verify raw-name pill" "expected 'test_verify', got '$labels'"
fi

# =============================================================================
echo "=== Test 3: two rework cycles → zero pill entries, two stages_complete ==="
# M110: rework is a sub-stage (pill=no per §2 policy table). tui_stage_begin
# now consults get_stage_policy and only adds pill=yes stages to _TUI_STAGE_ORDER.
# Rework must NOT appear in the pill row even after two cycles; it is invisible
# as a pill but still emits completion records in stages_complete (timings).
_activate
tui_stage_begin "rework" "claude-opus-4-7"
tui_stage_end   "rework" "claude-opus-4-7" "20/70" "90s" ""
tui_stage_begin "rework" "claude-opus-4-7"
tui_stage_end   "rework" "claude-opus-4-7" "15/70" "60s" ""

rework_pill_count=0
for _s in "${_TUI_STAGE_ORDER[@]}"; do
    [[ "$_s" == "rework" ]] && rework_pill_count=$((rework_pill_count + 1))
done

if [[ "$rework_pill_count" -eq 0 ]]; then
    pass "_TUI_STAGE_ORDER has no 'rework' pill (sub-stage, pill=no per M110 §2)"
else
    fail "_TUI_STAGE_ORDER rework pill count" \
         "expected 0 (sub-stage, no pill), got $rework_pill_count (order=${_TUI_STAGE_ORDER[*]:-})"
fi

rework_complete_count=0
python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
c = sum(1 for s in d.get('stages_complete', []) if s.get('label') == 'rework')
print(c)
" > "$TMPDIR/rework_count.txt" 2>/dev/null
rework_complete_count=$(cat "$TMPDIR/rework_count.txt")

if [[ "$rework_complete_count" -eq 2 ]]; then
    pass "_TUI_STAGES_COMPLETE contains two 'rework' entries after two cycles"
else
    fail "stages_complete rework count" \
         "expected 2, got $rework_complete_count"
fi

# =============================================================================
echo "=== Test 4: wrap-up stage wiring (begin + end produces pill entry) ==="
_activate
tui_stage_begin "wrap-up" ""
tui_stage_end   "wrap-up" "" "" "" "SUCCESS"

labels=$(_stages_complete_labels_csv)
if [[ "$labels" == "wrap-up" ]]; then
    pass "wrap-up stage emitted with label='wrap-up'"
else
    fail "wrap-up stage label" "expected 'wrap-up', got '$labels'"
fi

# Verify wrap-up verdict was propagated
verdict=$(python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
stages = d.get('stages_complete', [])
print(stages[0].get('verdict') if stages else '')
" 2>/dev/null)
if [[ "$verdict" == "SUCCESS" ]]; then
    pass "wrap-up stage carries SUCCESS verdict"
else
    fail "wrap-up verdict" "expected 'SUCCESS', got '$verdict'"
fi

# =============================================================================
echo "=== Test 5: get_display_stage_order output ends with 'wrap-up' ==="
# Standard configuration
unset SKIP_SECURITY SKIP_DOCS
export INTAKE_AGENT_ENABLED=true
export SECURITY_AGENT_ENABLED=true
export DOCS_AGENT_ENABLED=false
order=$(get_display_stage_order)
last=$(echo "$order" | awk '{print $NF}')
if [[ "$last" == "wrap-up" ]]; then
    pass "standard order ends with 'wrap-up' (order='$order')"
else
    fail "standard order suffix" "expected 'wrap-up', got '$last' (order='$order')"
fi

# test_first order
export PIPELINE_ORDER=test_first
order=$(get_display_stage_order)
last=$(echo "$order" | awk '{print $NF}')
if [[ "$last" == "wrap-up" ]]; then
    pass "test_first order ends with 'wrap-up' (order='$order')"
else
    fail "test_first order suffix" "expected 'wrap-up', got '$last' (order='$order')"
fi

# With security disabled
export PIPELINE_ORDER=standard
export SECURITY_AGENT_ENABLED=false
order=$(get_display_stage_order)
last=$(echo "$order" | awk '{print $NF}')
if [[ "$last" == "wrap-up" ]]; then
    pass "order with security disabled still ends with 'wrap-up' (order='$order')"
else
    fail "order-no-security suffix" "expected 'wrap-up', got '$last'"
fi

# With docs enabled
export SECURITY_AGENT_ENABLED=true
export DOCS_AGENT_ENABLED=true
order=$(get_display_stage_order)
last=$(echo "$order" | awk '{print $NF}')
if [[ "$last" == "wrap-up" ]]; then
    pass "order with docs enabled still ends with 'wrap-up' (order='$order')"
else
    fail "order-with-docs suffix" "expected 'wrap-up', got '$last'"
fi

# =============================================================================
echo "=== Test 6: get_stage_display_label handles all wired stages ==="
_check_label() {
    local in="$1" expected="$2"
    local got
    got=$(get_stage_display_label "$in")
    if [[ "$got" == "$expected" ]]; then
        pass "get_stage_display_label('$in') → '$expected'"
    else
        fail "display label for '$in'" "expected '$expected', got '$got'"
    fi
}
_check_label "intake"      "intake"
_check_label "scout"       "scout"
_check_label "coder"       "coder"
_check_label "test_verify" "tester"
_check_label "test_write"  "tester-write"
_check_label "security"    "security"
_check_label "review"      "review"
_check_label "docs"        "docs"
_check_label "rework"      "rework"
_check_label "wrap_up"     "wrap-up"
_check_label "wrap-up"     "wrap-up"

# =============================================================================
# M110 Tests: lifecycle-id monotonicity, transition atomicity, multi-pass reset
# =============================================================================

# _activate_m110: clean baseline for M110 lifecycle tests.
# Uses _TUI_STATUS_FILE="" so _tui_write_status is a no-op (no file writes).
# This keeps the tests fast and avoids JSON-file race conditions between tests.
_activate_m110() {
    _TUI_ACTIVE=true
    _TUI_STATUS_FILE=""        # no-op writes
    _TUI_STATUS_TMP=""
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
    _TUI_STAGE_START_TS=0
    _TUI_AGENT_STATUS="idle"
    _TUI_COMPLETE=false
    _TUI_VERDICT=""
    _TUI_STAGE_CYCLE=()
    _TUI_CURRENT_LIFECYCLE_ID=""
    _TUI_CLOSED_LIFECYCLE_IDS=()
    TUI_LIFECYCLE_V2=true
}

# =============================================================================
echo "=== Test M110-1: lifecycle-id monotonicity via _tui_alloc_lifecycle_id ==="

_activate_m110

_tui_alloc_lifecycle_id "rework"
if [[ "${_TUI_CURRENT_LIFECYCLE_ID:-}" == "rework#1" ]]; then
    pass "M110-1a: first alloc → rework#1"
else
    fail "M110-1a: first alloc" "expected rework#1, got '${_TUI_CURRENT_LIFECYCLE_ID:-}'"
fi

if [[ "${_TUI_STAGE_CYCLE[rework]:-}" == "1" ]]; then
    pass "M110-1b: cycle counter after first alloc = 1"
else
    fail "M110-1b: cycle counter" "expected 1, got '${_TUI_STAGE_CYCLE[rework]:-}'"
fi

_tui_alloc_lifecycle_id "rework"
if [[ "${_TUI_CURRENT_LIFECYCLE_ID:-}" == "rework#2" ]]; then
    pass "M110-1c: second alloc → rework#2 (never reuses rework#1)"
else
    fail "M110-1c: second alloc" "expected rework#2, got '${_TUI_CURRENT_LIFECYCLE_ID:-}'"
fi

_tui_alloc_lifecycle_id "coder"
if [[ "${_TUI_CURRENT_LIFECYCLE_ID:-}" == "coder#1" ]]; then
    pass "M110-1d: independent label starts at #1"
else
    fail "M110-1d: independent label" "expected coder#1, got '${_TUI_CURRENT_LIFECYCLE_ID:-}'"
fi

# =============================================================================
echo "=== Test M110-2: tui_stage_begin/end allocates distinct lifecycle ids ==="

_activate_m110

tui_stage_begin "rework"
lid1="${_TUI_CURRENT_LIFECYCLE_ID:-}"
if [[ "$lid1" == "rework#1" ]]; then
    pass "M110-2a: first tui_stage_begin → rework#1"
else
    fail "M110-2a: first begin" "expected rework#1, got '${lid1}'"
fi

tui_stage_end "rework"
if [[ "${_TUI_CURRENT_LIFECYCLE_ID:-}" == "" ]]; then
    pass "M110-2b: tui_stage_end clears current lifecycle id"
else
    fail "M110-2b: lifecycle id after end" "expected empty, got '${_TUI_CURRENT_LIFECYCLE_ID:-}'"
fi
if [[ -n "${_TUI_CLOSED_LIFECYCLE_IDS["rework#1"]:-}" ]]; then
    pass "M110-2c: rework#1 added to closed set after stage_end"
else
    fail "M110-2c: closed set" "rework#1 missing from _TUI_CLOSED_LIFECYCLE_IDS"
fi

tui_stage_begin "rework"
lid2="${_TUI_CURRENT_LIFECYCLE_ID:-}"
if [[ "$lid2" == "rework#2" ]]; then
    pass "M110-2d: second tui_stage_begin → rework#2"
else
    fail "M110-2d: second begin" "expected rework#2, got '${lid2}'"
fi
if [[ "$lid1" != "$lid2" ]]; then
    pass "M110-2e: first and second lifecycle ids are distinct"
else
    fail "M110-2e: distinct ids" "both ids are '${lid1}' — lifecycle counter stuck"
fi

# =============================================================================
echo "=== Test M110-3: tui_update_agent drops updates to a closed lifecycle id ==="

_activate_m110

tui_stage_begin "coder"
coder_lid="${_TUI_CURRENT_LIFECYCLE_ID:-}"
tui_stage_end "coder"

# Baseline: turns_used is 0 after reset
_TUI_AGENT_TURNS_USED=0

# Update with the now-closed id — must be silently dropped
tui_update_agent 99 200 500 "$coder_lid"
if [[ "${_TUI_AGENT_TURNS_USED:-0}" -eq 0 ]]; then
    pass "M110-3a: update with closed lifecycle id is dropped (turns_used stays 0)"
else
    fail "M110-3a: update drop" "expected turns_used=0, got ${_TUI_AGENT_TURNS_USED:-0}"
fi

# =============================================================================
echo "=== Test M110-4: tui_update_agent proceeds when id matches current owner ==="

_activate_m110

tui_stage_begin "coder"
active_lid="${_TUI_CURRENT_LIFECYCLE_ID:-}"
_TUI_AGENT_TURNS_USED=0

tui_update_agent 7 20 30 "$active_lid"
if [[ "${_TUI_AGENT_TURNS_USED:-0}" -eq 7 ]]; then
    pass "M110-4a: update with current lifecycle id proceeds (turns_used=7)"
else
    fail "M110-4a: update with current id" "expected 7, got ${_TUI_AGENT_TURNS_USED:-0}"
fi

# =============================================================================
echo "=== Test M110-7: out_reset_pass clears per-pass keys ==="

out_init
out_set_context action_items '[{"msg":"unresolved item","severity":"medium"}]'
out_set_context current_stage "coder"
out_set_context current_model "claude-opus-4-7"

out_reset_pass

if [[ "${_OUT_CTX[action_items]:-}" == "" ]]; then
    pass "M110-7a: out_reset_pass: action_items cleared"
else
    fail "M110-7a: action_items clear" "expected empty, got '${_OUT_CTX[action_items]:-}'"
fi
if [[ "${_OUT_CTX[current_stage]:-}" == "" ]]; then
    pass "M110-7b: out_reset_pass: current_stage cleared"
else
    fail "M110-7b: current_stage clear" "expected empty, got '${_OUT_CTX[current_stage]:-}'"
fi
if [[ "${_OUT_CTX[current_model]:-}" == "" ]]; then
    pass "M110-7c: out_reset_pass: current_model cleared"
else
    fail "M110-7c: current_model clear" "expected empty, got '${_OUT_CTX[current_model]:-}'"
fi

# =============================================================================
echo "=== Test M110-8: out_reset_pass preserves run-identity keys ==="

out_init
out_set_context mode "task"
out_set_context task "add login feature"
out_set_context cli_flags "--fix nb"
out_set_context attempt "2"
out_set_context max_attempts "3"
# Per-pass keys (should be cleared)
out_set_context action_items '[{"msg":"item","severity":"low"}]'
out_set_context current_stage "review"

out_reset_pass

if [[ "${_OUT_CTX[mode]:-}" == "task" ]]; then
    pass "M110-8a: out_reset_pass: mode preserved"
else
    fail "M110-8a: mode preserved" "expected task, got '${_OUT_CTX[mode]:-}'"
fi
if [[ "${_OUT_CTX[task]:-}" == "add login feature" ]]; then
    pass "M110-8b: out_reset_pass: task preserved"
else
    fail "M110-8b: task preserved" "expected 'add login feature', got '${_OUT_CTX[task]:-}'"
fi
if [[ "${_OUT_CTX[cli_flags]:-}" == "--fix nb" ]]; then
    pass "M110-8c: out_reset_pass: cli_flags preserved"
else
    fail "M110-8c: cli_flags preserved" "expected '--fix nb', got '${_OUT_CTX[cli_flags]:-}'"
fi
if [[ "${_OUT_CTX[attempt]:-}" == "2" ]]; then
    pass "M110-8d: out_reset_pass: attempt counter preserved"
else
    fail "M110-8d: attempt preserved" "expected 2, got '${_OUT_CTX[attempt]:-}'"
fi

# =============================================================================
echo "=== Test M110-9: tui_append_event stores runtime type in ring buffer ==="

_activate_m110

tui_append_event "info" "coder started" "runtime"
if [[ "${#_TUI_RECENT_EVENTS[@]}" -gt 0 ]]; then
    _last_event="${_TUI_RECENT_EVENTS[$(( ${#_TUI_RECENT_EVENTS[@]} - 1 ))]}"
    # M117 5-field shape: "ts|level|type|source|msg"; source empty here.
    if [[ "$_last_event" == *"|runtime||coder started" ]]; then
        pass "M110-9a: runtime event stored with correct type field"
    else
        fail "M110-9a: runtime event format" "entry: '${_last_event}'"
    fi
else
    fail "M110-9a: runtime event stored" "_TUI_RECENT_EVENTS empty after append"
fi

# =============================================================================
echo "=== Test M110-10: tui_append_event stores summary type in ring buffer ==="

_activate_m110

tui_append_event "info" "Task: add login feature" "summary"
if [[ "${#_TUI_RECENT_EVENTS[@]}" -gt 0 ]]; then
    _last_event="${_TUI_RECENT_EVENTS[$(( ${#_TUI_RECENT_EVENTS[@]} - 1 ))]}"
    # M117 5-field shape: "ts|level|type|source|msg"; source empty here.
    if [[ "$_last_event" == *"|summary||Task: add login feature" ]]; then
        pass "M110-10a: summary event stored with correct type field"
    else
        fail "M110-10a: summary event format" "entry: '${_last_event}'"
    fi
else
    fail "M110-10a: summary event stored" "_TUI_RECENT_EVENTS empty after append"
fi

# =============================================================================
echo "=== Test M110-11: tui_append_event with invalid type defaults to runtime ==="

_activate_m110

tui_append_event "warn" "some warning" "badtype"
if [[ "${#_TUI_RECENT_EVENTS[@]}" -gt 0 ]]; then
    _last_event="${_TUI_RECENT_EVENTS[$(( ${#_TUI_RECENT_EVENTS[@]} - 1 ))]}"
    if [[ "$_last_event" == *"|runtime|"* ]]; then
        pass "M110-11a: invalid event type defaults to runtime"
    else
        fail "M110-11a: invalid type default" "expected '|runtime|' in: '${_last_event}'"
    fi
else
    fail "M110-11a: invalid type event stored" "_TUI_RECENT_EVENTS empty after append"
fi

# =============================================================================
echo "=== Test M110-12: two rework cycles get distinct lifecycle ids ==="

_activate_m110

tui_stage_begin "review"

# First rework cycle
tui_stage_begin "rework"
rework_lid_1="${_TUI_CURRENT_LIFECYCLE_ID:-}"
tui_stage_end "rework"

# Second rework cycle
tui_stage_begin "rework"
rework_lid_2="${_TUI_CURRENT_LIFECYCLE_ID:-}"
tui_stage_end "rework"

if [[ "$rework_lid_1" != "$rework_lid_2" ]]; then
    pass "M110-12a: two rework cycles have distinct lifecycle ids"
else
    fail "M110-12a: distinct rework ids" "both ids are '${rework_lid_1}'"
fi
if [[ "$rework_lid_1" == "rework#1" && "$rework_lid_2" == "rework#2" ]]; then
    pass "M110-12b: rework cycles are rework#1 and rework#2 in order"
else
    fail "M110-12b: rework sequence" "expected rework#1/rework#2, got '${rework_lid_1}'/'${rework_lid_2}'"
fi
if [[ -n "${_TUI_CLOSED_LIFECYCLE_IDS["rework#1"]:-}" && \
      -n "${_TUI_CLOSED_LIFECYCLE_IDS["rework#2"]:-}" ]]; then
    pass "M110-12c: both rework cycles are in the closed lifecycle id set"
else
    fail "M110-12c: closed rework ids" "one or both rework ids missing from closed set"
fi
if [[ "${_TUI_STAGE_CYCLE[review]:-0}" -eq 1 ]]; then
    pass "M110-12d: review cycle counter = 1 (not mutated by sub-stage rework cycles)"
else
    fail "M110-12d: review counter" "expected 1, got ${_TUI_STAGE_CYCLE[review]:-0}"
fi

# =============================================================================
# M110-13: intake does not appear at end of pill row when plan excludes it.
#
# Regression guard for the --fix-nonblockers / --fix-drift bug where
# INTAKE_AGENT_ENABLED=false causes get_run_stage_plan to omit "intake" from
# the pill plan, but an unguarded tui_stage_begin "intake" call still appended
# it to the end of _TUI_STAGE_ORDER.  The fix in tekhton.sh guards the call;
# this test confirms that tui_stage_begin "intake" DOES append to the end when
# called against a plan that excludes "intake" (documenting the contract that
# callers must guard the call themselves).
# =============================================================================
echo "=== Test M110-13: intake appended to end when absent from seeded plan ==="

_activate_m110
# Simulate get_run_stage_plan output for INTAKE_AGENT_ENABLED=false:
# plan is "preflight coder security review tester wrap-up" (no intake).
tui_set_context "task" "" "preflight" "coder" "security" "review" "tester" "wrap-up"

# Simulate the old unguarded behaviour: call tui_stage_begin "intake" even
# though "intake" is absent from the seeded plan.
tui_stage_begin "intake"

# Verify that "intake" IS appended to the end (demonstrating the old bug)
# and that it therefore does NOT appear at position 2 (immediately after preflight).
_last="${_TUI_STAGE_ORDER[$(( ${#_TUI_STAGE_ORDER[@]} - 1 ))]:-}"
if [[ "$_last" == "intake" ]]; then
    pass "M110-13a: unguarded tui_stage_begin appends intake to end of pill row (old bug documented)"
else
    fail "M110-13a: expected intake at end of plan" "got last='${_last}' order=(${_TUI_STAGE_ORDER[*]:-})"
fi
# Also verify preflight is still at position 0 (not displaced).
if [[ "${_TUI_STAGE_ORDER[0]:-}" == "preflight" ]]; then
    pass "M110-13b: preflight remains at position 0 after unguarded intake begin"
else
    fail "M110-13b: preflight position after intake" "expected preflight at [0], order=(${_TUI_STAGE_ORDER[*]:-})"
fi

# Now verify the correct guarded behaviour: seed the plan correctly and do NOT
# call tui_stage_begin "intake" — pill order should have no intake.
_activate_m110
tui_set_context "task" "" "preflight" "coder" "security" "review" "tester" "wrap-up"
# (No tui_stage_begin "intake" — guard kept the call out.)
_found_intake=false
_s=""
for _s in "${_TUI_STAGE_ORDER[@]:-}"; do
    [[ "$_s" == "intake" ]] && { _found_intake=true; break; }
done
if [[ "$_found_intake" == "false" ]]; then
    pass "M110-13c: guarded path — intake absent from pill row when INTAKE_AGENT_ENABLED=false"
else
    fail "M110-13c: intake absent" "intake unexpectedly in pill row: (${_TUI_STAGE_ORDER[*]:-})"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
