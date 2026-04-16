#!/usr/bin/env bash
# tests/test_run_tests_single_invocation.sh
#
# Regression: tests/run_tests.sh run_test() must capture output and exit code
# from a SINGLE bash invocation. The previous implementation invoked the test
# twice — once silently to determine PASS/FAIL, then again to capture output
# for the debug section. That re-run could produce divergent results when the
# first run aborted under `set -euo pipefail` (e.g. SIGPIPE inside `$()`,
# bare grep with no match) but the second run started clean — yielding
# misleading "FAIL ... output: all PASS" reports.

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${TEKHTON_HOME}/tests/run_tests.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Stateful fixture: increments a counter file each invocation, prints
# INVOCATION_<n>, exits 1 on first run and 0 on subsequent runs. Lets us
# distinguish a single-run capture from a double-run capture.
counter="${tmpdir}/counter"
cat > "$tmpdir/test_stateful_failure.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
counter="${counter}"
n=\$(cat "\$counter" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "\$counter"
echo "INVOCATION_\$n"
if [ "\$n" -ge 2 ]; then
    exit 0
fi
exit 1
EOF
chmod +x "$tmpdir/test_stateful_failure.sh"

# Extract just the run_test() function from the runner so we can call it in
# isolation without triggering the auto-discovery loop or python test phase.
fn_src=$(awk '/^run_test\(\) \{/,/^}/' "$RUNNER")
if [ -z "$fn_src" ]; then
    echo "FAIL: could not extract run_test() from $RUNNER"
    exit 1
fi

# Provide the globals run_test() depends on. Referenced inside the eval'd
# function body, which shellcheck cannot see through.
# shellcheck disable=SC2034
RED=''
# shellcheck disable=SC2034
GREEN=''
# shellcheck disable=SC2034
NC=''
# shellcheck disable=SC2034
PASS=0
# shellcheck disable=SC2034
FAIL=0
# shellcheck disable=SC2034
FAILED_TESTS=()
# shellcheck disable=SC2034
TESTS_DIR="$tmpdir"

eval "$fn_src"

output=$(run_test "test_stateful_failure.sh" 2>&1)
invocations=$(cat "$counter" 2>/dev/null || echo 0)

if echo "$output" | grep -q "FAIL"; then
    pass "FAIL marker reported for failing fixture"
else
    fail "expected FAIL marker; got: $output"
fi

if echo "$output" | grep -q "INVOCATION_1"; then
    pass "debug section contains output from the run that produced the non-zero exit"
else
    fail "expected INVOCATION_1 in debug section; got: $output"
fi

if echo "$output" | grep -q "INVOCATION_2"; then
    fail "test was re-invoked — debug should not contain INVOCATION_2; got: $output"
else
    pass "test was not re-invoked for debug capture"
fi

if [ "$invocations" = "1" ]; then
    pass "test fixture was executed exactly once (counter=$invocations)"
else
    fail "test fixture was executed $invocations times, expected 1"
fi

# Sanity check: a passing fixture should still report PASS in a single run.
cat > "$tmpdir/test_passing_fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "ok"
exit 0
EOF
chmod +x "$tmpdir/test_passing_fixture.sh"

output=$(run_test "test_passing_fixture.sh" 2>&1)

if echo "$output" | grep -q "PASS"; then
    pass "passing fixture reported PASS"
else
    fail "expected PASS marker for passing fixture; got: $output"
fi

if echo "$output" | grep -q "FAIL"; then
    fail "passing fixture should not produce FAIL marker; got: $output"
else
    pass "passing fixture did not produce FAIL marker"
fi

echo
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
