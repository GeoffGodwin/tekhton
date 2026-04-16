#!/usr/bin/env bash
# test_audit_tests.sh — Tests for lib/test_audit.sh (Milestone 20)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
TEKHTON_SESSION_DIR=$(mktemp -d "$TMPDIR_TEST/session_XXXXXXXX")
TEKHTON_DIR=".tekhton"
mkdir -p "${TMPDIR_TEST}/${TEKHTON_DIR}"
export TEKHTON_HOME PROJECT_DIR TEKHTON_SESSION_DIR TEKHTON_DIR

# Set default file paths
TESTER_REPORT_FILE="${TESTER_REPORT_FILE:-${TEKHTON_DIR}/TESTER_REPORT.md}"
CODER_SUMMARY_FILE="${CODER_SUMMARY_FILE:-${TEKHTON_DIR}/CODER_SUMMARY.md}"
export TESTER_REPORT_FILE CODER_SUMMARY_FILE

# Initialize git repo
(cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -m "init" -q)

cd "$PROJECT_DIR"

# --- Source required libraries ---
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

# Stub functions that test_audit.sh depends on
run_agent() { :; }
was_null_run() { return 1; }
render_prompt() { echo "stub prompt"; }
_safe_read_file() { cat "$1" 2>/dev/null || true; }
_ensure_nonblocking_log() { :; }
print_run_summary() { :; }
emit_event() { :; }

# Set required globals
TASK="test task"
TIMESTAMP="20260324_120000"
LOG_DIR="${PROJECT_DIR}/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/test.log"
touch "$LOG_FILE"
NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CLAUDE_REVIEWER_MODEL="claude-sonnet-4-6"
CLAUDE_TESTER_MODEL="claude-sonnet-4-6"
AGENT_TOOLS_REVIEWER="Read Glob Grep"
AGENT_TOOLS_TESTER="Read Glob Grep Write Edit Bash"
TESTER_MAX_TURNS=30
TEST_AUDIT_ENABLED=true
TEST_AUDIT_MAX_TURNS=8
TEST_AUDIT_MAX_REWORK_CYCLES=1
TEST_AUDIT_ORPHAN_DETECTION=true
TEST_AUDIT_WEAKENING_DETECTION=true
TEST_AUDIT_REPORT_FILE="${TEKHTON_DIR}/TEST_AUDIT_REPORT.md"
BOLD=""
NC=""

# --- Source test_audit.sh ---
source "${TEKHTON_HOME}/lib/test_audit.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected='$expected', got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -qF "$expected"; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected to contain '$expected', got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected empty, got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Test Audit Tests (M20) ==="
echo

# --- Test _collect_audit_context ---

echo "--- _collect_audit_context ---"

# Test with TESTER_REPORT.md having checked items
cat > "${TESTER_REPORT_FILE}" << 'EOF'
## Planned Tests
- [x] `tests/test_auth.py` — auth tests
- [x] `tests/test_api.py` — api tests
- [ ] `tests/test_db.py` — db tests

## Test Run Results
Passed: 5  Failed: 0

## Bugs Found
None
EOF

cat > "${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: COMPLETE
## Files Modified
- `src/auth.py` — auth module
- `src/api.py` — api module
EOF

_collect_audit_context
assert_contains "collect: finds checked test files" "tests/test_auth.py" "$_AUDIT_TEST_FILES"
assert_contains "collect: finds checked test files (2)" "tests/test_api.py" "$_AUDIT_TEST_FILES"
assert_contains "collect: finds impl files" "src/auth.py" "$_AUDIT_IMPL_FILES"
assert_contains "collect: finds impl files (2)" "src/api.py" "$_AUDIT_IMPL_FILES"

# --- Test _detect_orphaned_tests ---

echo
echo "--- _detect_orphaned_tests ---"

# Create a test file that imports a deleted module
mkdir -p tests
cat > tests/test_legacy.py << 'EOF'
from src.legacy_handler import LegacyHandler
import unittest

class TestLegacy(unittest.TestCase):
    def test_handle(self):
        handler = LegacyHandler()
        self.assertTrue(handler.handle())
EOF

# Simulate deleted file
local_deleted="src/legacy_handler.py"

_detect_orphaned_tests "tests/test_legacy.py" "$local_deleted"
assert_contains "orphan: detects import of deleted module" "ORPHAN" "$_AUDIT_ORPHAN_FINDINGS"
assert_contains "orphan: names the deleted file" "legacy_handler" "$_AUDIT_ORPHAN_FINDINGS"

# Test with no deletions — should find nothing
_detect_orphaned_tests "tests/test_legacy.py" ""
assert_empty "orphan: no findings when no deletions" "$_AUDIT_ORPHAN_FINDINGS"

# Test with no test files — should find nothing
_detect_orphaned_tests "" "$local_deleted"
assert_empty "orphan: no findings when no test files" "$_AUDIT_ORPHAN_FINDINGS"

# --- Test _detect_orphaned_tests with JS imports ---

echo
echo "--- _detect_orphaned_tests (JS) ---"

