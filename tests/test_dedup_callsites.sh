#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_dedup_callsites.sh — M105: structural verification of dedup wiring
#
# Verifies that test_dedup_* functions exist in lib/test_dedup.sh, that the
# config default is present, that tekhton.sh sources the module, and that all
# five participating TEST_CMD call sites have both test_dedup_can_skip and
# test_dedup_record_pass wired correctly.
#
# Also documents the known gap: the fix-attempt loop re-run in
# hooks_final_checks.sh does NOT call test_dedup_record_pass after a successful
# fix (fingerprint is not updated — next check always re-runs after a fix).
# This is functionally harmless but is an explicit, tested invariant.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_PASS=0 _FAIL=0
pass() { _PASS=$((_PASS + 1)); echo "PASS: $1"; }
fail() { _FAIL=$((_FAIL + 1)); echo "FAIL: $1"; }

# =============================================================================
# Suite 1: lib/test_dedup.sh — public API surface
# =============================================================================
echo ""
echo "=== Suite 1: lib/test_dedup.sh public API ==="

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/test_dedup.sh"

if declare -f _test_dedup_fingerprint &>/dev/null; then
    pass "1.1: _test_dedup_fingerprint defined"
else
    fail "1.1: _test_dedup_fingerprint missing from lib/test_dedup.sh"
fi

if declare -f test_dedup_record_pass &>/dev/null; then
    pass "1.2: test_dedup_record_pass defined"
else
    fail "1.2: test_dedup_record_pass missing from lib/test_dedup.sh"
fi

if declare -f test_dedup_can_skip &>/dev/null; then
    pass "1.3: test_dedup_can_skip defined"
else
    fail "1.3: test_dedup_can_skip missing from lib/test_dedup.sh"
fi

if declare -f test_dedup_reset &>/dev/null; then
    pass "1.4: test_dedup_reset defined"
else
    fail "1.4: test_dedup_reset missing from lib/test_dedup.sh"
fi

# =============================================================================
# Suite 2: lib/config_defaults.sh — TEST_DEDUP_ENABLED default
# =============================================================================
echo ""
echo "=== Suite 2: config_defaults.sh — TEST_DEDUP_ENABLED ==="

if grep -q 'TEST_DEDUP_ENABLED' "${TEKHTON_HOME}/lib/config_defaults.sh"; then
    pass "2.1: TEST_DEDUP_ENABLED present in config_defaults.sh"
else
    fail "2.1: TEST_DEDUP_ENABLED missing from config_defaults.sh"
fi

if grep 'TEST_DEDUP_ENABLED' "${TEKHTON_HOME}/lib/config_defaults.sh" | grep -q 'true'; then
    pass "2.2: TEST_DEDUP_ENABLED defaults to 'true'"
else
    fail "2.2: TEST_DEDUP_ENABLED does not default to 'true' in config_defaults.sh"
fi

# =============================================================================
# Suite 3: tekhton.sh — sources lib/test_dedup.sh
# =============================================================================
echo ""
echo "=== Suite 3: tekhton.sh sources lib/test_dedup.sh ==="

if grep -q 'lib/test_dedup\.sh' "${TEKHTON_HOME}/tekhton.sh"; then
    pass "3.1: tekhton.sh sources lib/test_dedup.sh"
else
    fail "3.1: tekhton.sh does not source lib/test_dedup.sh"
fi

# =============================================================================
# Suite 4: Call site wiring — each participating file has both guards
# =============================================================================
echo ""
echo "=== Suite 4: dedup guards at each call site ==="

_check_callsite() {
    local label="$1" file="${TEKHTON_HOME}/$2"

    if grep -q 'test_dedup_can_skip' "$file"; then
        pass "${label}: test_dedup_can_skip present"
    else
        fail "${label}: test_dedup_can_skip missing"
    fi

    if grep -q 'test_dedup_record_pass' "$file"; then
        pass "${label}: test_dedup_record_pass present"
    else
        fail "${label}: test_dedup_record_pass missing"
    fi
}

_check_callsite "4.1 milestone_acceptance"  "lib/milestone_acceptance.sh"
_check_callsite "4.2 gates_completion"      "lib/gates_completion.sh"
_check_callsite "4.3 orchestrate_loop"      "lib/orchestrate_loop.sh"
_check_callsite "4.4 orchestrate_preflight" "lib/orchestrate_preflight.sh"
_check_callsite "4.5 hooks_final_checks"    "lib/hooks_final_checks.sh"
# M112: new call sites — pre-coder initial check, pre-coder fix verification,
# tester-fix retest loop.
_check_callsite "4.6 coder_prerun"          "stages/coder_prerun.sh"
_check_callsite "4.7 tester_fix"            "stages/tester_fix.sh"

# =============================================================================
# Suite 4.8: M112 — coder_prerun has BOTH paths covered
# (initial check + fix-loop verification)
# =============================================================================
echo ""
echo "=== Suite 4.8: coder_prerun has both dedup call sites (M112) ==="

