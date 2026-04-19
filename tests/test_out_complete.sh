#!/usr/bin/env bash
# =============================================================================
# test_out_complete.sh — M102 — out_complete() and _hook_tui_complete() tests
#
# Covers:
#   1. out_complete() is a no-op when tui_complete is not defined
#   2. out_complete() delegates to tui_complete when it IS defined
#   3. out_complete "SUCCESS" passes "SUCCESS" to tui_complete
#   4. out_complete "FAIL" passes "FAIL" to tui_complete
#   5. out_complete silently no-ops when tui_complete is unset (no error)
#   6. _hook_tui_complete 0  → out_complete called with "SUCCESS"
#   7. _hook_tui_complete 1  → out_complete called with "FAIL"
#   8. _hook_tui_complete 42 → out_complete called with "FAIL" (any non-zero)
#   9. _hook_tui_complete does NOT call tui_complete directly (uses out_complete)
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
_tui_notify()     { :; }
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""

# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"
# shellcheck source=../lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

# =============================================================================
echo "=== Part 1: out_complete() behaviour ==="
# =============================================================================

# --- Test 1: no-op when tui_complete is not defined --------------------------
echo "--- Test 1: no-op when tui_complete absent ---"

# Ensure tui_complete is NOT defined
if declare -f tui_complete &>/dev/null; then unset -f tui_complete; fi

_GOT_ERROR=0
out_complete "SUCCESS" 2>/dev/null || _GOT_ERROR=1

if [[ "$_GOT_ERROR" -eq 0 ]]; then
    pass "out_complete exits 0 when tui_complete is not defined"
else
    fail "out_complete no-op" "unexpected non-zero exit when tui_complete is absent"
fi

# --- Test 2: delegates to tui_complete when defined --------------------------
echo "--- Test 2: delegates to tui_complete ---"

_CALLED_VERDICT=""
tui_complete() { _CALLED_VERDICT="$1"; }

# shellcheck disable=SC2218  # out_complete sourced from output.sh above; shellcheck can't follow.
out_complete "SUCCESS"

if [[ -n "$_CALLED_VERDICT" ]]; then
    pass "out_complete calls tui_complete when it is defined"
else
    fail "out_complete delegate" "tui_complete was not called"
fi

# --- Test 3: passes "SUCCESS" verdict ----------------------------------------
echo "--- Test 3: passes SUCCESS verdict ---"

_CALLED_VERDICT=""
# shellcheck disable=SC2218  # out_complete sourced from output.sh; shellcheck can't follow.
out_complete "SUCCESS"

if [[ "$_CALLED_VERDICT" == "SUCCESS" ]]; then
    pass "out_complete passes 'SUCCESS' verdict to tui_complete"
else
    fail "out_complete SUCCESS" "expected 'SUCCESS', got '${_CALLED_VERDICT}'"
fi

# --- Test 4: passes "FAIL" verdict -------------------------------------------
echo "--- Test 4: passes FAIL verdict ---"

_CALLED_VERDICT=""
# shellcheck disable=SC2218  # out_complete sourced from output.sh; shellcheck can't follow.
out_complete "FAIL"

if [[ "$_CALLED_VERDICT" == "FAIL" ]]; then
    pass "out_complete passes 'FAIL' verdict to tui_complete"
else
    fail "out_complete FAIL" "expected 'FAIL', got '${_CALLED_VERDICT}'"
fi

# --- Test 5: no-op silently after tui_complete unset again -------------------
echo "--- Test 5: silent no-op after tui_complete unset ---"

unset -f tui_complete

_GOT_ERROR=0
out_complete "DONE" 2>/dev/null || _GOT_ERROR=1

if [[ "$_GOT_ERROR" -eq 0 ]]; then
    pass "out_complete silently no-ops when tui_complete is unset"
else
    fail "out_complete silent no-op" "error when tui_complete not defined"
fi

# =============================================================================
echo "=== Part 2: _hook_tui_complete() behaviour ==="
#
# _hook_tui_complete is defined in lib/finalize.sh. We extract it here using
# awk so we test the real function body from the source file, not a hand-copy.
# =============================================================================

# Extract _hook_tui_complete from finalize.sh via awk state-machine.
# Matches the function header, accumulates until the closing "}" at column 0.
_HOOK_TUI_FN=$(awk '
    /^_hook_tui_complete\(\)/ { p=1 }
    p { print }
    p && /^\}[[:space:]]*$/ { exit }
' "${TEKHTON_HOME}/lib/finalize.sh")

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

# Override out_complete to record the verdict it receives.
_COMPLETE_CALLED_WITH=""
out_complete() { _COMPLETE_CALLED_WITH="${1:-}"; }

# --- Test 6: exit 0 → "SUCCESS" ----------------------------------------------
echo "--- Test 6: exit 0 → SUCCESS ---"

_COMPLETE_CALLED_WITH=""
_hook_tui_complete 0

if [[ "$_COMPLETE_CALLED_WITH" == "SUCCESS" ]]; then
    pass "_hook_tui_complete with exit 0 passes 'SUCCESS' to out_complete"
else
    fail "_hook_tui_complete exit 0" "expected 'SUCCESS', got '${_COMPLETE_CALLED_WITH}'"
fi

# --- Test 7: exit 1 → "FAIL" -------------------------------------------------
echo "--- Test 7: exit 1 → FAIL ---"

_COMPLETE_CALLED_WITH=""
_hook_tui_complete 1

if [[ "$_COMPLETE_CALLED_WITH" == "FAIL" ]]; then
    pass "_hook_tui_complete with exit 1 passes 'FAIL' to out_complete"
else
    fail "_hook_tui_complete exit 1" "expected 'FAIL', got '${_COMPLETE_CALLED_WITH}'"
fi

# --- Test 8: any non-zero exit → "FAIL" --------------------------------------
echo "--- Test 8: exit 42 → FAIL ---"

_COMPLETE_CALLED_WITH=""
_hook_tui_complete 42

if [[ "$_COMPLETE_CALLED_WITH" == "FAIL" ]]; then
    pass "_hook_tui_complete with exit 42 passes 'FAIL' to out_complete"
else
    fail "_hook_tui_complete exit 42" "expected 'FAIL', got '${_COMPLETE_CALLED_WITH}'"
fi

# --- Test 9: routes through out_complete, not tui_complete directly ----------
echo "--- Test 9: no direct tui_complete call ---"

# Define tui_complete as a canary — if _hook_tui_complete calls it directly,
# the test fails. (The real path is: _hook_tui_complete → out_complete → if
# tui_complete defined, call it. Here out_complete is our mock so the canary
# is never reached unless _hook_tui_complete bypasses out_complete.)
_CANARY_CALLED=0
tui_complete() { _CANARY_CALLED=1; }

_COMPLETE_CALLED_WITH=""
_hook_tui_complete 0

# out_complete mock does NOT call through to tui_complete, so canary stays 0.
# If _hook_tui_complete calls tui_complete directly, canary fires.
if [[ "$_CANARY_CALLED" -eq 0 ]]; then
    pass "_hook_tui_complete does not call tui_complete directly (routes via out_complete)"
else
    fail "_hook_tui_complete routing" "tui_complete was called directly, bypassing out_complete"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
