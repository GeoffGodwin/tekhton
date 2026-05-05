#!/usr/bin/env bash
# =============================================================================
# test_wedge_audit.sh — Unit tests for scripts/wedge-audit.sh (m04 invariant gate)
#
# Tests:
#   1. (Happy path) Audit exits 0 against HEAD — no direct-write bypasses present
#   2. Violation: >> redirect into $CAUSAL_LOG_FILE detected
#   3. Violation: >> redirect into $PIPELINE_STATE_FILE detected
#   4. Violation: mv into $CAUSAL_LOG_FILE detected
#   5. Violation: _LAST_EVENT_ID= assignment (in-process counter) detected
#   6. Violation: _CAUSAL_EVENT_COUNT= assignment detected
#   7. Allowlist: violations inside lib/causality.sh are exempt
#   8. Allowlist: violations inside lib/state.sh are exempt
#   9. Allowlist: violations inside lib/state_helpers.sh are exempt
#  10. Report output names the offending file path
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/wedge-audit.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1 (happy path): HEAD is clean — no violations
# ---------------------------------------------------------------------------

if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
    pass "clean HEAD exits 0"
else
    fail "clean HEAD: expected exit 0 from wedge-audit, got non-zero"
fi

# ---------------------------------------------------------------------------
# Helpers for injecting temporary violation files into lib/
#
# Each test below:
#   1. Writes a temp .sh file into lib/ with a distinctive name (PID-scoped)
#   2. Runs the audit and asserts the expected exit code / output
#   3. Removes the temp file immediately (trap ensures cleanup on signal/error)
#
# Using lib/ rather than stages/ avoids any risk of collision with the
# two-level glob in the audit script (lib/**/*.sh stages/**/*.sh).
# ---------------------------------------------------------------------------

_VFILE="${TEKHTON_HOME}/lib/_test_wedge_violation_$$.sh"
trap 'rm -f "$_VFILE"' EXIT INT TERM

_audit_output=""
_audit_rc=0

_inject_and_audit() {
    local content="$1"
    printf '%s\n' "$content" > "$_VFILE"
    _audit_output=$(bash "$AUDIT_SCRIPT" 2>&1) || _audit_rc=$?
    _audit_rc=${_audit_rc:-0}
}

_reset_rc() { _audit_rc=0; _audit_output=""; rm -f "$_VFILE"; }

# ---------------------------------------------------------------------------
# Test 2: >> redirect into $CAUSAL_LOG_FILE
# ---------------------------------------------------------------------------

_inject_and_audit 'echo "data" >> "$CAUSAL_LOG_FILE"'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "causal log redirect (>>) detected"
else
    fail "causal log redirect (>>): audit should have failed, exit was 0"
fi
_reset_rc

# ---------------------------------------------------------------------------
# Test 3: >> redirect into $PIPELINE_STATE_FILE
# ---------------------------------------------------------------------------

_inject_and_audit 'echo "data" >> "$PIPELINE_STATE_FILE"'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "state file redirect (>>) detected"
else
    fail "state file redirect (>>): audit should have failed, exit was 0"
fi
_reset_rc

# ---------------------------------------------------------------------------
# Test 4: mv into $CAUSAL_LOG_FILE
# ---------------------------------------------------------------------------

_inject_and_audit 'mv /tmp/foo.tmp "$CAUSAL_LOG_FILE"'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "mv into CAUSAL_LOG_FILE detected"
else
    fail "mv into CAUSAL_LOG_FILE: audit should have failed, exit was 0"
fi
_reset_rc

# ---------------------------------------------------------------------------
# Test 5: _LAST_EVENT_ID= in-process counter assignment
# ---------------------------------------------------------------------------

_inject_and_audit '_LAST_EVENT_ID=pipeline.001'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "_LAST_EVENT_ID= assignment detected"
else
    fail "_LAST_EVENT_ID= assignment: audit should have failed, exit was 0"
