#!/usr/bin/env bash
# =============================================================================
# test_m116_substage_migration.sh — M116 — rework + architect-remediation
# migration to the M113 substage API; tui_stage_transition retirement.
#
# Primary behavior under test: when review.sh wraps rework in tui_substage_begin/end
# (instead of tui_stage_begin/end), stages_complete records only the parent
# "review" entry — no "rework" breadcrumb entries appear. Same invariant for
# architect wrapping architect-remediation.
#
# Also verifies that tui_stage_transition is absent from tui_ops.sh, review.sh,
# and architect.sh, and that the BUILD_BROKEN early-return in architect.sh
# properly closes both the substage and the parent stage.
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

# _activate — initialize all TUI globals to a clean active state with file writes.
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
}

# Read a top-level string field from the current status JSON file.
_json_field() {
    python3 -c "
import json, sys
d = json.load(open('$_TUI_STATUS_FILE'))
v = d.get('$1')
print('<MISSING>' if v is None else str(v))
" 2>/dev/null
}

# Count entries in stages_complete whose 'label' matches argument.
_stages_complete_count_for_label() {
    local target="$1"
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
c = sum(1 for s in d.get('stages_complete', []) if s.get('label') == '$target')
print(c)
" 2>/dev/null
}

# CSV of all stages_complete labels in order.
_stages_complete_labels_csv() {
    python3 -c "
import json
d = json.load(open('$_TUI_STATUS_FILE'))
labels = [s.get('label', '') for s in d.get('stages_complete', [])]
print(','.join(labels))
" 2>/dev/null
}

# =============================================================================
echo "=== M116-1: rework substage inside review — stages_complete has review, zero rework ==="
# AC: "During a review cycle with rework, stages_complete contains exactly one
# review entry per cycle and NO rework entries."
_activate
tui_stage_begin "review" "claude-sonnet-4-6"
tui_substage_begin "rework" "claude-opus-4-7"
tui_substage_end "rework" ""
tui_stage_end "review" "claude-sonnet-4-6" "15/30" "45s" "APPROVED"

review_count=$(_stages_complete_count_for_label "review")
rework_count=$(_stages_complete_count_for_label "rework")

if [[ "$review_count" -eq 1 ]]; then
    pass "M116-1a: stages_complete has exactly 1 review entry after review+rework cycle"
else
    fail "M116-1a: review entry count" "expected 1, got $review_count (labels='$(_stages_complete_labels_csv)')"
fi

if [[ "$rework_count" -eq 0 ]]; then
    pass "M116-1b: stages_complete has 0 rework entries (rework used substage API)"
else
    fail "M116-1b: rework entry count" "expected 0, got $rework_count (labels='$(_stages_complete_labels_csv)')"
fi

# =============================================================================
echo "=== M116-2: two rework substage cycles inside review — 1 review, 0 rework entries ==="
_activate
tui_stage_begin "review" "claude-sonnet-4-6"
# First rework cycle
tui_substage_begin "rework" "claude-opus-4-7"
tui_substage_end "rework" ""
# Second rework cycle
tui_substage_begin "rework" "claude-opus-4-7"
tui_substage_end "rework" ""
tui_stage_end "review" "claude-sonnet-4-6" "30/50" "90s" "APPROVED"

review_count=$(_stages_complete_count_for_label "review")
rework_count=$(_stages_complete_count_for_label "rework")

if [[ "$review_count" -eq 1 ]]; then
    pass "M116-2a: two rework cycles produce exactly 1 review entry in stages_complete"
else
    fail "M116-2a: review entry count (two cycles)" "expected 1, got $review_count"
fi

if [[ "$rework_count" -eq 0 ]]; then
    pass "M116-2b: two rework substage cycles produce 0 rework entries in stages_complete"
else
    fail "M116-2b: rework entry count (two cycles)" "expected 0, got $rework_count"
fi

# =============================================================================
echo "=== M116-3: architect-remediation substage inside architect — 1 architect, 0 architect-remediation entries ==="
# AC: "During an architect audit with remediation, stages_complete contains
# exactly one architect entry and NO architect-remediation entry."
_activate
tui_stage_begin "architect" "claude-opus-4-7"
tui_substage_begin "architect-remediation" "claude-opus-4-7"
tui_substage_end "architect-remediation" ""
tui_stage_end "architect" "claude-opus-4-7" "20/25" "120s" ""

architect_count=$(_stages_complete_count_for_label "architect")
remediation_count=$(_stages_complete_count_for_label "architect-remediation")

if [[ "$architect_count" -eq 1 ]]; then
    pass "M116-3a: stages_complete has exactly 1 architect entry"
