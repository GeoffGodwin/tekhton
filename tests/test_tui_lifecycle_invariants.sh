#!/usr/bin/env bash
# =============================================================================
# test_tui_lifecycle_invariants.sh — M119 — TUI lifecycle invariants.
#
# Quality-gate suite that codifies the lifecycle guarantees established by
# M113 (substage API), M115 (run_op migration), M116 (rework + architect-
# remediation migration; tui_stage_transition retirement), M117 (Recent
# Events substage attribution), and M118 (preflight/intake deferred emit).
#
# Each invariant is a small, self-contained test. The suite is executed
# under tests/run_tests.sh; it never spawns the real Python sidecar.
#
# Invariants exercised here (one authoritative test each):
#   1. Pill ↔ stages_complete coherence
#   2. Pill row owner (active pill is the pipeline stage label)
#   3. Live-row timer continuity across substage begin/end
#   4. Substage non-retention (no stages_complete row from substage end)
#   5. Auto-close warn (parent end with substage open)
#   6. Opt-out no-op (TUI_LIFECYCLE_V2=false)
#   7. No parallel mechanism (grep-based; production code only)
#   8. Attribution source correctness (stage / substage / unattributed)
#   9. Preflight + intake ordering (pill flips before success line)
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
source "${TEKHTON_HOME}/lib/pipeline_order.sh"
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

_event_field() {
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
ev = (d.get('recent_events') or [])
print('<MISSING>' if not ev else (ev[-1].get('$1') if ev[-1].get('$1') is not None else '<MISSING>'))
" 2>/dev/null
}

_last_event_json() {
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
ev = (d.get('recent_events') or [])
print('<EMPTY>' if not ev else json.dumps(ev[-1], sort_keys=True))
" 2>/dev/null
}

_stage_complete_label() {
    # Echo the JSON .label of the Nth (1-based) stages_complete entry.
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
arr = d.get('stages_complete') or []
i = $1 - 1
print('<MISSING>' if i >= len(arr) else arr[i].get('label', ''))
" 2>/dev/null
}

# =============================================================================
echo "=== Invariant 1: Pill ↔ stages_complete coherence ==="
# Every label appended to _TUI_STAGES_COMPLETE must correspond to a stage
# whose policy class is one of pipeline | pre | post — never sub or op.
# Substages (scout/rework/architect-remediation) and run_op labels must
# never produce a completion record.
_activate

# Pipeline stages (eligible for stages_complete)
tui_stage_begin "coder"
tui_stage_begin "scout"   # substage-class via policy; tui_stage_begin still allocates id but pill=no
# Use the substage API for the substage end so it doesn't write a record.
_TUI_CURRENT_SUBSTAGE_LABEL="scout"
_TUI_CURRENT_SUBSTAGE_START_TS=$(date +%s)
tui_substage_end "scout" "PASS"
tui_stage_end "coder" "" "" "" "PASS"

tui_stage_begin "review"
tui_substage_begin "rework"
tui_substage_end "rework" "PASS"
tui_stage_end "review" "" "" "" "PASS"

# A run_op also must not append a record.
tui_stage_begin "tester"
run_op "Running tests" true
tui_stage_end "tester" "" "" "" "PASS"

_violations=0
_n=${#_TUI_STAGES_COMPLETE[@]}
for ((i=1; i<=_n; i++)); do
    label=$(_stage_complete_label "$i")
    [[ -z "$label" || "$label" == "<MISSING>" ]] && continue
    pol=$(get_stage_policy "$label")
    cls="${pol%%|*}"
    case "$cls" in
        pipeline|pre|post) ;;
        *)
            _violations=$((_violations + 1))
            echo "    violator: label='$label' class='$cls'"
            ;;
    esac
done
if (( _violations == 0 )); then
    pass "1: every stages_complete label has class ∈ {pipeline,pre,post}"
else
    fail "1" "$_violations stages_complete entries with non-pipeline class"
