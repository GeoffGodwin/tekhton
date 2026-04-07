#!/usr/bin/env bash
# test_audit_coverage_gaps.sh — Coverage gap tests for lib/test_audit.sh (M20)
#
# Covers two gaps identified by the reviewer:
#   1. _collect_audit_context in a non-git directory: the git rev-parse guard
#      (line 45) must skip deleted-file detection outside a git repo.
#   2. _detect_test_weakening "removed test functions" branch (lines 200-209):
#      detects def test_/it(/test(/func Test/describe( removals in git diff.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
NON_GIT_DIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST" "$NON_GIT_DIR"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
TEKHTON_SESSION_DIR=$(mktemp -d "$TMPDIR_TEST/session_XXXXXXXX")
export TEKHTON_HOME PROJECT_DIR TEKHTON_SESSION_DIR

# Initialize git repo in PROJECT_DIR
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

# Required globals
TASK="test task"
TIMESTAMP="20260324_120000"
LOG_DIR="${PROJECT_DIR}/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/test.log"
touch "$LOG_FILE"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
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
TEST_AUDIT_REPORT_FILE="TEST_AUDIT_REPORT.md"
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

echo "=== Test Audit Coverage Gap Tests (M20) ==="
echo

# =============================================================================
# Gap 1: _collect_audit_context in a non-git directory
#
# When PROJECT_DIR (CWD) is not inside a git repo, the `git rev-parse --git-dir`
# guard at line 45 of test_audit.sh must skip deleted-file detection entirely.
# _AUDIT_DELETED_FILES must be empty. Other fields (test files, impl files) must
# still be populated from the report markdown files.
# =============================================================================

echo "--- Gap 1: _collect_audit_context in non-git directory ---"

# Guard: if NON_GIT_DIR happens to be inside a git repo, skip this section.
if git -C "$NON_GIT_DIR" rev-parse --git-dir &>/dev/null; then
    echo "SKIP: NON_GIT_DIR is inside a git repo — cannot test non-git code path"
else
    # Create report files in the non-git directory so those branches execute.
    cat > "$NON_GIT_DIR/TESTER_REPORT.md" << 'EOF'
## Planned Tests
- [x] `tests/test_foo.py` — foo tests
- [x] `tests/test_bar.py` — bar tests

## Test Run Results
Passed: 2  Failed: 0

## Bugs Found
None
EOF

    cat > "$NON_GIT_DIR/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Files Modified
- `src/foo.py` — foo module
- `src/bar.py` — bar module
EOF

    # pushd into the non-git dir, run _collect_audit_context, capture results,
    # then pop back to PROJECT_DIR. pushd/popd are bash builtins — no subshell,
    # so variable assignments from _collect_audit_context are visible here.
    pushd "$NON_GIT_DIR" > /dev/null
    _collect_audit_context
    _non_git_deleted="$_AUDIT_DELETED_FILES"
    _non_git_tests="$_AUDIT_TEST_FILES"
    popd > /dev/null

    assert_empty \
        "non-git: _AUDIT_DELETED_FILES empty when not in a git repo (git guard fires)" \
        "$_non_git_deleted"
    assert_contains \
        "non-git: _AUDIT_TEST_FILES still populated from TESTER_REPORT.md" \
        "tests/test_foo.py" "$_non_git_tests"
fi

# =============================================================================
# Gap 2: _detect_test_weakening — removed test functions branch (lines 200-209)
#
# The branch fires when lines matching `^\-\s*(def test_|it\(|test\(|func Test|
# describe\()` are present in `git diff HEAD -- <file>`. The existing tests only
# exercised the assertion-count and specific-to-generic branches.
# =============================================================================

echo
echo "--- Gap 2: _detect_test_weakening: removed test functions (JS it()) ---"

mkdir -p tests

# Commit a JS test file with two it() blocks.
cat > tests/test_calc.spec.js << 'EOF'
describe('calculator', () => {
    it('adds two numbers', () => {
        expect(add(1, 2)).toBe(3);
    });
    it('subtracts two numbers', () => {
        expect(subtract(5, 3)).toBe(2);
    });
});
EOF

(cd "$PROJECT_DIR" && git add tests/test_calc.spec.js && git commit -q -m "add js calc tests")

# Remove the second it() block — this is the "removed test function" weakening.
cat > tests/test_calc.spec.js << 'EOF'
describe('calculator', () => {
    it('adds two numbers', () => {
        expect(add(1, 2)).toBe(3);
    });
});
EOF

_AUDIT_WEAKENING_FINDINGS=""
_AUDIT_TEST_FILES="tests/test_calc.spec.js"
_detect_test_weakening

assert_contains \
    "removed-js-fn: WEAKENING finding emitted when it() block removed" \
    "WEAKENING" "$_AUDIT_WEAKENING_FINDINGS"
assert_contains \
    "removed-js-fn: finding states 'test function(s) removed'" \
    "test function" "$_AUDIT_WEAKENING_FINDINGS"
assert_contains \
    "removed-js-fn: finding names the modified test file" \
    "test_calc.spec.js" "$_AUDIT_WEAKENING_FINDINGS"

# Restore the file; verify no finding when the diff is empty.
(cd "$PROJECT_DIR" && git checkout -- tests/test_calc.spec.js)

_AUDIT_WEAKENING_FINDINGS=""
_AUDIT_TEST_FILES="tests/test_calc.spec.js"
_detect_test_weakening
assert_empty \
    "removed-js-fn: no finding when file unchanged (empty diff)" \
    "$_AUDIT_WEAKENING_FINDINGS"

echo
echo "--- Gap 2: _detect_test_weakening: removed test functions (Python def test_) ---"

# Commit a Python test file with three test methods.
cat > tests/test_math.py << 'EOF'
import unittest

class TestMath(unittest.TestCase):
    def test_add(self):
        self.assertEqual(1 + 1, 2)

    def test_subtract(self):
        self.assertEqual(5 - 3, 2)

    def test_multiply(self):
        self.assertEqual(3 * 4, 12)
EOF

(cd "$PROJECT_DIR" && git add tests/test_math.py && git commit -q -m "add python math tests")

# Remove two test methods (test_subtract and test_multiply).
cat > tests/test_math.py << 'EOF'
import unittest

class TestMath(unittest.TestCase):
    def test_add(self):
        self.assertEqual(1 + 1, 2)
EOF

_AUDIT_WEAKENING_FINDINGS=""
_AUDIT_TEST_FILES="tests/test_math.py"
_detect_test_weakening

assert_contains \
    "removed-py-fn: WEAKENING finding emitted when def test_ methods removed" \
    "WEAKENING" "$_AUDIT_WEAKENING_FINDINGS"
assert_contains \
    "removed-py-fn: finding names the python test file" \
    "test_math.py" "$_AUDIT_WEAKENING_FINDINGS"

# =============================================================================
# Summary
# =============================================================================

echo
echo "════════════════════════════════════════"
echo "  Coverage Gap Tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
