#!/usr/bin/env bash
# test_audit_standalone.sh — Coverage for run_standalone_test_audit and emit_event guard
# Addresses reviewer coverage gaps for Milestone 20.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
TEKHTON_SESSION_DIR=$(mktemp -d "$TMPDIR_TEST/session_XXXXXXXX")
export TEKHTON_HOME PROJECT_DIR TEKHTON_SESSION_DIR

# Initialize git repo
(cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -m "init" -q)

cd "$PROJECT_DIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"

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
TESTER_REPORT_FILE="${TEKHTON_DIR}/TESTER_REPORT.md"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
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

echo "=== Standalone Test Audit + emit_event guard Tests (M20) ==="
echo

# =============================================================================
# run_standalone_test_audit: no test files committed
# =============================================================================

echo "--- run_standalone_test_audit: no test files ---"

# The repo has only the empty init commit — no test files tracked.
output=$(run_standalone_test_audit 2>&1)
assert_contains "standalone-no-files: logs no test files" "No test files found" "$output"

# =============================================================================
# run_standalone_test_audit: test files present, PASS verdict
# =============================================================================

echo
echo "--- run_standalone_test_audit: test files + PASS verdict ---"

mkdir -p tests
echo "echo ok" > tests/test_foo.sh
echo "test content" > tests/test_bar.py
(cd "$PROJECT_DIR" && git add -A && git commit -q -m "add test files")

# run_agent writes a PASS report
run_agent() {
    cat > "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" << 'REOF'
## Test Audit Report
Verdict: PASS
### Findings
None
REOF
}

output=$(run_standalone_test_audit 2>&1)
assert_contains "standalone-pass: summary banner appears" "Test Audit Results" "$output"
assert_contains "standalone-pass: verdict shown in banner" "PASS" "$output"
assert_contains "standalone-pass: file count line present" "Files audited:" "$output"
assert_contains "standalone-pass: report path shown" "TEST_AUDIT_REPORT.md" "$output"

# =============================================================================
# run_standalone_test_audit: HIGH and MEDIUM finding counts
# =============================================================================

echo
echo "--- run_standalone_test_audit: finding counts in banner ---"

run_agent() {
    cat > "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" << 'REOF'
## Test Audit Report
Verdict: CONCERNS
### Findings
#### INTEGRITY: Hard-coded value
- Severity: HIGH
#### COVERAGE: Missing error path
- Severity: HIGH
#### NAMING: Convention mismatch
- Severity: MEDIUM
REOF
}

output=$(run_standalone_test_audit 2>&1)
assert_contains "standalone-counts: banner shows 2 HIGH findings" "HIGH findings:   2" "$output"
assert_contains "standalone-counts: banner shows 1 MEDIUM finding" "MEDIUM findings: 1" "$output"

# =============================================================================
# run_standalone_test_audit: NEEDS_WORK verdict shown (no rework in standalone)
# =============================================================================

echo
echo "--- run_standalone_test_audit: NEEDS_WORK verdict display ---"

run_agent() {
    cat > "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" << 'REOF'
## Test Audit Report
Verdict: NEEDS_WORK
### Findings
#### INTEGRITY: Assert always true
- Severity: HIGH
REOF
}

output=$(run_standalone_test_audit 2>&1)
assert_contains "standalone-needs-work: verdict shown in banner" "NEEDS_WORK" "$output"
assert_contains "standalone-needs-work: banner separator present" "════" "$output"

# Restore no-op stub
run_agent() { :; }

# =============================================================================
# emit_event guard: emit_event IS present — verify it is called
# =============================================================================

echo
echo "--- emit_event guard: emit_event present ---"

cat > "${TESTER_REPORT_FILE}" << 'EOF'
## Planned Tests
- [x] `tests/test_foo.sh` — foo tests

## Test Run Results
Passed: 1  Failed: 0

## Bugs Found
None
EOF

# Write a PASS report so run_agent (no-op) leaves it intact
cat > "${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}" << 'EOF'
## Test Audit Report
Verdict: PASS
EOF

_EMIT_CALL_COUNT=0
_EMIT_LAST_ARGS=""
emit_event() {
    _EMIT_CALL_COUNT=$((_EMIT_CALL_COUNT + 1))
    _EMIT_LAST_ARGS="$*"
}

run_test_audit > /dev/null 2>&1
assert_eq "emit-present: emit_event called exactly once" "1" "$_EMIT_CALL_COUNT"
assert_contains "emit-present: first arg is 'test_audit'" "test_audit" "$_EMIT_LAST_ARGS"
assert_contains "emit-present: payload contains verdict key" "verdict" "$_EMIT_LAST_ARGS"

# =============================================================================
# emit_event guard: emit_event IS absent — verify no error and returns 0
# =============================================================================

echo
echo "--- emit_event guard: emit_event absent ---"

unset -f emit_event

_EMIT_CALL_COUNT=0
run_test_audit > /dev/null 2>&1
_rc=$?
assert_eq "emit-absent: run_test_audit returns 0 without emit_event" "0" "$_rc"
assert_eq "emit-absent: call count unchanged (guard worked)" "0" "$_EMIT_CALL_COUNT"

# Restore stub for safety
emit_event() { :; }

# =============================================================================
# Summary
# =============================================================================

echo
echo "════════════════════════════════════════"
echo "  Standalone Audit Tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
