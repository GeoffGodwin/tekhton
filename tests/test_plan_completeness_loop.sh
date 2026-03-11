#!/usr/bin/env bash
# Test: run_plan_completeness_loop orchestration and multi-line HTML comment detection
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# Tracks how many times run_plan_followup_interview was called
FOLLOWUP_CALL_COUNT=0

# Mock run_plan_followup_interview — avoids invoking claude
run_plan_followup_interview() {
    FOLLOWUP_CALL_COUNT=$((FOLLOWUP_CALL_COUNT + 1))
    return 0
}

TEST_TMPDIR=$(mktemp -d)
PROJECT_DIR="$TEST_TMPDIR"
export TEKHTON_TEST_MODE=1
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Source plan.sh (defines _is_section_incomplete, check_design_completeness,
# run_plan_completeness_loop, etc.)
# shellcheck source=../lib/plan.sh
source "${TEKHTON_HOME}/lib/plan.sh"
# shellcheck source=../lib/plan_completeness.sh
source "${TEKHTON_HOME}/lib/plan_completeness.sh"

# Re-declare mock after sourcing (plan.sh does not define this function, but
# guard against future changes)
run_plan_followup_interview() {
    FOLLOWUP_CALL_COUNT=$((FOLLOWUP_CALL_COUNT + 1))
    return 0
}

# Set up a template with REQUIRED markers used by check_design_completeness
PLAN_TEMPLATE_FILE="${TEST_TMPDIR}/template.md"
cat > "$PLAN_TEMPLATE_FILE" << 'EOF'
# Design Document

## Overview
<!-- REQUIRED -->
<!-- Describe the project -->

## Tech Stack
<!-- REQUIRED -->
<!-- Language and framework -->

## Optional Section
<!-- Not required -->
EOF

# Helper: write a DESIGN.md where all required sections are filled
make_complete_design() {
    cat > "${TEST_TMPDIR}/DESIGN.md" << 'EOF'
# Design Document

## Overview
A task management web application for small teams.

## Tech Stack
React, Node.js, PostgreSQL.

## Optional Section
Skipped intentionally.
EOF
}

# Helper: write a DESIGN.md with one incomplete section (TBD placeholder)
make_incomplete_design() {
    cat > "${TEST_TMPDIR}/DESIGN.md" << 'EOF'
# Design Document

## Overview
A task management web application.

## Tech Stack
TBD
EOF
}

# ---------------------------------------------------------------------------
echo "=== _is_section_incomplete — multi-line HTML comment ==="

# A comment that spans multiple lines (<!-- on one line, --> on another).
# sed 's/<!--.*-->//g' does NOT strip this because .* won't cross newlines.
# The grep -q '<!--' fallback detects the remaining open comment tag.
multiline_comment="<!--
This guidance comment spans
multiple lines of content
-->"
if _is_section_incomplete "$multiline_comment"; then
    pass "Multi-line HTML comment only is incomplete"
else
    fail "Multi-line HTML comment only should be incomplete"
fi

# Real content followed by a multi-line HTML comment
mixed_content="React and Node.js
<!--
Add more detail here
-->"
if _is_section_incomplete "$mixed_content"; then
    pass "Real content with trailing multi-line comment is incomplete"
else
    fail "Real content with trailing multi-line comment should be incomplete"
fi

# Real content with a multi-line comment at the start
leading_comment="<!--
Primary stack choice
-->
React, Node.js, PostgreSQL."
if _is_section_incomplete "$leading_comment"; then
    pass "Content with leading multi-line comment is incomplete"
else
    fail "Content with leading multi-line comment should be incomplete"
fi

# Control case: real content with no comments should be complete
if _is_section_incomplete "React, Node.js, PostgreSQL, deployed on AWS."; then
    fail "Real content without comments should be complete"
else
    pass "Real content without multi-line comments is complete (control)"
fi

# ---------------------------------------------------------------------------
echo
echo "=== run_plan_completeness_loop — complete DESIGN.md passes immediately ==="

make_complete_design
FOLLOWUP_CALL_COUNT=0
result=0
run_plan_completeness_loop < /dev/null > /dev/null 2>&1 || result=$?
if [ "$result" -eq 0 ]; then
    pass "Complete DESIGN.md: loop exits 0 on first pass"
else
    fail "Complete DESIGN.md: expected exit 0, got ${result}"
fi
if [ "$FOLLOWUP_CALL_COUNT" -eq 0 ]; then
    pass "Complete DESIGN.md: no follow-up interview launched"
else
    fail "Complete DESIGN.md: follow-up should not be called (called ${FOLLOWUP_CALL_COUNT} times)"
fi

# ---------------------------------------------------------------------------
echo
echo "=== run_plan_completeness_loop — skip path ==="

make_incomplete_design
FOLLOWUP_CALL_COUNT=0
result=0
# User enters 's' to skip the follow-up interview
run_plan_completeness_loop < <(printf "s\n") > /dev/null 2>&1 || result=$?
if [ "$result" -eq 0 ]; then
    pass "Skip path: returns 0 when user enters 's'"
else
    fail "Skip path: expected exit 0, got ${result}"
fi
if [ "$FOLLOWUP_CALL_COUNT" -eq 0 ]; then
    pass "Skip path: no follow-up interview launched"
else
    fail "Skip path: follow-up should not be called (called ${FOLLOWUP_CALL_COUNT} times)"
fi

# ---------------------------------------------------------------------------
echo
echo "=== run_plan_completeness_loop — invalid input then skip ==="

make_incomplete_design
FOLLOWUP_CALL_COUNT=0
result=0
# Invalid choice 'x' triggers inner re-prompt loop without re-running completeness check
# Inner loop re-prompts: user enters 's' → returns 0
run_plan_completeness_loop < <(printf "x\ns\n") > /dev/null 2>&1 || result=$?
if [ "$result" -eq 0 ]; then
    pass "Invalid-input path: returns 0 after invalid choice then skip"
else
    fail "Invalid-input path: expected exit 0, got ${result}"
fi
if [ "$FOLLOWUP_CALL_COUNT" -eq 0 ]; then
    pass "Invalid-input path: no follow-up interview launched"
else
    fail "Invalid-input path: follow-up should not be called (called ${FOLLOWUP_CALL_COUNT} times)"
fi

# ---------------------------------------------------------------------------
echo
echo "=== run_plan_completeness_loop — max follow-up cap ==="

make_incomplete_design
FOLLOWUP_CALL_COUNT=0
result=0
# DESIGN.md stays incomplete through all follow-up passes (mock does nothing).
# Pass 1: fails, pass_num=1 < 3, prompts → 'f' (follow-up called, still incomplete)
# Pass 2: fails, pass_num=2 < 3, prompts → 'f' (follow-up called, still incomplete)
# Pass 3: fails, pass_num=3 >= 3, warns and returns 0 without prompting
run_plan_completeness_loop < <(printf "f\nf\n") > /dev/null 2>&1 || result=$?
if [ "$result" -eq 0 ]; then
    pass "Max-followup cap: returns 0 after hitting 3-pass limit"
else
    fail "Max-followup cap: expected exit 0, got ${result}"
fi
if [ "$FOLLOWUP_CALL_COUNT" -eq 2 ]; then
    pass "Max-followup cap: follow-up called exactly twice (passes 1 and 2)"
else
    fail "Max-followup cap: expected 2 follow-up calls, got ${FOLLOWUP_CALL_COUNT}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== run_plan_completeness_loop — missing DESIGN.md ==="

rm -f "${TEST_TMPDIR}/DESIGN.md"
FOLLOWUP_CALL_COUNT=0
result=0
run_plan_completeness_loop < /dev/null > /dev/null 2>&1 || result=$?
if [ "$result" -ne 0 ]; then
    pass "Missing DESIGN.md: returns non-zero"
else
    fail "Missing DESIGN.md: expected non-zero return"
fi
if [ "$FOLLOWUP_CALL_COUNT" -eq 0 ]; then
    pass "Missing DESIGN.md: no follow-up interview launched"
else
    fail "Missing DESIGN.md: follow-up should not be called"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
