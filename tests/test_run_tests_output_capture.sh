#!/usr/bin/env bash
# tests/test_run_tests_output_capture.sh
#
# Comprehensive test for the single-invocation fix to run_test().
# Verifies: output capture, exit codes, stdin isolation, complex output handling.

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${TEKHTON_HOME}/tests/run_tests.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Extract run_test() function from runner
fn_src=$(awk '/^run_test\(\) \{/,/^}/' "$RUNNER")
if [ -z "$fn_src" ]; then
    echo "FAIL: could not extract run_test() from $RUNNER"
    exit 1
fi

# Provide globals that run_test() depends on
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

# Test 1: Multiline output is captured correctly
cat > "$tmpdir/test_multiline_output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "line 1"
echo "line 2"
echo "line 3"
exit 1
EOF
chmod +x "$tmpdir/test_multiline_output.sh"

output=$(run_test "test_multiline_output.sh" 2>&1)
if echo "$output" | grep -q "line 1" && echo "$output" | grep -q "line 2" && echo "$output" | grep -q "line 3"; then
    pass "multiline output captured in single invocation"
else
    fail "multiline output not fully captured; got: $output"
fi

# Test 2: Stderr is captured alongside stdout
cat > "$tmpdir/test_mixed_output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stdout message" >&1
echo "stderr message" >&2
exit 1
EOF
chmod +x "$tmpdir/test_mixed_output.sh"

output=$(run_test "test_mixed_output.sh" 2>&1)
if echo "$output" | grep -q "stdout message" && echo "$output" | grep -q "stderr message"; then
    pass "stdout and stderr both captured"
else
    fail "mixed stdout/stderr not captured; got: $output"
fi

# Test 3: Exit code of 0 produces PASS, exit code of 1 produces FAIL
cat > "$tmpdir/test_exit_zero.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpdir/test_exit_zero.sh"

output=$(run_test "test_exit_zero.sh" 2>&1)
if echo "$output" | grep -q "PASS"; then
    pass "exit code 0 produces PASS"
else
    fail "exit code 0 did not produce PASS; got: $output"
fi

# Test 4: Various non-zero exit codes all produce FAIL
for exit_code in 1 2 5 127; do
    cat > "$tmpdir/test_exit_nonzero_${exit_code}.sh" <<EOF
#!/usr/bin/env bash
exit $exit_code
EOF
    chmod +x "$tmpdir/test_exit_nonzero_${exit_code}.sh"

    output=$(run_test "test_exit_nonzero_${exit_code}.sh" 2>&1)
    if echo "$output" | grep -q "FAIL"; then
        pass "exit code $exit_code produces FAIL"
    else
        fail "exit code $exit_code did not produce FAIL; got: $output"
    fi
done

# Test 5: stdin is isolated (via < /dev/null)
# A test that tries to read from stdin should not hang or inherit parent's stdin
cat > "$tmpdir/test_stdin_isolated.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Try to read a line from stdin with timeout
if timeout 1 read -t 1 line < /dev/stdin 2>/dev/null; then
    # If read succeeds, fail the test
    exit 1
fi
# If read fails/times out, the test passes (stdin is isolated)
exit 0
EOF
chmod +x "$tmpdir/test_stdin_isolated.sh"

output=$(run_test "test_stdin_isolated.sh" 2>&1)
if echo "$output" | grep -q "PASS"; then
    pass "stdin isolation via < /dev/null works"
else
    fail "stdin was not properly isolated; got: $output"
fi

# Test 6: Output with special characters is preserved
cat > "$tmpdir/test_special_chars.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "special: \$var \`backticks\` 'quotes' \"double\" &ampersand"
exit 1
EOF
chmod +x "$tmpdir/test_special_chars.sh"

output=$(run_test "test_special_chars.sh" 2>&1)
if echo "$output" | grep -q 'special:' && echo "$output" | grep -q 'backticks'; then
    pass "special characters in output preserved"
else
    fail "special characters not preserved; got: $output"
fi

# Test 7: A test that produces empty output on failure still shows FAIL
cat > "$tmpdir/test_silent_failure.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
chmod +x "$tmpdir/test_silent_failure.sh"

output=$(run_test "test_silent_failure.sh" 2>&1)
if echo "$output" | grep -q "FAIL"; then
    pass "silent failure (no output) still reports FAIL"
else
    fail "silent failure did not report FAIL; got: $output"
fi

# Test 8: Verify that FAILED_TESTS array is populated on failure
FAILED_TESTS=()
run_test "test_silent_failure.sh" > /dev/null 2>&1 || true
found=0
for item in "${FAILED_TESTS[@]}"; do
    if [ "$item" = "test_silent_failure.sh" ]; then
        found=1
        break
    fi
done
if [ "$found" -eq 1 ]; then
    pass "FAILED_TESTS array populated on failure"
else
    fail "FAILED_TESTS array not updated; got: $(printf '%s ' "${FAILED_TESTS[@]}")"
fi

# Test 9: Verify PASS and FAIL counters are updated correctly
initial_pass=$PASS
initial_fail=$FAIL

run_test "test_exit_zero.sh" > /dev/null 2>&1 || true
if [ "$PASS" -gt "$initial_pass" ]; then
    pass "PASS counter incremented on passing test"
else
    fail "PASS counter not incremented"
fi

initial_fail=$FAIL
run_test "test_silent_failure.sh" > /dev/null 2>&1 || true
if [ "$FAIL" -gt "$initial_fail" ]; then
    pass "FAIL counter incremented on failing test"
else
    fail "FAIL counter not incremented"
fi

echo
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