fi

# =============================================================================
echo "=== Invariant 2: Pill row owner ==="
# The active pill label (stage_label in JSON) must equal _TUI_CURRENT_STAGE_LABEL,
# never _TUI_CURRENT_SUBSTAGE_LABEL — even while a substage is active.
_activate
tui_stage_begin "coder" "claude-opus-4-7"
tui_substage_begin "scout" "claude-haiku-4-5"

stage_label_in_json=$(python3 -c "import json; print(json.load(open('$_TUI_STATUS_FILE')).get('stage_label',''))")
if [[ "$stage_label_in_json" == "$_TUI_CURRENT_STAGE_LABEL" \
   && "$stage_label_in_json" == "coder" \
   && "$stage_label_in_json" != "$_TUI_CURRENT_SUBSTAGE_LABEL" ]]; then
    pass "2: stage_label='coder' (parent), not 'scout' (substage)"
else
    fail "2" "stage_label='$stage_label_in_json', current='$_TUI_CURRENT_STAGE_LABEL', sub='$_TUI_CURRENT_SUBSTAGE_LABEL'"
fi
tui_substage_end "scout"
tui_stage_end "coder" "" "" "" "PASS"

# =============================================================================
echo "=== Invariant 3: Live-row timer continuity across substage begin/end ==="
# Opening and closing a substage inside a stage must not alter the parent
# stage's _TUI_STAGE_START_TS — the live-row timer is a property of the
# pipeline stage, not the substage.
_activate
tui_stage_begin "coder" "claude-opus-4-7"
parent_ts="$_TUI_STAGE_START_TS"

tui_substage_begin "scout" "claude-haiku-4-5"
mid_ts="$_TUI_STAGE_START_TS"
tui_substage_end "scout" "PASS"
end_ts="$_TUI_STAGE_START_TS"

if [[ "$parent_ts" == "$mid_ts" && "$parent_ts" == "$end_ts" && "$parent_ts" -gt 0 ]]; then
    pass "3: _TUI_STAGE_START_TS unchanged across substage begin/end (=$parent_ts)"
else
    fail "3" "parent ts changed: parent=$parent_ts mid=$mid_ts end=$end_ts"
fi
tui_stage_end "coder" "" "" "" "PASS"

