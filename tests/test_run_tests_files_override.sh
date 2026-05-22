#!/usr/bin/env bash
# TIMEOUT_SECS=90
# tests/test_run_tests_files_override.sh
set -euo pipefail

_src="${BASH_SOURCE[0]}"
TEKHTON_HOME="$(cd "$(dirname "$_src")/.." && pwd)"
RUNNER="$TEKHTON_HOME/tests/run_tests.sh"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== Test 1: TEST_FILES scopes run to named test ==="
_out1=$(TEST_FILES="test_dedup.sh" bash "$RUNNER" 2>&1) || true
if echo "$_out1" | grep -qE "PASS.*test_dedup\.sh"; then
    pass "1.1: test_dedup.sh runs with TEST_FILES=test_dedup.sh"
else
    fail "1.1: expected PASS test_dedup.sh in output"
fi

echo "=== Test 2: TEST_FILES with unknown file ==="
_exit2=0
_out2=$(TEST_FILES="test_nonexistent_xyzzy_9.sh" bash "$RUNNER" 2>&1) || _exit2=$?
if echo "$_out2" | grep -q "MISSING"; then
    pass "2.1: unknown file name prints MISSING"
else
    fail "2.1: expected MISSING in output"
fi
if [ "$_exit2" -ne 0 ]; then
    pass "2.2: unknown file causes non-zero exit"
else
    fail "2.2: expected non-zero exit for unknown file"
fi

echo "=== Test 3: empty TEST_FILES runs full suite ==="
_out3=$(TEST_FILES="" bash "$RUNNER" 2>&1) || true
_fd=0; _fm=0
if echo "$_out3" | grep -qE "(PASS|FAIL).*test_dedup\.sh"; then _fd=1; fi
if echo "$_out3" | grep -qE "(PASS|FAIL).*test_milestone_dag\.sh"; then _fm=1; fi
if [ "$_fd" -eq 1 ] && [ "$_fm" -eq 1 ]; then
    pass "3.1: full suite runs with empty TEST_FILES"
else
    fail "3.1: expected multiple tests; dedup=$_fd milestone=$_fm"
fi

echo "=== Test 4: TEST_FILES with multiple tests ==="
_out4=$(TEST_FILES="test_dedup.sh test_milestone_dag.sh" bash "$RUNNER" 2>&1) || true
_d=0; _m=0
if echo "$_out4" | grep -qE "(PASS|FAIL).*test_dedup\.sh"; then _d=1; fi
if echo "$_out4" | grep -qE "(PASS|FAIL).*test_milestone_dag\.sh"; then _m=1; fi
if [ "$_d" -eq 1 ] && [ "$_m" -eq 1 ]; then
    pass "4.1: both specified tests appear in output"
else
    fail "4.1: expected both tests; dedup=$_d milestone=$_m"
fi
if echo "$_out4" | grep -qE "(PASS|FAIL).*test_hooks_commit_message\.sh"; then
    fail "4.2: test_hooks_commit_message.sh ran despite not being in TEST_FILES"
else
    pass "4.2: tests outside TEST_FILES did not run"
fi

echo ""
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
