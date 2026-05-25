#!/usr/bin/env bash
# =============================================================================
# test_out_complete.sh — M111 — out_complete() and _hook_tui_complete() tests
#
# Covers:
#   1. out_complete() is a no-op when _sidecar_complete_hold is not defined
#   2. out_complete() delegates to _sidecar_complete_hold when it IS defined
#   3. out_complete "SUCCESS" passes "SUCCESS" through
#   4. out_complete "FAIL" passes "FAIL" through
#   5. out_complete silently no-ops when _sidecar_complete_hold is unset
#   6. _hook_tui_complete 0  → emits summary event, does NOT call out_complete
#   7. _hook_tui_complete 1  → emits summary event, does NOT call out_complete
#   8. _hook_tui_complete 42 → emits summary event, does NOT call out_complete
#   9. _hook_tui_complete 0  → calls stage-end wrap-up SUCCESS via _tui_call
#  10. _hook_tui_complete 1  → calls stage-end wrap-up FAIL via _tui_call
#
# m23 update: the bash `tui_*` shim functions are deleted. out_complete now
# delegates to lib/sidecar_lifecycle.sh::_sidecar_complete_hold, and the
# _hook_tui_complete hook body invokes `tekhton tui stage-end / append-event`
# through the shared _tui_call helper instead of bash function calls.
#
# M111 invariant preserved: _hook_tui_complete still does NOT trigger
# out_complete (which would kill the sidecar mid-run). Per-pass finalize_run()
# only closes the wrap-up pill and emits a pass-complete summary event; the
# outer tekhton.sh dispatch site calls out_complete once at true teardown.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# ── Stubs required before sourcing output.sh ──────────────────────────────────
_tui_strip_ansi() { printf '%s' "$*"; }
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""

# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"
# shellcheck source=../lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

# =============================================================================
echo "=== Part 1: out_complete() behaviour ==="
# =============================================================================

# --- Test 1: no-op when _sidecar_complete_hold is not defined ----------------
echo "--- Test 1: no-op when _sidecar_complete_hold absent ---"

# Ensure _sidecar_complete_hold is NOT defined.
if declare -f _sidecar_complete_hold &>/dev/null; then unset -f _sidecar_complete_hold; fi

_GOT_ERROR=0
out_complete "SUCCESS" 2>/dev/null || _GOT_ERROR=1

if [[ "$_GOT_ERROR" -eq 0 ]]; then
    pass "out_complete exits 0 when _sidecar_complete_hold is not defined"
else
    fail "out_complete no-op" "unexpected non-zero exit when _sidecar_complete_hold absent"
fi

# --- Test 2: delegates to _sidecar_complete_hold when defined ----------------
echo "--- Test 2: delegates to _sidecar_complete_hold ---"

_CALLED_VERDICT=""
_sidecar_complete_hold() { _CALLED_VERDICT="$1"; }

out_complete "SUCCESS"

if [[ -n "$_CALLED_VERDICT" ]]; then
    pass "out_complete calls _sidecar_complete_hold when defined"
else
    fail "out_complete delegate" "_sidecar_complete_hold was not called"
fi

# --- Test 3: passes "SUCCESS" verdict ----------------------------------------
echo "--- Test 3: passes SUCCESS verdict ---"

_CALLED_VERDICT=""
out_complete "SUCCESS"

if [[ "$_CALLED_VERDICT" == "SUCCESS" ]]; then
    pass "out_complete passes 'SUCCESS' verdict to _sidecar_complete_hold"
else
    fail "out_complete SUCCESS" "expected 'SUCCESS', got '${_CALLED_VERDICT}'"
fi

# --- Test 4: passes "FAIL" verdict -------------------------------------------
echo "--- Test 4: passes FAIL verdict ---"

_CALLED_VERDICT=""
out_complete "FAIL"