# =============================================================================
echo "=== Invariant 4: Substage non-retention ==="
# tui_substage_end must not append to _TUI_STAGES_COMPLETE.
_activate
tui_stage_begin "review" "claude-opus-4-7"
before=${#_TUI_STAGES_COMPLETE[@]}

tui_substage_begin "rework" "claude-opus-4-7"
mid=${#_TUI_STAGES_COMPLETE[@]}
tui_substage_end "rework" "PASS"
after=${#_TUI_STAGES_COMPLETE[@]}

# Now end the parent — it SHOULD append exactly one record.
tui_stage_end "review" "claude-opus-4-7" "12/50" "45s" "CHANGES_REQUIRED"
final=${#_TUI_STAGES_COMPLETE[@]}

if (( before == 0 && mid == 0 && after == 0 && final == 1 )); then
    label=$(_stage_complete_label 1)
    if [[ "$label" == "review" ]]; then
        pass "4: substage end did not append; parent end appended one 'review' record"
    else
        fail "4" "expected single 'review' record, got label='$label'"
    fi
else
    fail "4" "stages_complete deltas: before=$before mid=$mid after=$after final=$final"
fi

# =============================================================================
echo "=== Invariant 5: Auto-close warn ==="
# Ending a stage while a substage is still open must auto-close the substage
# and emit exactly one warn event with the expected text.
_activate
tui_stage_begin "review" "claude-opus-4-7"
tui_substage_begin "rework" "claude-opus-4-7"
# Forget to call tui_substage_end before ending the parent.
tui_stage_end "review" "claude-opus-4-7" "20/50" "60s" "PASS"

if [[ -z "$_TUI_CURRENT_SUBSTAGE_LABEL" && "$_TUI_CURRENT_SUBSTAGE_START_TS" == "0" ]]; then
    pass "5a: substage globals cleared by parent end"
else
    fail "5a" "substage not auto-cleared (label='$_TUI_CURRENT_SUBSTAGE_LABEL')"
fi

warn_count=0
for e in "${_TUI_RECENT_EVENTS[@]:-}"; do
    [[ "$e" == *"substage 'rework' auto-closed by parent end"* ]] && warn_count=$((warn_count + 1))
done
if (( warn_count == 1 )); then
    pass "5b: exactly one auto-close warn event emitted"
else
    fail "5b" "expected 1 auto-close warn, got $warn_count"
fi

# =============================================================================
echo "=== Invariant 6: Opt-out no-op (TUI_LIFECYCLE_V2=false) ==="
# With TUI_LIFECYCLE_V2=false, substage functions must:
#   - set no globals (begin)
#   - leave globals untouched (end on a manually-set state)
#   - perform no status-file writes
#   - emit no events
# The auto-close helper invoked by tui_stage_end must also be silent.
_activate
# shellcheck disable=SC2034  # Read by lib/tui_ops_substage.sh and lib/common.sh
TUI_LIFECYCLE_V2=false
rm -f "$_TUI_STATUS_FILE"
events_before=${#_TUI_RECENT_EVENTS[@]}

tui_substage_begin "scout" "claude-haiku-4-5"

ok=true
[[ -n "$_TUI_CURRENT_SUBSTAGE_LABEL" ]] && ok=false
[[ "$_TUI_CURRENT_SUBSTAGE_START_TS" != "0" ]] && ok=false
[[ -f "$_TUI_STATUS_FILE" ]] && ok=false

# tui_substage_end on poisoned globals must leave them alone.
_TUI_CURRENT_SUBSTAGE_LABEL="poisoned"
_TUI_CURRENT_SUBSTAGE_START_TS=12345
tui_substage_end "poisoned" "PASS"
[[ "$_TUI_CURRENT_SUBSTAGE_LABEL" != "poisoned" ]] && ok=false
[[ "$_TUI_CURRENT_SUBSTAGE_START_TS" != "12345" ]] && ok=false

# Reset, then verify auto-close path is silent under V2=false.
_TUI_CURRENT_SUBSTAGE_LABEL="scout"
_TUI_CURRENT_SUBSTAGE_START_TS=999
tui_stage_begin "coder"
tui_stage_end "coder" "" "" "" "PASS"
warn_count=0
for e in "${_TUI_RECENT_EVENTS[@]:-}"; do
    [[ "$e" == *"auto-closed by parent end"* ]] && warn_count=$((warn_count + 1))
done
(( warn_count != 0 )) && ok=false

if [[ "$ok" == "true" ]]; then
    pass "6: substage API, status-file writes, and auto-close all silent under V2=false"
else
    fail "6" "opt-out violated: substage_label='$_TUI_CURRENT_SUBSTAGE_LABEL' ts='$_TUI_CURRENT_SUBSTAGE_START_TS' status_file_exists=$([[ -f $_TUI_STATUS_FILE ]] && echo yes || echo no) warn_count=$warn_count"
fi
events_delta=$(( ${#_TUI_RECENT_EVENTS[@]} - events_before ))
if (( events_delta == 0 )); then
    pass "6b: no events appended under V2=false"
else
    fail "6b" "events appended: delta=$events_delta"
fi

# =============================================================================
echo "=== Invariant 7: No parallel mechanism (grep-based) ==="
# The retired strings _TUI_OPERATION_LABEL, current_operation, and
# tui_stage_transition must not appear in production code (lib/, stages/,
# tekhton.sh). Tests that explicitly verify their absence (this file plus
# M115/M116 retirement-verification suites) are exempted; historical
# milestone docs and the milestone definition file are exempted by
# searching only the four production-code locations.
_violations_v7=()
_invariant7_check() {
    local needle="$1" path="$2"
    local found
    if [[ -d "$path" ]]; then
        found=$(grep -rln "$needle" "$path" 2>/dev/null || true)
    elif [[ -f "$path" ]]; then
        found=$(grep -ln "$needle" "$path" 2>/dev/null || true)
    fi
    if [[ -n "$found" ]]; then
        while IFS= read -r f; do
            _violations_v7+=("$needle in $f")
        done <<<"$found"
    fi
}

# Production code: zero tolerance.
for needle in "_TUI_OPERATION_LABEL" "current_operation" "tui_stage_transition"; do
    _invariant7_check "$needle" "${TEKHTON_HOME}/lib"
    _invariant7_check "$needle" "${TEKHTON_HOME}/stages"
    _invariant7_check "$needle" "${TEKHTON_HOME}/tekhton.sh"
done

# Filter out historical references baked into comments/docstrings that note
# the strings are RETIRED. The check is "no parallel mechanism" — comments
# about retirement do not constitute a parallel mechanism. Currently no such
# allowed comments exist in production code; if a grep below ever hits one,
# add an explicit allowlist entry here with a justification.

if (( ${#_violations_v7[@]} == 0 )); then
    pass "7: no parallel-mechanism strings found in lib/, stages/, tekhton.sh"
else
    echo "    violations:"
    for v in "${_violations_v7[@]}"; do echo "      - $v"; done
    fail "7" "${#_violations_v7[@]} occurrences of retired strings in production code"
fi

# =============================================================================
echo "=== Invariant 8: Attribution source correctness ==="
# An event emitted while a substage is active must carry source="parent » substage".
# An event emitted while only a stage is active must carry source="stage".
# An event emitted before any stage is opened must omit the source field.

# 8a: substage active.
_activate
tui_stage_begin "coder" "claude-opus-4-7"
tui_substage_begin "scout" "claude-haiku-4-5"
log "scanning"
got=$(_event_field source)
if [[ "$got" == "coder » scout" ]]; then
    pass "8a: source='coder » scout' during substage"
else
    fail "8a" "expected 'coder » scout', got '$got'"
fi
tui_substage_end "scout"

# 8b: stage active, no substage.
log "back in coder"
got=$(_event_field source)
if [[ "$got" == "coder" ]]; then
    pass "8b: source='coder' during stage with no substage"
else
    fail "8b" "expected 'coder', got '$got'"
fi
tui_stage_end "coder" "" "" "" "PASS"

# 8c: no stage active — JSON must omit the source key.
_activate
log "before any stage"
json=$(_last_event_json)
if [[ "$json" != *'"source"'* ]]; then
    pass "8c: source key absent in JSON when no stage/substage is active"
else
    fail "8c" "expected no 'source' key, got: $json"
fi

# =============================================================================
echo "=== Invariant 9: Preflight + intake ordering ==="
# Validates the M118 deferred-emit pattern: on the happy path, the
# stages_complete update for preflight (and intake) precedes the
# corresponding success event in the ring buffer. We model the call site
# ordering used by tekhton.sh (stage_end → success → ring-buffer event).
_activate

# --- preflight ---
tui_stage_begin "preflight"
tui_stage_end "preflight" "" "" "" "pass"
# A stages_complete entry now exists. Now the deferred success line emits.
tui_append_event "success" "preflight: ✔ deps env ports"

n=${#_TUI_STAGES_COMPLETE[@]}
preflight_complete_label=""
(( n > 0 )) && preflight_complete_label=$(_stage_complete_label "$n")

# Find the success event for preflight in the ring buffer; record its index.
preflight_event_index=-1
for ((i=0; i<${#_TUI_RECENT_EVENTS[@]}; i++)); do
    e="${_TUI_RECENT_EVENTS[$i]}"
    if [[ "$e" == *"preflight: ✔"* ]]; then
        preflight_event_index=$i
        break
    fi
done

if [[ "$preflight_complete_label" == "preflight" && "$preflight_event_index" -ge 0 ]]; then
    # The completion record was written during tui_stage_end (the call
    # immediately preceding tui_append_event), so by call-order the pill
    # update is committed before the event is appended.
    pass "9a: preflight stages_complete record exists before its success event"
else
    fail "9a" "preflight_complete_label='$preflight_complete_label' event_index=$preflight_event_index"
fi

# --- intake ---
tui_stage_begin "intake"
tui_stage_end "intake" "" "" "" "PASS"
tui_append_event "success" "Intake: task is clear. Proceeding."

n2=${#_TUI_STAGES_COMPLETE[@]}
intake_complete_label=""
(( n2 > 0 )) && intake_complete_label=$(_stage_complete_label "$n2")

intake_event_index=-1
for ((i=0; i<${#_TUI_RECENT_EVENTS[@]}; i++)); do
    e="${_TUI_RECENT_EVENTS[$i]}"
    if [[ "$e" == *"Intake: task is clear. Proceeding."* ]]; then
        intake_event_index=$i
        break
    fi
done

if [[ "$intake_complete_label" == "intake" && "$intake_event_index" -ge 0 ]]; then
    pass "9b: intake stages_complete record exists before its success event"
else
    fail "9b" "intake_complete_label='$intake_complete_label' event_index=$intake_event_index"
fi

# Cross-check the deferred-emit globals consumed by tekhton.sh exist as
# hand-off vehicles (_PREFLIGHT_SUMMARY, _INTAKE_PASS_EMIT). Their consumer
# block in tekhton.sh runs AFTER tui_stage_end, so the documented ordering
# is preserved at the source level, not just in this synthetic harness.
if grep -q "_PREFLIGHT_SUMMARY" "${TEKHTON_HOME}/lib/preflight.sh" \
   && grep -q "_INTAKE_PASS_EMIT" "${TEKHTON_HOME}/stages/intake.sh"; then
    pass "9c: deferred-emit globals declared in producing modules"
else
    fail "9c" "missing _PREFLIGHT_SUMMARY or _INTAKE_PASS_EMIT producer reference"
fi

# Cross-check tekhton.sh consumes the globals AFTER tui_stage_end for both
# stages — i.e. the success-emit lines appear after a tui_stage_end call for
# the same stage. We verify by line ordering.
_grep_after() {
    # _grep_after FILE STAGE_END_PATTERN GLOBAL_PATTERN
    # Returns 0 if the line matching GLOBAL_PATTERN comes after the line
    # matching STAGE_END_PATTERN in the file.
    local file="$1" stage_pat="$2" global_pat="$3"
    local stage_line global_line
    stage_line=$(grep -n -- "$stage_pat" "$file" 2>/dev/null | head -1 | cut -d: -f1)
    global_line=$(grep -n -- "$global_pat" "$file" 2>/dev/null | head -1 | cut -d: -f1)
    [[ -n "$stage_line" && -n "$global_line" ]] || return 1
    (( global_line > stage_line ))
}

if _grep_after "${TEKHTON_HOME}/tekhton.sh" 'tui_stage_end "preflight"' '_PREFLIGHT_SUMMARY'; then
    pass "9d: tekhton.sh consumes _PREFLIGHT_SUMMARY after tui_stage_end \"preflight\""
else
    fail "9d" "ordering: _PREFLIGHT_SUMMARY consumer is not after tui_stage_end \"preflight\""
fi
if _grep_after "${TEKHTON_HOME}/tekhton.sh" 'tui_stage_end "intake"' '_INTAKE_PASS_EMIT'; then
    pass "9e: tekhton.sh consumes _INTAKE_PASS_EMIT after tui_stage_end \"intake\""
else
    fail "9e" "ordering: _INTAKE_PASS_EMIT consumer is not after tui_stage_end \"intake\""
fi

# =============================================================================
echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