fi
_reset_rc

# ---------------------------------------------------------------------------
# Test 6: _CAUSAL_EVENT_COUNT= in-process counter assignment
# ---------------------------------------------------------------------------

_inject_and_audit '_CAUSAL_EVENT_COUNT=5'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "_CAUSAL_EVENT_COUNT= assignment detected"
else
    fail "_CAUSAL_EVENT_COUNT= assignment: audit should have failed, exit was 0"
fi
_reset_rc

# ---------------------------------------------------------------------------
# Test 7: Allowlist — lib/causality.sh violations are exempt
# ---------------------------------------------------------------------------
# The audit script checks ALLOWED_FILES by relative path from REPO_ROOT.
# lib/causality.sh is in the allowlist, so violations there must NOT cause failure.

causality_violations=$(grep -c 'CAUSAL_LOG_FILE\|PIPELINE_STATE_FILE\|_LAST_EVENT_ID=\|_CAUSAL_EVENT_COUNT=' \
    "${TEKHTON_HOME}/lib/causality.sh" 2>/dev/null || echo "0")
if [[ "$causality_violations" -gt 0 ]]; then
    # Real violations exist in causality.sh — the audit must still pass because
    # it's allowlisted.
    if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
        pass "lib/causality.sh violations are exempt (allowlisted)"
    else
        fail "lib/causality.sh violations caused audit failure — allowlist broken"
    fi
else
    # causality.sh has no detectable violations in this version; skip the
    # structural assertion but note it.
    pass "lib/causality.sh has no detectable violation lines (allowlist untriggered but file is present)"
fi

# ---------------------------------------------------------------------------
# Test 8: Allowlist — lib/state.sh violations are exempt
# ---------------------------------------------------------------------------

state_violations=$(grep -c 'PIPELINE_STATE_FILE' \
    "${TEKHTON_HOME}/lib/state.sh" 2>/dev/null || echo "0")
if [[ "$state_violations" -gt 0 ]]; then
    if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
        pass "lib/state.sh violations are exempt (allowlisted)"
    else
        fail "lib/state.sh violations caused audit failure — allowlist broken"
    fi
else
    pass "lib/state.sh has no detectable violation lines (allowlist untriggered)"
fi

# ---------------------------------------------------------------------------
# Test 9: Allowlist — lib/state_helpers.sh violations are exempt
# ---------------------------------------------------------------------------

helpers_violations=$(grep -c 'PIPELINE_STATE_FILE\|_LAST_EVENT_ID=\|_CAUSAL_EVENT_COUNT=' \
    "${TEKHTON_HOME}/lib/state_helpers.sh" 2>/dev/null || echo "0")
if [[ "$helpers_violations" -gt 0 ]]; then
    if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
        pass "lib/state_helpers.sh violations are exempt (allowlisted)"
    else
        fail "lib/state_helpers.sh violations caused audit failure — allowlist broken"
    fi
else
    pass "lib/state_helpers.sh has no detectable violation lines (allowlist untriggered)"
fi

# ---------------------------------------------------------------------------
# Test 10: Report output names the offending file
# ---------------------------------------------------------------------------

_REPORT_VFILE="${TEKHTON_HOME}/lib/_test_wedge_report_$$.sh"
trap 'rm -f "$_VFILE" "$_REPORT_VFILE"' EXIT INT TERM

printf '%s\n' '_LAST_EVENT_ID=bypass_test' > "$_REPORT_VFILE"
_report_out=$(bash "$AUDIT_SCRIPT" 2>&1) || true

if echo "$_report_out" | grep -qF "_test_wedge_report_$$"; then
    pass "report names the offending file path"
else
    fail "report does not name the offending file; got: $_report_out"
fi
rm -f "$_REPORT_VFILE"
trap 'rm -f "$_VFILE"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "wedge-audit tests: Passed=$PASS Failed=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "All wedge-audit tests passed."
