#!/usr/bin/env bash
# =============================================================================
# test_ui_build_gate.sh — Unit tests for UI test gate in run_build_gate() (M28)
#
# Tests:
#   1.  Gate skipped when UI_TEST_CMD is empty
#   2.  Gate skipped when UI_VALIDATION_ENABLED=false
#   3.  Gate warns and skips when custom binary is not found (not npx/npm)
#   4.  Gate passes when UI_TEST_CMD exits 0
#   5.  Gate fails (returns 1) after retry when UI_TEST_CMD always exits non-zero
#   6.  Gate writes UI_TEST_ERRORS.md on failure
#   7.  UI_TEST_ERRORS.md contains stage label and command
#   8.  Gate retries exactly once: passes if retry succeeds
#   9.  Gate does NOT check availability for npx commands (runtime resolution)
#  10.  Gate does NOT check availability for npm commands (runtime resolution)
#  11.  Gate passes and removes BUILD_ERRORS.md on overall success
#  12.  UI_TEST_ERRORS.md is not written on gate pass
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"

PROJECT_DIR="$TMPDIR"

# --- Minimal pipeline environment ---
source "${TEKHTON_HOME}/lib/common.sh"

# ANALYZE_CMD always passes; no compile check; no constraints; no UI by default
ANALYZE_CMD="echo ok"
ANALYZE_ERROR_PATTERN="NEVER_MATCH_THIS_STRING"
BUILD_CHECK_CMD=""
BUILD_ERROR_PATTERN="ERROR"
DEPENDENCY_CONSTRAINTS_FILE=""
UI_TEST_CMD=""
UI_VALIDATION_ENABLED="true"
UI_TEST_TIMEOUT="10"

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns_remediation.sh"
source "${TEKHTON_HOME}/lib/gates.sh"
source "${TEKHTON_HOME}/lib/gates_phases.sh"
source "${TEKHTON_HOME}/lib/gates_ui.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

assert_file_exists() {
    local name="$1" file="$2"
    if [ -f "$file" ]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — file '$file' should exist"
        FAIL=1
    fi
}

assert_file_not_exists() {
    local name="$1" file="$2"
    if [ ! -f "$file" ]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — file '$file' should NOT exist"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        FAIL=1
    fi
}

# Helper to run gate and capture exit code without set -e aborting
run_gate() {
    local label="$1"
    local _exit=0
    run_build_gate "$label" > /dev/null 2>&1 || _exit=$?
    echo "$_exit"
}

# =============================================================================
# Test 1: Gate skipped when UI_TEST_CMD is empty
# =============================================================================
UI_TEST_CMD=""
UI_VALIDATION_ENABLED="true"
gate_exit=$(run_gate "test-empty-cmd")
assert_eq "1 gate passes when UI_TEST_CMD empty" "0" "$gate_exit"
assert_file_not_exists "1 no UI_TEST_ERRORS.md when cmd empty" "UI_TEST_ERRORS.md"

# =============================================================================
# Test 2: Gate skipped when UI_VALIDATION_ENABLED=false
# =============================================================================

# Write a failing UI test script
cat > "$TMPDIR/fail_always.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "UI test failure output"
exit 1
SCRIPT
chmod +x "$TMPDIR/fail_always.sh"

UI_TEST_CMD="$TMPDIR/fail_always.sh"
UI_VALIDATION_ENABLED="false"
gate_exit=$(run_gate "test-disabled")
assert_eq "2 gate passes when UI_VALIDATION_ENABLED=false" "0" "$gate_exit"
assert_file_not_exists "2 no UI_TEST_ERRORS.md when disabled" "UI_TEST_ERRORS.md"

# Reset
UI_VALIDATION_ENABLED="true"

# =============================================================================
# Test 3: Gate warns and skips when custom binary not found
# =============================================================================
UI_TEST_CMD="nonexistent_test_runner_xyz_abc --run"
UI_VALIDATION_ENABLED="true"

gate_exit=$(run_gate "test-missing-binary")
assert_eq "3 gate passes when binary not found (soft failure)" "0" "$gate_exit"
assert_file_not_exists "3 no UI_TEST_ERRORS.md when binary missing" "UI_TEST_ERRORS.md"

# =============================================================================
# Test 4: Gate passes when UI_TEST_CMD exits 0
# =============================================================================

cat > "$TMPDIR/pass_always.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "All UI tests passed"
exit 0
SCRIPT
chmod +x "$TMPDIR/pass_always.sh"

UI_TEST_CMD="$TMPDIR/pass_always.sh"
rm -f UI_TEST_ERRORS.md

gate_exit=$(run_gate "test-passing-ui")
assert_eq "4 gate passes when UI test exits 0" "0" "$gate_exit"
assert_file_not_exists "4 no UI_TEST_ERRORS.md on pass" "UI_TEST_ERRORS.md"

# =============================================================================
# Test 5: Gate fails after retry when command always exits non-zero
# =============================================================================
UI_TEST_CMD="$TMPDIR/fail_always.sh"
rm -f UI_TEST_ERRORS.md

gate_exit=$(run_gate "test-always-fail")
assert_eq "5 gate fails when UI test always exits non-zero" "1" "$gate_exit"

