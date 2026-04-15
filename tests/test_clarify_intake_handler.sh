#!/usr/bin/env bash
# test_clarify_intake_handler.sh — Unit tests for _intake_handle_needs_clarity()
#
# Tests the bug fix for the clarification protocol:
# - Missing report file returns 1
# - COMPLETE_MODE check prevents interactive clarification in autonomous mode
# - Questions are written to CLARIFICATIONS.md in ## Q: format
# - handle_clarifications() is called only when interactive and COMPLETE_MODE=false
#
# Note: Since _intake_handle_needs_clarity() calls exit in some code paths,
# we run it in subshells so exit doesn't kill the test runner.
#
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME PROJECT_DIR

# --- Required globals ---
TEKHTON_SESSION_DIR="${TMPDIR_TEST}/session"
mkdir -p "$TEKHTON_SESSION_DIR"
export TEKHTON_SESSION_DIR

MILESTONE_DIR="${TMPDIR_TEST}/milestones"
mkdir -p "$MILESTONE_DIR"
export MILESTONE_DIR

MILESTONE_DAG_ENABLED="false"
MILESTONE_MODE=false
_CURRENT_MILESTONE=""
TASK="test task"
COMPLETE_MODE="false"
export MILESTONE_DAG_ENABLED MILESTONE_MODE _CURRENT_MILESTONE TASK COMPLETE_MODE

mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"
CLARIFICATIONS_FILE="${TEKHTON_DIR}/CLARIFICATIONS.md"
export CLARIFICATIONS_FILE

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
success() { :; }
export -f log warn error header success

# Mock write_pipeline_state — writes marker file then exits.
# Because it calls exit, tests must run the function in a subshell.
write_pipeline_state() {
    echo "write_pipeline_state: $*" > "${TMPDIR_TEST}/.write_state"
    exit 1
}
export -f write_pipeline_state

# Mock handle_clarifications — returns value from env var.
# Writes a marker so we can verify it was called.
handle_clarifications() {
    echo "called" > "${TMPDIR_TEST}/.handle_clarifications_called"
    return "${HANDLE_CLARIFICATIONS_RETURN:-0}"
}
export -f handle_clarifications

# Source the helpers first (for _intake_parse_questions)
# shellcheck source=../lib/intake_helpers.sh
source "${TEKHTON_HOME}/lib/intake_helpers.sh" 2>/dev/null || {
    echo "ERROR: Could not source intake_helpers.sh"
    exit 1
}

# Source the file under test
# shellcheck source=../lib/intake_verdict_handlers.sh
source "${TEKHTON_HOME}/lib/intake_verdict_handlers.sh" 2>/dev/null || {
    echo "ERROR: Could not source intake_verdict_handlers.sh"
    exit 1
}

# Export the function under test so subshells can use it
export -f _intake_handle_needs_clarity _intake_parse_questions

# --- Test helpers ---
PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# run_in_subshell — Run function in a subshell to safely catch exit calls.
# Usage: run_in_subshell "_intake_handle_needs_clarity arg1 arg2"
# Returns the exit code of the subshell.
run_in_subshell() {
    ( eval "$1" ) 2>/dev/null
    return $?
}

# ============================================================
# Test 1: No report file — should return 1 immediately
# ============================================================
echo "=== _intake_handle_needs_clarity — no report file ==="

RC=0
run_in_subshell '_intake_handle_needs_clarity "${TMPDIR_TEST}/nonexistent.md"' || RC=$?

if [[ $RC -ne 0 ]]; then
    pass "Returns non-zero when report file doesn't exist"
else
    fail "Should return non-zero when report file doesn't exist"
fi

# ============================================================
# Test 2: Report with BLOCKING questions, COMPLETE_MODE=true
# Should write CLARIFICATIONS.md with questions, then exit
# ============================================================
echo "=== _intake_handle_needs_clarity — COMPLETE_MODE=true + blocking ==="

COMPLETE_MODE="true"
export COMPLETE_MODE

REPORT_FILE="${TMPDIR_TEST}/report_complete.md"
cat > "$REPORT_FILE" << 'EOF'
## Questions

- [BLOCKING] Which database should we use?
- [BLOCKING] Should we cache responses?
EOF

rm -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" "${TMPDIR_TEST}/.write_state"

RC=0
run_in_subshell "_intake_handle_needs_clarity '$REPORT_FILE'" || RC=$?