prerun_file="${TEKHTON_HOME}/stages/coder_prerun.sh"
prerun_skip_count=$(grep -c 'test_dedup_can_skip' "$prerun_file" || echo "0")
prerun_record_count=$(grep -c 'test_dedup_record_pass' "$prerun_file" || echo "0")

if [[ "$prerun_skip_count" -ge 2 ]]; then
    pass "4.8.1: coder_prerun.sh has ${prerun_skip_count} can_skip calls (initial + fix-loop)"
else
    fail "4.8.1: coder_prerun.sh should have >=2 can_skip calls, found ${prerun_skip_count}"
fi

if [[ "$prerun_record_count" -ge 2 ]]; then
    pass "4.8.2: coder_prerun.sh has ${prerun_record_count} record_pass calls (initial + fix-loop)"
else
    fail "4.8.2: coder_prerun.sh should have >=2 record_pass calls, found ${prerun_record_count}"
fi

# =============================================================================
# Suite 5: orchestrate.sh — test_dedup_reset at loop entry
# =============================================================================
echo ""
echo "=== Suite 5: test_dedup_reset at loop entry ==="

if grep -q 'test_dedup_reset' "${TEKHTON_HOME}/lib/orchestrate.sh"; then
    pass "5.1: test_dedup_reset called in lib/orchestrate.sh"
else
    fail "5.1: test_dedup_reset missing from lib/orchestrate.sh"
fi

# =============================================================================
# Suite 6: Known gap — fix-loop re-run does NOT call test_dedup_record_pass
#
# After a successful fix attempt in run_final_checks, the fingerprint is not
# updated. This is intentional (functionally harmless — fix agent changes files
# so fingerprint will change anyway), and this test documents the invariant so
# any future accidental addition of record_pass in the fix loop is detected.
# =============================================================================
echo ""
echo "=== Suite 6: fix-loop gap — record_pass absent after re-run ==="

hooks_file="${TEKHTON_HOME}/lib/hooks_final_checks.sh"

# 6.1: Exactly one direct test_dedup_record_pass invocation (initial pass only, not fix loop)
# Exclude 'declare -f' guard lines — count only actual function calls.
record_count=$(grep -v 'declare -f' "$hooks_file" | grep -c 'test_dedup_record_pass' || echo "0")
if [[ "$record_count" -eq 1 ]]; then
    pass "6.1: hooks_final_checks.sh has exactly 1 test_dedup_record_pass invocation (initial pass, not fix loop)"
else
    fail "6.1: Expected 1 test_dedup_record_pass invocation in hooks_final_checks.sh, found ${record_count}"
fi

# 6.2: The single record_pass call appears BEFORE the fix-attempt loop
record_line=$(grep -n 'test_dedup_record_pass' "$hooks_file" | head -1 | cut -d: -f1)
fix_loop_line=$(grep -n 'while.*test_exit.*ne.*0' "$hooks_file" | head -1 | cut -d: -f1)

if [[ -n "$record_line" && -n "$fix_loop_line" ]]; then
    if [[ "$record_line" -lt "$fix_loop_line" ]]; then
        pass "6.2: record_pass (line ${record_line}) precedes fix loop (line ${fix_loop_line}) — gap documented"
    else
        fail "6.2: record_pass (line ${record_line}) not before fix loop (line ${fix_loop_line})"
    fi
else
    fail "6.2: Could not locate record_pass or fix loop (record=${record_line:-?}, loop=${fix_loop_line:-?})"
fi

# =============================================================================
# Suite 7: Functional — test_dedup_can_skip respects TEST_DEDUP_ENABLED flag
# =============================================================================
echo ""
echo "=== Suite 7: functional — TEST_DEDUP_ENABLED gate ==="

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export TEKHTON_DIR="${TEST_TMP}/.tekhton"
mkdir -p "$TEKHTON_DIR"

# Pre-seed a fingerprint file so can_skip has something to compare against
echo "some-fingerprint" > "${TEKHTON_DIR}/test_dedup.fingerprint"

# 7.1: With TEST_DEDUP_ENABLED=false, can_skip must always return 1 (must run)
export TEST_DEDUP_ENABLED=false
if test_dedup_can_skip; then
    fail "7.1: can_skip returned 0 when TEST_DEDUP_ENABLED=false"
else
    pass "7.1: can_skip returns must-run when TEST_DEDUP_ENABLED=false"
fi

# 7.2: With TEST_DEDUP_ENABLED=true and matching fingerprint, can_skip returns 0
# Set up a real git repo so fingerprinting works deterministically
cd "$TEST_TMP"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "seed" > seed.txt
git add seed.txt
git commit -q -m "seed"
# Pre-populate TEKHTON_DIR so git status is stable across calls
echo "placeholder" > "${TEKHTON_DIR}/placeholder"

export TEST_DEDUP_ENABLED=true
export TEST_CMD="echo ok"

test_dedup_reset
test_dedup_record_pass

if test_dedup_can_skip; then
    pass "7.2: can_skip returns 0 (skip) when fingerprint matches and ENABLED=true"
else
    fail "7.2: can_skip returned must-run despite matching fingerprint and ENABLED=true"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Summary ==="
echo "Passed: ${_PASS}, Failed: ${_FAIL}"
if [[ "$_FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