cat > tests/test_utils.js << 'EOF'
const { parseConfig } = require('../src/config_parser');
const assert = require('assert');

describe('config parser', () => {
    it('parses config', () => {
        const result = parseConfig('key=value');
        assert.strictEqual(result.key, 'value');
    });
});
EOF

_detect_orphaned_tests "tests/test_utils.js" "src/config_parser.js"
assert_contains "orphan-js: detects require of deleted module" "ORPHAN" "$_AUDIT_ORPHAN_FINDINGS"

# --- Test _detect_test_weakening ---

echo
echo "--- _detect_test_weakening ---"

# Create a test file in git, then modify it to weaken assertions
cat > tests/test_calc.py << 'EOF'
import unittest

class TestCalc(unittest.TestCase):
    def test_add(self):
        result = add(2, 3)
        self.assertEqual(result, 5)

    def test_subtract(self):
        result = subtract(5, 3)
        self.assertEqual(result, 2)
EOF

(cd "$PROJECT_DIR" && git add tests/test_calc.py && git commit -q -m "add calc tests")

# Now weaken: replace assertEqual with assertTrue
cat > tests/test_calc.py << 'EOF'
import unittest

class TestCalc(unittest.TestCase):
    def test_add(self):
        result = add(2, 3)
        self.assertTrue(result > 0)
EOF

_AUDIT_TEST_FILES="tests/test_calc.py"
_detect_test_weakening

assert_contains "weakening: detects broadened assertions" "WEAKENING" "$_AUDIT_WEAKENING_FINDINGS"
assert_contains "weakening: notes assertion loss" "assertion" "$_AUDIT_WEAKENING_FINDINGS"

# Reset for next test
(cd "$PROJECT_DIR" && git checkout -- tests/test_calc.py 2>/dev/null || true)

# Test with a newly created file (no weakening possible)
cat > tests/test_new.py << 'EOF'
import unittest

class TestNew(unittest.TestCase):
    def test_new(self):
        self.assertTrue(True)
EOF

_AUDIT_TEST_FILES="tests/test_new.py"
_detect_test_weakening
assert_empty "weakening: no findings for new files" "$_AUDIT_WEAKENING_FINDINGS"

# --- Test _parse_audit_verdict ---

echo
echo "--- _parse_audit_verdict ---"

# PASS verdict
cat > "${TEST_AUDIT_REPORT_FILE}" << 'EOF'
## Test Audit Report

### Audit Summary
Tests audited: 3 files, 12 test functions
Verdict: PASS

### Findings
None
EOF

result=$(_parse_audit_verdict)
assert_eq "verdict: parses PASS" "PASS" "$result"

# NEEDS_WORK verdict
cat > "${TEST_AUDIT_REPORT_FILE}" << 'EOF'
## Test Audit Report

### Audit Summary
Tests audited: 3 files, 12 test functions
Verdict: NEEDS_WORK

### Findings
#### INTEGRITY: Hard-coded assertion
- File: tests/test_calc.py:34
- Issue: assert result == 42
- Severity: HIGH
- Action: Rewrite to test actual computation
EOF

result=$(_parse_audit_verdict)
assert_eq "verdict: parses NEEDS_WORK" "NEEDS_WORK" "$result"

# CONCERNS verdict
cat > "${TEST_AUDIT_REPORT_FILE}" << 'EOF'
## Test Audit Report

### Audit Summary
Tests audited: 5 files, 20 test functions
Verdict: CONCERNS

### Findings
#### COVERAGE: Missing error path
- File: tests/test_auth.py
- Issue: No tests for expired token
- Severity: MEDIUM
- Action: Add error path tests
EOF

result=$(_parse_audit_verdict)
assert_eq "verdict: parses CONCERNS" "CONCERNS" "$result"

# Missing report file — defaults to PASS
rm -f "${TEST_AUDIT_REPORT_FILE}"
result=$(_parse_audit_verdict)
assert_eq "verdict: defaults to PASS when no report" "PASS" "$result"

# --- Test _route_audit_verdict ---

echo
echo "--- _route_audit_verdict ---"

_route_audit_verdict "PASS" > /dev/null 2>&1
assert_eq "route: PASS returns 0" "0" "$?"

_route_audit_verdict "CONCERNS" > /dev/null 2>&1
assert_eq "route: CONCERNS returns 0" "0" "$?"

_route_audit_verdict "NEEDS_WORK" > /dev/null 2>&1 || local_exit=$?
assert_eq "route: NEEDS_WORK returns 1" "1" "${local_exit:-0}"

# --- Test run_test_audit skip conditions ---

echo
echo "--- run_test_audit skip conditions ---"

# Test disabled audit
TEST_AUDIT_ENABLED=false
run_test_audit > /dev/null 2>&1
assert_eq "skip: disabled audit returns 0" "0" "$?"
TEST_AUDIT_ENABLED=true

# Test no test files written
rm -f "${TESTER_REPORT_FILE}"
_AUDIT_TEST_FILES=""
run_test_audit > /dev/null 2>&1
assert_eq "skip: no test files returns 0" "0" "$?"

# --- Test _discover_all_test_files ---

echo
echo "--- _discover_all_test_files ---"