# =============================================================================
# Test 6: UI_TEST_ERRORS.md written on failure
# =============================================================================
# Already failed from test 5 — UI_TEST_ERRORS.md should exist
assert_file_exists "6 UI_TEST_ERRORS.md written on failure" "UI_TEST_ERRORS.md"
rm -f UI_TEST_ERRORS.md

# =============================================================================
# Test 7: UI_TEST_ERRORS.md contains stage label and command
# =============================================================================
UI_TEST_CMD="$TMPDIR/fail_always.sh"
run_build_gate "test-error-content" > /dev/null 2>&1 || true
assert_file_contains "7 UI_TEST_ERRORS.md has stage label" "UI_TEST_ERRORS.md" "test-error-content"
assert_file_contains "7 UI_TEST_ERRORS.md has command reference" "UI_TEST_ERRORS.md" "fail_always"
rm -f UI_TEST_ERRORS.md

# =============================================================================
# Test 8: Gate passes if retry succeeds (first fail, retry pass)
# =============================================================================

# Create a script that fails once then passes on retry
# Use a state file in the temp directory to track invocation count
RETRY_STATE="$TMPDIR/retry_count.txt"
echo "0" > "$RETRY_STATE"

cat > "$TMPDIR/fail_then_pass.sh" << SCRIPT
#!/usr/bin/env bash
COUNT=\$(cat "${RETRY_STATE}")
NEW_COUNT=\$((COUNT + 1))
echo "\$NEW_COUNT" > "${RETRY_STATE}"
if [ "\$COUNT" -eq 0 ]; then
    echo "First run: failing"
    exit 1
else
    echo "Retry: passing"
    exit 0
fi
SCRIPT
chmod +x "$TMPDIR/fail_then_pass.sh"

UI_TEST_CMD="$TMPDIR/fail_then_pass.sh"
rm -f UI_TEST_ERRORS.md

gate_exit=$(run_gate "test-retry-pass")
assert_eq "8 gate passes when retry succeeds" "0" "$gate_exit"
assert_file_not_exists "8 no UI_TEST_ERRORS.md when retry succeeds" "UI_TEST_ERRORS.md"

# =============================================================================
# Test 9: npx commands are not checked for binary availability
# =============================================================================
# Use a command that starts with "npx" — even if playwright isn't installed,
# the gate should attempt to run it (not skip with warning).
# We mock npx as a passthrough stub.

# Override 'timeout' behavior for this test: use a mock npx that exits 0
NPX_MOCK="$TMPDIR/npx_mock.sh"
cat > "$NPX_MOCK" << 'SCRIPT'
#!/usr/bin/env bash
# Mock npx — always succeeds
exit 0
SCRIPT
chmod +x "$NPX_MOCK"

# Temporarily add mock to PATH
OLD_PATH="$PATH"
PATH="$TMPDIR:$PATH"
# Rename mock to 'npx'
cp "$NPX_MOCK" "$TMPDIR/npx"
chmod +x "$TMPDIR/npx"

UI_TEST_CMD="npx playwright test"
rm -f UI_TEST_ERRORS.md

gate_exit=$(run_gate "test-npx-runtime")
assert_eq "9 npx command runs without availability check" "0" "$gate_exit"

PATH="$OLD_PATH"
rm -f "$TMPDIR/npx"

# =============================================================================
# Test 10: npm commands are not checked for binary availability
# =============================================================================
# Similar: "npm run e2e" should not be skipped even if e2e script isn't real.

NPM_MOCK="$TMPDIR/npm"
cat > "$NPM_MOCK" << 'SCRIPT'
#!/usr/bin/env bash
# Mock npm — always succeeds
exit 0
SCRIPT
chmod +x "$NPM_MOCK"

OLD_PATH="$PATH"
PATH="$TMPDIR:$PATH"

UI_TEST_CMD="npm run e2e"
rm -f UI_TEST_ERRORS.md

gate_exit=$(run_gate "test-npm-runtime")
assert_eq "10 npm command runs without availability check" "0" "$gate_exit"

PATH="$OLD_PATH"
rm -f "$TMPDIR/npm"

# =============================================================================
# Test 11: Overall gate pass removes BUILD_ERRORS.md
# =============================================================================
echo "# Stale errors" > BUILD_ERRORS.md
UI_TEST_CMD="$TMPDIR/pass_always.sh"

gate_exit=$(run_gate "test-cleanup")
assert_eq "11 gate passes with passing UI test" "0" "$gate_exit"
assert_file_not_exists "11 BUILD_ERRORS.md removed on overall pass" "BUILD_ERRORS.md"

# =============================================================================
# Test 12: UI_TEST_ERRORS.md NOT written on gate pass
# =============================================================================
UI_TEST_CMD="$TMPDIR/pass_always.sh"
rm -f UI_TEST_ERRORS.md

gate_exit=$(run_gate "test-no-errors-on-pass")
assert_eq "12 gate passes" "0" "$gate_exit"
assert_file_not_exists "12 UI_TEST_ERRORS.md NOT written on pass" "UI_TEST_ERRORS.md"

# =============================================================================
# Summary
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "All UI build gate tests passed (12/12)"
    exit 0
else
    echo "Some UI build gate tests FAILED"
    exit 1
fi