else
    fail "M116-3a: architect entry count" "expected 1, got $architect_count (labels='$(_stages_complete_labels_csv)')"
fi

if [[ "$remediation_count" -eq 0 ]]; then
    pass "M116-3b: stages_complete has 0 architect-remediation entries (it is a substage)"
else
    fail "M116-3b: architect-remediation entry count" "expected 0, got $remediation_count"
fi

# =============================================================================
echo "=== M116-4: JSON breadcrumb shows review » rework during rework substage ==="
# AC: "The stage-timings live row reads 'review » rework' while the jr-coder
# rework agent runs; the timer is continuous across rework entry/exit."
_activate
tui_stage_begin "review" "claude-sonnet-4-6"
tui_substage_begin "rework" "claude-opus-4-7"

# Parent stage label must remain "review" while substage is active
parent_label=$(_json_field stage_label)
if [[ "$parent_label" == "review" ]]; then
    pass "M116-4a: stage_label stays 'review' while rework substage is active"
else
    fail "M116-4a: parent label during rework" "expected 'review', got '$parent_label'"
fi

# Substage label must be "rework" during the substage
substage_label=$(_json_field current_substage_label)
if [[ "$substage_label" == "rework" ]]; then
    pass "M116-4b: current_substage_label='rework' in JSON (breadcrumb active)"
else
    fail "M116-4b: substage label" "expected 'rework', got '$substage_label'"
fi

# After substage_end the breadcrumb should clear
tui_substage_end "rework" ""
substage_after=$(_json_field current_substage_label)
if [[ "$substage_after" == "" ]]; then
    pass "M116-4c: current_substage_label cleared after rework substage_end"
else
    fail "M116-4c: substage label after end" "expected '', got '$substage_after'"
fi

tui_stage_end "review" "claude-sonnet-4-6" "" "" ""

# =============================================================================
echo "=== M116-5: JSON breadcrumb shows architect » architect-remediation during remediation ==="
# AC: "The stage-timings live row reads 'architect » architect-remediation'
# during remediation."
_activate
tui_stage_begin "architect" "claude-opus-4-7"
tui_substage_begin "architect-remediation" "claude-opus-4-7"

parent_label=$(_json_field stage_label)
if [[ "$parent_label" == "architect" ]]; then
    pass "M116-5a: stage_label stays 'architect' while architect-remediation substage active"
else
    fail "M116-5a: parent label during remediation" "expected 'architect', got '$parent_label'"
fi

substage_label=$(_json_field current_substage_label)
if [[ "$substage_label" == "architect-remediation" ]]; then
    pass "M116-5b: current_substage_label='architect-remediation' in JSON"
else
    fail "M116-5b: substage label" "expected 'architect-remediation', got '$substage_label'"
fi

tui_substage_end "architect-remediation" ""
tui_stage_end "architect" "claude-opus-4-7" "" "" ""

# =============================================================================
echo "=== M116-6: tui_stage_transition absent from lib/tui_ops.sh ==="
# AC: "tui_stage_transition does not appear in any .sh file under lib/, stages/,
# tekhton.sh, or tests/"
if ! grep -q "tui_stage_transition" "${TEKHTON_HOME}/lib/tui_ops.sh"; then
    pass "M116-6a: tui_stage_transition not present in lib/tui_ops.sh (deleted per M116)"
else
    fail "M116-6a: tui_stage_transition still present" "lib/tui_ops.sh still defines the deleted function"
fi

# Also verify the function is not callable from the sourced environment
if ! declare -f tui_stage_transition &>/dev/null; then
    pass "M116-6b: tui_stage_transition not callable after sourcing lib/tui.sh"
else
    fail "M116-6b: tui_stage_transition callable" "function still exists in shell env after sourcing tui.sh"
fi

# =============================================================================
echo "=== M116-7: tui_stage_transition absent from stages/review.sh ==="
if ! grep -q "tui_stage_transition" "${TEKHTON_HOME}/stages/review.sh"; then
    pass "M116-7: tui_stage_transition not present in stages/review.sh"
else
    fail "M116-7: tui_stage_transition in review.sh" "migration not applied to stages/review.sh"
fi

# =============================================================================
echo "=== M116-8: tui_stage_transition absent from stages/architect.sh ==="
if ! grep -q "tui_stage_transition" "${TEKHTON_HOME}/stages/architect.sh"; then
    pass "M116-8: tui_stage_transition not present in stages/architect.sh"
else
    fail "M116-8: tui_stage_transition in architect.sh" "migration not applied to stages/architect.sh"
fi

# =============================================================================
echo "=== M116-9: stages/review.sh calls tui_substage_begin/end for rework ==="
if grep -q 'tui_substage_begin "rework"' "${TEKHTON_HOME}/stages/review.sh"; then
    pass "M116-9a: stages/review.sh has tui_substage_begin 'rework'"
