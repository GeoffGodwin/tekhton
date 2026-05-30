#!/usr/bin/env bash
# TIMEOUT_SECS=90
# tests/test_run_tests_files_override.sh — focused-test override contract.
#
# run_tests.sh accepts positional args naming test files. When passed, only
# those tests run instead of the default tests/test_*.sh glob. Used by the
# test-fix loop in lib/hooks_final_checks.sh to focus on just the tests
# that failed. The previous TEST_FILES env-var design leaked across
# subprocess boundaries (#41 v2 diagnosis: stagerunner-spawned coder
# inherited TEST_FILES via env, causing the pre-run check to run only one
# test) so the contract is now ARGV ONLY — run_tests.sh explicitly unsets
# TEST_FILES at startup.
set -euo pipefail

_src="${BASH_SOURCE[0]}"
TEKHTON_HOME="$(cd "$(dirname "$_src")/.." && pwd)"
RUNNER="$TEKHTON_HOME/tests/run_tests.sh"
PASS_COUNT=0
FAIL_COUNT=0

# The contract being verified is purely shell-level (positional-args override
# of the default test glob). Inner invocations of run_tests.sh below don't
# need Python or Go tests; running them would add ~40s of cold-cache `go test`
# per invocation × 4 invocations, blowing the test's 90s timeout. Skip them.
export TEKHTON_RUN_TESTS_SHELL_ONLY=1

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== Test 1: positional arg scopes run to named test ==="
_out1=$(bash "$RUNNER" test_dedup.sh 2>&1) || true
if echo "$_out1" | grep -qE "PASS.*test_dedup\.sh"; then
    pass "1.1: test_dedup.sh runs when passed as positional arg"
else
    fail "1.1: expected PASS test_dedup.sh in output"
fi

echo "=== Test 2: positional with unknown file ==="
_exit2=0
_out2=$(bash "$RUNNER" test_nonexistent_xyzzy_9.sh 2>&1) || _exit2=$?
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

echo "=== Test 3: no args falls through to default glob ==="
# DO NOT exec run_tests.sh without args here — that would run the full
# suite, which includes this very test, which would exec another full
# suite, recursing until the 90s timeout fires. Static-check the
# conditional branch instead.
if grep -q 'if \[\[ "\$#" -gt 0 \]\]' "$TEKHTON_HOME/tests/run_tests.sh"; then
    pass "3.1: run_tests.sh gates positional override behind \$# -gt 0"
else
    fail "3.1: positional-args override branch not found in run_tests.sh"
fi

echo "=== Test 4: multiple positional args ==="
_out4=$(bash "$RUNNER" test_dedup.sh test_milestone_dag.sh 2>&1) || true
_d=0; _m=0
if echo "$_out4" | grep -qE "(PASS|FAIL).*test_dedup\.sh"; then _d=1; fi
if echo "$_out4" | grep -qE "(PASS|FAIL).*test_milestone_dag\.sh"; then _m=1; fi
if [ "$_d" -eq 1 ] && [ "$_m" -eq 1 ]; then
    pass "4.1: both specified tests appear in output"
else
    fail "4.1: expected both tests; dedup=$_d milestone=$_m"
fi
if echo "$_out4" | grep -qE "(PASS|FAIL).*test_hooks_commit_message\.sh"; then
    fail "4.2: test_hooks_commit_message.sh ran despite not being a positional arg"
else
    pass "4.2: tests outside positional args did not run"
fi

echo "=== Test 5: TEST_FILES env is wiped at startup (#41 v2 anti-leak) ==="
# Inherited TEST_FILES used to cause coder's pre-run check to run only one
# test, tripping false-positive pre-run-fix loops. run_tests.sh now unsets
# TEST_FILES alongside its other parent-env config wipes. Verify the
# startup unset block contains TEST_FILES.
# Multi-line unset block — `unset A \` followed by continuation lines
# containing TEST_FILES. Join with awk so a single grep can match.
if awk '/^unset / {flag=1} flag {buf=buf" "$0} /[^\\]$/ && flag {print buf; flag=0; buf=""}' \
    "$TEKHTON_HOME/tests/run_tests.sh" 2>/dev/null \
    | grep -qE 'unset\b.*\bTEST_FILES\b'; then
    pass "5.1: run_tests.sh unsets inherited TEST_FILES at startup"
else
    fail "5.1: TEST_FILES not in the startup unset block — env leak would recur"
fi
# And functionally — setting TEST_FILES in env should NOT scope the run
# (positional args are the only way to scope).
_out5=$(TEST_FILES="test_dedup.sh" bash "$RUNNER" test_milestone_dag.sh 2>&1) || true
if echo "$_out5" | grep -qE "(PASS|FAIL).*test_milestone_dag\.sh"; then
    pass "5.2: positional arg honored when TEST_FILES env is also set"
else
    fail "5.2: positional arg ignored — TEST_FILES env shadowed it"
fi

echo ""
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