# Should return non-zero (exit 1 in write_pipeline_state path)
if [[ $RC -ne 0 ]]; then
    pass "Returns non-zero when COMPLETE_MODE=true"
else
    fail "Should return non-zero in COMPLETE_MODE"
fi

# CLARIFICATIONS.md should be created before the exit
if [[ -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" ]]; then
    pass "Creates CLARIFICATIONS.md in COMPLETE_MODE"

    CONTENT=$(cat "${PROJECT_DIR}/${CLARIFICATIONS_FILE}")
    if echo "$CONTENT" | grep -q "Which database should we use?"; then
        pass "First question written to CLARIFICATIONS.md"
    else
        fail "First question missing from CLARIFICATIONS.md"
    fi

    if echo "$CONTENT" | grep -q "Should we cache responses?"; then
        pass "Second question written to CLARIFICATIONS.md"
    else
        fail "Second question missing from CLARIFICATIONS.md"
    fi
else
    fail "CLARIFICATIONS.md should be created in COMPLETE_MODE"
fi

# ============================================================
# Test 3: Report with NON_BLOCKING only — no questions extracted
# _intake_parse_questions looks for ## Questions section.
# NON_BLOCKING items in ## Clarification Required aren't questions.
# ============================================================
echo "=== _intake_handle_needs_clarity — non-blocking only ==="

COMPLETE_MODE="false"
export COMPLETE_MODE

REPORT_FILE="${TMPDIR_TEST}/report_nonblocking.md"
cat > "$REPORT_FILE" << 'EOF'
## Questions

- [NON_BLOCKING] Consider adding caching
- [NON_BLOCKING] API rate limiting recommended
EOF

rm -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" "${TMPDIR_TEST}/.handle_clarifications_called"

# NON_BLOCKING items ARE in ## Questions section, so they will be parsed.
# But handle_clarifications will be called (interactive mode).
HANDLE_CLARIFICATIONS_RETURN=0
export HANDLE_CLARIFICATIONS_RETURN

RC=0
run_in_subshell "_intake_handle_needs_clarity '$REPORT_FILE'" || RC=$?

if [[ $RC -eq 0 ]]; then
    pass "Returns 0 with non-blocking items (handle_clarifications succeeds)"
else
    fail "Should return 0 with non-blocking only (got RC=$RC)"
fi

# ============================================================
# Test 4: Report with BLOCKING, COMPLETE_MODE=false, handle_clarifications succeeds
# ============================================================
echo "=== _intake_handle_needs_clarity — COMPLETE_MODE=false, success ==="

COMPLETE_MODE="false"
HANDLE_CLARIFICATIONS_RETURN=0
export COMPLETE_MODE HANDLE_CLARIFICATIONS_RETURN

REPORT_FILE="${TMPDIR_TEST}/report_interactive.md"
cat > "$REPORT_FILE" << 'EOF'
## Questions

- [BLOCKING] What's your preferred language?
EOF

rm -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" "${TMPDIR_TEST}/.handle_clarifications_called"

RC=0
run_in_subshell "_intake_handle_needs_clarity '$REPORT_FILE'" || RC=$?

if [[ $RC -eq 0 ]]; then
    pass "Returns 0 when handle_clarifications succeeds"
else
    fail "Should return 0 when handle_clarifications succeeds (got RC=$RC)"
fi

# handle_clarifications should have been called
if [[ -f "${TMPDIR_TEST}/.handle_clarifications_called" ]]; then
    pass "Calls handle_clarifications in interactive mode"
else
    fail "Should call handle_clarifications in interactive mode"
fi

# ============================================================
# Test 5: Report with BLOCKING, COMPLETE_MODE=false, handle_clarifications fails
# ============================================================
echo "=== _intake_handle_needs_clarity — COMPLETE_MODE=false, failure ==="

COMPLETE_MODE="false"
HANDLE_CLARIFICATIONS_RETURN=1
export COMPLETE_MODE HANDLE_CLARIFICATIONS_RETURN

REPORT_FILE="${TMPDIR_TEST}/report_fail.md"
cat > "$REPORT_FILE" << 'EOF'
## Questions

- [BLOCKING] Architecture decision needed?
EOF

rm -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" "${TMPDIR_TEST}/.write_state" "${TMPDIR_TEST}/.handle_clarifications_called"

RC=0
run_in_subshell "_intake_handle_needs_clarity '$REPORT_FILE'" || RC=$?

if [[ $RC -ne 0 ]]; then
    pass "Returns non-zero when handle_clarifications fails"
else
    fail "Should return non-zero when handle_clarifications fails"
fi

# handle_clarifications should have been called
if [[ -f "${TMPDIR_TEST}/.handle_clarifications_called" ]]; then
    pass "Calls handle_clarifications even if it fails"
else
    fail "Should call handle_clarifications"
fi

# ============================================================
# Test 6: Multiple questions, proper ## Q: formatting
# ============================================================
echo "=== _intake_handle_needs_clarity — question formatting ==="

COMPLETE_MODE="true"
export COMPLETE_MODE

REPORT_FILE="${TMPDIR_TEST}/report_multi.md"
cat > "$REPORT_FILE" << 'EOF'
## Questions

- [BLOCKING] First question?
- [BLOCKING] Second question?
- [BLOCKING] Third question?
EOF

rm -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}"

run_in_subshell "_intake_handle_needs_clarity '$REPORT_FILE'" || true

# Check all questions made it to CLARIFICATIONS.md in ## Q: format
if [[ -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" ]]; then
    CONTENT=$(cat "${PROJECT_DIR}/${CLARIFICATIONS_FILE}")

    Q_COUNT=$(echo "$CONTENT" | grep -c "^## Q:" || true)
    if [[ $Q_COUNT -eq 3 ]]; then
        pass "All 3 questions formatted as ## Q: sections"
    else
        fail "Expected 3 ## Q: sections, found $Q_COUNT"
    fi

    # Verify tags are stripped from ## Q: lines
    if echo "$CONTENT" | grep -q "## Q: \[BLOCKING\]"; then
        fail "[BLOCKING] tag should be stripped from ## Q: line"
    else
        pass "[BLOCKING] tag stripped from question text"
    fi
else
    fail "CLARIFICATIONS.md not created"
fi

# ============================================================
# Test 7: CLARIFICATIONS.md appending on multiple runs
# ============================================================
echo "=== _intake_handle_needs_clarity — appending ==="

COMPLETE_MODE="true"
export COMPLETE_MODE

rm -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}"

# First call
REPORT1="${TMPDIR_TEST}/report_app1.md"
cat > "$REPORT1" << 'EOF'
## Questions

- [BLOCKING] Run 1 question?
EOF

run_in_subshell "_intake_handle_needs_clarity '$REPORT1'" || true

if [[ -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" ]]; then
    SIZE1=$(wc -c < "${PROJECT_DIR}/${CLARIFICATIONS_FILE}")
    pass "First run creates CLARIFICATIONS.md"
else
    fail "First run should create CLARIFICATIONS.md"
    SIZE1=0
fi

# Second call
REPORT2="${TMPDIR_TEST}/report_app2.md"
cat > "$REPORT2" << 'EOF'
## Questions

- [BLOCKING] Run 2 question?
EOF

run_in_subshell "_intake_handle_needs_clarity '$REPORT2'" || true

if [[ -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}" ]]; then
    SIZE2=$(wc -c < "${PROJECT_DIR}/${CLARIFICATIONS_FILE}")

    if (( SIZE2 > SIZE1 )); then
        pass "Second run appends to CLARIFICATIONS.md (file grew)"
    else
        fail "Second run should append (file should grow)"
    fi

    CONTENT=$(cat "${PROJECT_DIR}/${CLARIFICATIONS_FILE}")
    if echo "$CONTENT" | grep -q "Run 1 question"; then
        pass "Run 1 question still in appended file"
    else
        fail "Run 1 question missing after append"
    fi

    if echo "$CONTENT" | grep -q "Run 2 question"; then
        pass "Run 2 question in appended file"
    else
        fail "Run 2 question missing from appended file"
    fi
else
    fail "CLARIFICATIONS.md should exist after second run"
fi

# ============================================================
# Test 8: Report with no Questions section
# ============================================================
echo "=== _intake_handle_needs_clarity — no questions section ==="

REPORT_FILE="${TMPDIR_TEST}/report_empty.md"
cat > "$REPORT_FILE" << 'EOF'
## Some Other Section

Nothing here
EOF

rm -f "${PROJECT_DIR}/${CLARIFICATIONS_FILE}"

RC=0
run_in_subshell "_intake_handle_needs_clarity '$REPORT_FILE'" || RC=$?

# No questions found → function warns and returns 0 (proceeding cautiously)
if [[ $RC -eq 0 ]]; then
    pass "Returns 0 when no Questions section (proceeds cautiously)"
else
    fail "Should return 0 when no questions found (got RC=$RC)"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