else
    fail "M116-9a: substage_begin rework absent" "expected 'tui_substage_begin \"rework\"' in stages/review.sh"
fi

if grep -q 'tui_substage_end "rework"' "${TEKHTON_HOME}/stages/review.sh"; then
    pass "M116-9b: stages/review.sh has tui_substage_end 'rework'"
else
    fail "M116-9b: substage_end rework absent" "expected 'tui_substage_end \"rework\"' in stages/review.sh"
fi

# Verify both rework call sites were migrated (there are two branches: complex
# blockers and simple-only blockers; each needs its own substage pair).
complex_begin=$(grep -c 'tui_substage_begin "rework"' "${TEKHTON_HOME}/stages/review.sh" 2>/dev/null || echo "0")
complex_end=$(grep -c 'tui_substage_end "rework"' "${TEKHTON_HOME}/stages/review.sh" 2>/dev/null || echo "0")

if [[ "$complex_begin" -ge 2 ]]; then
    pass "M116-9c: both rework call sites migrated (tui_substage_begin count >= 2)"
else
    fail "M116-9c: rework substage_begin count" "expected >= 2, got $complex_begin — one branch may be unmigrated"
fi

if [[ "$complex_end" -ge 2 ]]; then
    pass "M116-9d: both rework end calls present (tui_substage_end count >= 2)"
else
    fail "M116-9d: rework substage_end count" "expected >= 2, got $complex_end"
fi

# =============================================================================
echo "=== M116-10: stages/architect.sh calls tui_substage_begin/end for architect-remediation ==="
if grep -q 'tui_substage_begin "architect-remediation"' "${TEKHTON_HOME}/stages/architect.sh"; then
    pass "M116-10a: stages/architect.sh has tui_substage_begin 'architect-remediation'"
else
    fail "M116-10a: substage_begin absent" "expected 'tui_substage_begin \"architect-remediation\"' in architect.sh"
fi

if grep -q 'tui_substage_end "architect-remediation"' "${TEKHTON_HOME}/stages/architect.sh"; then
    pass "M116-10b: stages/architect.sh has tui_substage_end 'architect-remediation'"
else
    fail "M116-10b: substage_end absent" "expected 'tui_substage_end \"architect-remediation\"' in architect.sh"
fi

# =============================================================================
echo "=== M116-11: BUILD_BROKEN early-return in architect.sh closes substage then stage ==="
# The BUILD_BROKEN path must close architect-remediation substage first, then
# close the architect stage — so the parent stage is never left open.
if grep -q 'tui_substage_end "architect-remediation" "BUILD_BROKEN"' "${TEKHTON_HOME}/stages/architect.sh"; then
    pass "M116-11a: architect.sh closes substage with BUILD_BROKEN verdict on early return"
else
    fail "M116-11a: BUILD_BROKEN substage close missing" \
         "expected 'tui_substage_end \"architect-remediation\" \"BUILD_BROKEN\"' in architect.sh"
fi

if grep -q '"BUILD_BROKEN"' "${TEKHTON_HOME}/stages/architect.sh" && \
   grep -q 'tui_stage_end "architect"' "${TEKHTON_HOME}/stages/architect.sh"; then
    pass "M116-11b: architect.sh closes parent architect stage on BUILD_BROKEN path"
else
    fail "M116-11b: BUILD_BROKEN stage close" \
         "expected tui_stage_end 'architect' with BUILD_BROKEN verdict in architect.sh"
fi

# Verify ordering in the BUILD_BROKEN block: substage_end must precede stage_end.
# Extract line numbers for both calls to confirm ordering.
sub_end_line=$(grep -n 'tui_substage_end "architect-remediation" "BUILD_BROKEN"' \
    "${TEKHTON_HOME}/stages/architect.sh" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")
stage_end_after_broken=$(grep -n 'tui_stage_end "architect".*"BUILD_BROKEN"' \
    "${TEKHTON_HOME}/stages/architect.sh" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")

if [[ "$sub_end_line" -gt 0 && "$stage_end_after_broken" -gt 0 ]]; then
    if [[ "$sub_end_line" -lt "$stage_end_after_broken" ]]; then
        pass "M116-11c: substage_end (line $sub_end_line) precedes stage_end (line $stage_end_after_broken) in BUILD_BROKEN path"
    else
        fail "M116-11c: close ordering" \
             "substage_end (line $sub_end_line) should precede stage_end (line $stage_end_after_broken)"
    fi
else
    fail "M116-11c: line numbers not found" \
         "sub_end_line=$sub_end_line stage_end_line=$stage_end_after_broken"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