if [[ "$_CALLED_VERDICT" == "FAIL" ]]; then
    pass "out_complete passes 'FAIL' verdict to _sidecar_complete_hold"
else
    fail "out_complete FAIL" "expected 'FAIL', got '${_CALLED_VERDICT}'"
fi

# --- Test 5: no-op silently after _sidecar_complete_hold unset ---------------
echo "--- Test 5: silent no-op after _sidecar_complete_hold unset ---"

unset -f _sidecar_complete_hold

_GOT_ERROR=0
out_complete "DONE" 2>/dev/null || _GOT_ERROR=1

if [[ "$_GOT_ERROR" -eq 0 ]]; then
    pass "out_complete silently no-ops when _sidecar_complete_hold unset"
else
    fail "out_complete silent no-op" "error when _sidecar_complete_hold not defined"
fi

# =============================================================================
echo "=== Part 2: _hook_tui_complete() behaviour (M111 contract) ==="
#
# _hook_tui_complete is defined in lib/finalize_dashboard_hooks.sh. We extract
# it here via awk so we test the real function body from the source file, not
# a hand-copy.
# =============================================================================

# Extract _hook_tui_complete via awk state-machine.
# Matches the function header, accumulates until the closing "}" at column 0.
_HOOK_TUI_FN=$(awk '
    /^_hook_tui_complete\(\)/ { p=1 }
    p { print }
    p && /^\}[[:space:]]*$/ { exit }
' "${TEKHTON_HOME}/lib/finalize_dashboard_hooks.sh")

if [[ -z "$_HOOK_TUI_FN" ]]; then
    fail "_hook_tui_complete extraction" "awk returned empty — check finalize.sh format"
    echo ""
    echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
    exit 1
fi

# Source the extracted function into the current shell.
eval "$_HOOK_TUI_FN"

# Verify it's callable before proceeding.
if ! declare -f _hook_tui_complete &>/dev/null; then
    fail "_hook_tui_complete load" "_hook_tui_complete not defined after eval"
    echo ""
    echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
    exit 1
fi

# Mock collaborators. _hook_tui_complete (post-m23) should:
#   - call `_tui_call stage-end --label wrap-up ... --verdict <verdict>`
#   - call `_tui_call append-event --level <level> --message "Pass complete: <verdict>" --type summary`
#   - NOT call out_complete (that would tear down the sidecar mid-run)
_COMPLETE_CALLED_WITH=""
out_complete() { _COMPLETE_CALLED_WITH="${1:-}"; }

_STAGE_END_LABEL=""; _STAGE_END_VERDICT=""
_SUMMARY_EVENT_LEVEL=""; _SUMMARY_EVENT_MSG=""

# _tui_call parses subcommand + flag args; we record what each invocation
# attempted. Mirrors the real helper's flag layout: --label LBL --verdict V
# for stage-end, --level L --message M --type summary for append-event.
_tui_call() {
    local sub="${1:-}"; shift || true
    local label="" verdict="" level="" message="" event_type=""
    while (( $# > 0 )); do
        case "$1" in
            --label)       label="${2:-}";      shift 2 ;;
            --verdict)     verdict="${2:-}";    shift 2 ;;
            --level)       level="${2:-}";      shift 2 ;;
            --message)     message="${2:-}";    shift 2 ;;
            --type)        event_type="${2:-}"; shift 2 ;;
            --status-file) shift 2 ;;
            *)             shift ;;
        esac
    done
    case "$sub" in
        stage-end)
            _STAGE_END_LABEL="$label"
            _STAGE_END_VERDICT="$verdict"
            ;;
        append-event)
            if [[ "$event_type" == "summary" ]]; then
                _SUMMARY_EVENT_LEVEL="$level"
                _SUMMARY_EVENT_MSG="$message"
            fi
            ;;
    esac
}

# _hook_tui_complete only emits when TUI is active in the live runtime; in
# this test we drive the body directly, so force the gate open.
_TUI_ACTIVE=true
export _TUI_ACTIVE