# Create some test files tracked by git
mkdir -p tests src/__tests__
echo "test content" > tests/test_foo.py
echo "test content" > tests/test_bar.js
echo "test content" > src/__tests__/baz.test.ts
echo "not a test" > src/main.py
(cd "$PROJECT_DIR" && git add -A && git commit -q -m "add test files")

result=$(_discover_all_test_files)
assert_contains "discover: finds tests/ files" "tests/test_foo.py" "$result"
assert_contains "discover: finds __tests__ files" "src/__tests__/baz.test.ts" "$result"

# --- Test rework cycle bounds ---

echo
echo "--- rework cycle bounds ---"

# Verify max rework cycles default
assert_eq "config: max rework cycles" "1" "$TEST_AUDIT_MAX_REWORK_CYCLES"

# Verify max turns default
assert_eq "config: max audit turns" "8" "$TEST_AUDIT_MAX_TURNS"

# --- Test _route_audit_verdict CONCERNS when _ensure_nonblocking_log is absent ---

echo
echo "--- _route_audit_verdict CONCERNS (no _ensure_nonblocking_log) ---"

# Create a report with CONCERNS verdict and a heading that matches the grep pattern,
# so that $findings is non-empty and the guard on _ensure_nonblocking_log is reached.
cat > "${TEST_AUDIT_REPORT_FILE}" << 'EOF'
## Test Audit Report

### Audit Summary
Verdict: CONCERNS

### Findings
#### COVERAGE: Missing error path
- File: tests/test_auth.py
- Issue: No tests for expired token
- Severity: MEDIUM
EOF

rm -f "$NON_BLOCKING_LOG_FILE"

# Remove _ensure_nonblocking_log to simulate it being unavailable.
unset -f _ensure_nonblocking_log

_route_audit_verdict "CONCERNS" > /dev/null 2>&1
assert_eq "route-concerns-skip: returns 0 when _ensure_nonblocking_log absent" "0" "$?"

nb_content=$(cat "$NON_BLOCKING_LOG_FILE" 2>/dev/null || true)
assert_empty "route-concerns-skip: does not write NON_BLOCKING_LOG when function absent" "$nb_content"

# Restore the stub for subsequent tests.
_ensure_nonblocking_log() { :; }

# Contrast: verify log IS written when _ensure_nonblocking_log IS available.
rm -f "$NON_BLOCKING_LOG_FILE"
_route_audit_verdict "CONCERNS" > /dev/null 2>&1
assert_eq "route-concerns-write: returns 0 when _ensure_nonblocking_log present" "0" "$?"
nb_content=$(cat "$NON_BLOCKING_LOG_FILE" 2>/dev/null || true)
assert_contains "route-concerns-write: writes COVERAGE finding to NON_BLOCKING_LOG" "COVERAGE" "$nb_content"

# --- Test run_test_audit rework cycle (NEEDS_WORK → rework → PASS) ---

echo
echo "--- run_test_audit rework cycle ---"

# Prepare a TESTER_REPORT.md with one checked test file so _collect_audit_context
# populates _AUDIT_TEST_FILES (required for run_test_audit to proceed past the skip guard).
cat > "${TESTER_REPORT_FILE}" << 'EOF'
## Planned Tests
- [x] `tests/test_calc.py` — calc tests

## Test Run Results
Passed: 1  Failed: 0

## Bugs Found
None
EOF

# Override run_agent with a stateful mock: first call (initial audit) writes NEEDS_WORK,
# second call (tester rework) is a no-op, third call (re-audit) writes PASS.
_MOCK_REWORK_CALL_COUNT=0
run_agent() {
    _MOCK_REWORK_CALL_COUNT=$((_MOCK_REWORK_CALL_COUNT + 1))
    local _rpt="${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}"
    if [[ "$_MOCK_REWORK_CALL_COUNT" -eq 1 ]]; then
        # Initial audit → NEEDS_WORK
        printf '## Test Audit Report\nVerdict: NEEDS_WORK\n' > "$_rpt"
    elif [[ "$_MOCK_REWORK_CALL_COUNT" -eq 3 ]]; then
        # Re-audit after rework → PASS
        printf '## Test Audit Report\nVerdict: PASS\n' > "$_rpt"
    fi
    # Second call (tester rework) intentionally leaves the report unchanged.
}

_MOCK_REWORK_CALL_COUNT=0
TEST_AUDIT_ENABLED=true
run_test_audit > /dev/null 2>&1
assert_eq "rework-cycle: run_test_audit returns 0 after rework succeeds" "0" "$?"
assert_eq "rework-cycle: run_agent called exactly 3 times (audit, rework, re-audit)" "3" "$_MOCK_REWORK_CALL_COUNT"

# Verify that after the PASS re-audit the final report file contains PASS.
final_verdict=$(_parse_audit_verdict)
assert_eq "rework-cycle: final verdict is PASS after rework" "PASS" "$final_verdict"

# Restore the no-op stub used by earlier tests.
run_agent() { :; }

# --- Summary ---
echo
echo "════════════════════════════════════════"
echo "  Test Audit Tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
