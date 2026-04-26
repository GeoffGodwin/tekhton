#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_build_fix_helpers.sh — Pure-function unit tests for the M128 helpers
#
# Covers test cases T1 and T2 from m128-build-fix-continuation-adaptive-budget.md:
#   _build_fix_progress_signal — improved | unchanged | worsened truth table
#   _compute_build_fix_budget  — adaptive schedule + lower/upper clamp +
#                                cumulative-cap math
#
# Pure-function tests need no stubs, no pipeline state, and no I/O. Loop-level
# integration tests live in test_build_fix_loop.sh (T3–T10).
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "${name}: expected '${expected}', got '${actual}'"
    fi
}

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder_buildfix_helpers.sh"

# =============================================================================
# T1: unit_progress_signal_truth_table
# =============================================================================
echo "=== T1: _build_fix_progress_signal truth table ==="
assert_eq "T1a 10→5 improved"   "improved"  "$(_build_fix_progress_signal 10 5  tail-A tail-B)"
assert_eq "T1b 5→10 worsened"   "worsened"  "$(_build_fix_progress_signal 5  10 tail-A tail-B)"
assert_eq "T1c 7=7 same tail"   "unchanged" "$(_build_fix_progress_signal 7  7  x x)"
assert_eq "T1d 7=7 diff tail"   "improved"  "$(_build_fix_progress_signal 7  7  x y)"

# =============================================================================
# T2: unit_compute_budget_clamps
# =============================================================================
echo "=== T2: _compute_build_fix_budget adaptive schedule + clamps ==="
export EFFECTIVE_CODER_MAX_TURNS=60
export BUILD_FIX_MAX_TURN_MULTIPLIER=100
export BUILD_FIX_TOTAL_TURN_CAP=300

# Adaptive schedule
assert_eq "T2a attempt=1 1.0x base=20"     "20" "$(_compute_build_fix_budget 1 20 0)"
assert_eq "T2b attempt=2 1.5x base=20"     "30" "$(_compute_build_fix_budget 2 20 0)"
assert_eq "T2c attempt=3 2.0x base=20"     "40" "$(_compute_build_fix_budget 3 20 0)"

# Lower clamp 8: base=2 → attempt 1 floored to 8
assert_eq "T2d lower clamp 8 (base=2)"     "8"  "$(_compute_build_fix_budget 1 2 0)"

# Upper clamp: base=50, attempt=3 → 100; max=60, multiplier=100 → upper=60 → 60
export EFFECTIVE_CODER_MAX_TURNS=60
export BUILD_FIX_MAX_TURN_MULTIPLIER=100
assert_eq "T2e upper clamp at 60"          "60" "$(_compute_build_fix_budget 3 50 0)"

# Cumulative cap: used == cap → 0
export BUILD_FIX_TOTAL_TURN_CAP=100
assert_eq "T2f cap reached (used==cap)"    "0"  "$(_compute_build_fix_budget 1 20 100)"

# Cumulative cap: remaining < 8 (the 8-turn floor) → 0
assert_eq "T2g cap remaining < floor"      "0"  "$(_compute_build_fix_budget 1 20 95)"

# Cumulative cap: budget clamped down to remaining
export BUILD_FIX_TOTAL_TURN_CAP=100
assert_eq "T2h cap clamps budget to rem"   "20" "$(_compute_build_fix_budget 1 30 80)"

# =============================================================================
# Summary
# =============================================================================
echo
echo "--------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "M128 build-fix helpers tests passed"