# --- Test 6: exit 0 → summary event, no out_complete -------------------------
echo "--- Test 6: exit 0 → summary event, no out_complete ---"

_COMPLETE_CALLED_WITH=""
_SUMMARY_EVENT_LEVEL=""; _SUMMARY_EVENT_MSG=""
_hook_tui_complete 0

if [[ -z "$_COMPLETE_CALLED_WITH" ]] \
   && [[ "$_SUMMARY_EVENT_MSG" == "Pass complete: SUCCESS" ]]; then
    pass "_hook_tui_complete exit 0 emits SUCCESS summary event, no out_complete"
else
    fail "_hook_tui_complete exit 0" \
        "out_complete='${_COMPLETE_CALLED_WITH}' summary_msg='${_SUMMARY_EVENT_MSG}'"
fi

# --- Test 7: exit 1 → summary event, no out_complete -------------------------
echo "--- Test 7: exit 1 → summary event, no out_complete ---"

_COMPLETE_CALLED_WITH=""
_SUMMARY_EVENT_LEVEL=""; _SUMMARY_EVENT_MSG=""
_hook_tui_complete 1

if [[ -z "$_COMPLETE_CALLED_WITH" ]] \
   && [[ "$_SUMMARY_EVENT_MSG" == "Pass complete: FAIL" ]]; then
    pass "_hook_tui_complete exit 1 emits FAIL summary event, no out_complete"
else
    fail "_hook_tui_complete exit 1" \
        "out_complete='${_COMPLETE_CALLED_WITH}' summary_msg='${_SUMMARY_EVENT_MSG}'"
fi

# --- Test 8: any non-zero exit → FAIL summary --------------------------------
echo "--- Test 8: exit 42 → FAIL summary event ---"

_COMPLETE_CALLED_WITH=""
_SUMMARY_EVENT_LEVEL=""; _SUMMARY_EVENT_MSG=""
_hook_tui_complete 42

if [[ -z "$_COMPLETE_CALLED_WITH" ]] \
   && [[ "$_SUMMARY_EVENT_MSG" == "Pass complete: FAIL" ]]; then
    pass "_hook_tui_complete exit 42 emits FAIL summary event, no out_complete"
else
    fail "_hook_tui_complete exit 42" \
        "out_complete='${_COMPLETE_CALLED_WITH}' summary_msg='${_SUMMARY_EVENT_MSG}'"
fi

# --- Test 9: closes wrap-up pill with SUCCESS verdict on exit 0 --------------
echo "--- Test 9: exit 0 → stage-end wrap-up SUCCESS ---"

_STAGE_END_LABEL=""; _STAGE_END_VERDICT=""
_hook_tui_complete 0

if [[ "$_STAGE_END_LABEL" == "wrap-up" ]] && [[ "$_STAGE_END_VERDICT" == "SUCCESS" ]]; then
    pass "_hook_tui_complete exit 0 closes wrap-up pill with SUCCESS"
else
    fail "_hook_tui_complete wrap-up SUCCESS" \
        "label='${_STAGE_END_LABEL}' verdict='${_STAGE_END_VERDICT}'"
fi

# --- Test 10: closes wrap-up pill with FAIL verdict on exit 1 ----------------
echo "--- Test 10: exit 1 → stage-end wrap-up FAIL ---"

_STAGE_END_LABEL=""; _STAGE_END_VERDICT=""
_hook_tui_complete 1

if [[ "$_STAGE_END_LABEL" == "wrap-up" ]] && [[ "$_STAGE_END_VERDICT" == "FAIL" ]]; then
    pass "_hook_tui_complete exit 1 closes wrap-up pill with FAIL"
else
    fail "_hook_tui_complete wrap-up FAIL" \
        "label='${_STAGE_END_LABEL}' verdict='${_STAGE_END_VERDICT}'"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
