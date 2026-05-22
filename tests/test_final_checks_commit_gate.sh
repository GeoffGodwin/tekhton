#!/usr/bin/env bash
# TIMEOUT_SECS=30
# =============================================================================
# test_final_checks_commit_gate.sh — gate on .final_check_result sentinel
#
# Covers task #46: _hook_commit must refuse to run when _hook_final_checks
# recorded a failure in .tekhton/.final_check_result, AND must proceed
# normally when the sentinel records success (or is absent).
#
# Each finalize hook runs in its own bash subprocess under the Go orchestrator
# shim, so the in-memory FINAL_CHECK_RESULT set by _hook_final_checks doesn't
# survive to _hook_commit. The sentinel file is the bridge between them.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Source only what's needed to expose _final_check_result_read without
# pulling in the whole finalize stack (which expects a real project tree).
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_commit.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TEKHTON_DIR="$TMP/.tekhton"
mkdir -p "$TEKHTON_DIR"

echo "=== _final_check_result_read: sentinel absent → 0 ==="
result=$(_final_check_result_read)
if [[ "$result" == "0" ]]; then
    pass "1.1: absent sentinel returns 0"
else
    fail "1.1: absent sentinel returned '$result' (want 0)"
fi

echo "=== _final_check_result_read: sentinel says 0 → 0 ==="
echo "0" > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "0" ]]; then
    pass "2.1: zero sentinel returns 0"
else
    fail "2.1: zero sentinel returned '$result'"
fi

echo "=== _final_check_result_read: sentinel says non-zero → non-zero ==="
echo "1" > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "1" ]]; then
    pass "3.1: failure sentinel returns 1"
else
    fail "3.1: failure sentinel returned '$result' (want 1)"
fi

echo "=== _final_check_result_read: handles trailing whitespace ==="
printf '2\n  \n' > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "2" ]]; then
    pass "4.1: whitespace-around value parsed correctly"
else
    fail "4.1: got '$result' (want 2)"
fi

echo "=== _final_check_result_read: empty file → 0 ==="
: > "$TEKHTON_DIR/.final_check_result"
result=$(_final_check_result_read)
if [[ "$result" == "0" ]]; then
    pass "5.1: empty sentinel returns 0 (defensive default)"
else
    fail "5.1: empty sentinel returned '$result'"
fi

# Source finalize_core_hooks for _hook_final_checks gate behavior. Stub
# run_final_checks so the test doesn't actually invoke TEST_CMD.
# shellcheck source=/dev/null
source "$TEKHTON_HOME/lib/finalize_core_hooks.sh"

echo "=== _hook_final_checks: failure writes sentinel ==="
run_final_checks() { return 7; }  # fake failure
rm -f "$TEKHTON_DIR/.final_check_result"
SKIP_FINAL_CHECKS=false _PREFLIGHT_TESTS_PASSED=false \
    _hook_final_checks 0 >/dev/null 2>&1 || true
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    val=$(tr -d '[:space:]' < "$TEKHTON_DIR/.final_check_result")
    if [[ "$val" == "7" ]]; then
        pass "6.1: failure persists exit code (7) to sentinel"
    else
        fail "6.1: sentinel contains '$val' (want 7)"
    fi
else
    fail "6.1: sentinel file not created on failure"
fi

echo "=== _hook_final_checks: success leaves sentinel absent ==="
run_final_checks() { return 0; }  # fake success
rm -f "$TEKHTON_DIR/.final_check_result"
SKIP_FINAL_CHECKS=false _PREFLIGHT_TESTS_PASSED=false \
    _hook_final_checks 0 >/dev/null 2>&1 || true
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    val=$(tr -d '[:space:]' < "$TEKHTON_DIR/.final_check_result")
    fail "7.1: sentinel file exists on success (contains '$val'); should be absent"
else
    pass "7.1: sentinel absent after a clean run"
fi

echo "=== _hook_final_checks: SKIP_FINAL_CHECKS=true records 1 ==="
# SKIP path treats the skipped check as a failure so the commit gate still trips
rm -f "$TEKHTON_DIR/.final_check_result"
SKIP_FINAL_CHECKS=true _hook_final_checks 0 >/dev/null 2>&1 || true
if [[ -f "$TEKHTON_DIR/.final_check_result" ]]; then
    pass "8.1: SKIP_FINAL_CHECKS writes failure sentinel (commit gate trips)"
else
    fail "8.1: SKIP_FINAL_CHECKS should still write a failure sentinel"
fi

# Integration: _hook_commit reads the sentinel and blocks when non-zero.
# Use a flag FILE (not a variable) to detect git invocations from the
# subshell created by $() — variable writes in a subshell don't propagate
# back to the parent, but file-system changes do.
_GIT_FLAG="$TEKHTON_DIR/.git_called_flag"
git() { touch "$_GIT_FLAG"; return 0; }

echo "=== _hook_commit: persisted sentinel blocks commit ==="
rm -f "$_GIT_FLAG"
echo "1" > "$TEKHTON_DIR/.final_check_result"
unset FINAL_CHECK_RESULT
output=$(_hook_commit 0 2>&1) || true
if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "9.1: git not called when persisted sentinel records failure"
else
    fail "9.1: git was called despite persisted failure sentinel"
fi
if echo "$output" | grep -q "Commit blocked"; then
    pass "9.2: 'Commit blocked' warning emitted"
else
    fail "9.2: expected 'Commit blocked' in output, got: $output"
fi

echo "=== _hook_commit: in-memory FINAL_CHECK_RESULT blocks commit ==="
rm -f "$_GIT_FLAG"
rm -f "$TEKHTON_DIR/.final_check_result"
output=$(FINAL_CHECK_RESULT=1 _hook_commit 0 2>&1) || true
if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "10.1: git not called when in-memory FINAL_CHECK_RESULT is non-zero"
else
    fail "10.1: git was called despite FINAL_CHECK_RESULT=1"
fi
if echo "$output" | grep -q "Commit blocked"; then
    pass "10.2: 'Commit blocked' warning emitted for in-memory path"
else
    fail "10.2: expected 'Commit blocked' in output, got: $output"
fi

echo "=== _hook_commit: non-zero exit_code bypasses commit silently ==="
rm -f "$_GIT_FLAG"
rm -f "$TEKHTON_DIR/.final_check_result"
unset FINAL_CHECK_RESULT
_hook_commit 1 >/dev/null 2>&1 || true
if [[ ! -f "$_GIT_FLAG" ]]; then
    pass "11.1: git not called when exit_code is non-zero (expected early return)"
else
    fail "11.1: git was called for non-zero exit_code"
fi

echo ""
echo "=== Summary ==="
echo "Passed: $PASS, Failed: $FAIL"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
