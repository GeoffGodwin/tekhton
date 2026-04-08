#!/usr/bin/env bash
# Test: test_plan_answers_completeness.sh
# Tests answer file completeness checking, particularly after importing
# Verifies that imported answers are properly validated and the completeness
# check prevents loops when answers are complete
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail()  { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
log()   { :; }
warn()  { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
success() { :; }
header() { :; }

# Create temp directory for testing
TEST_TMP=$(mktemp -d)
trap "rm -rf $TEST_TMP" EXIT

# Setup test environment
export PROJECT_DIR="$TEST_TMP"
export TEKHTON_HOME
export TEKHTON_VERSION="3.65.0"
export PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"
export TEKHTON_TEST_MODE=1

# Source required libraries
source "${TEKHTON_HOME}/lib/plan_answers.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

echo "=== Testing Answer File Completeness Checking ==="

# Create a test template with required sections
TEST_TEMPLATE="${TEST_TMP}/test_template.md"
cat > "$TEST_TEMPLATE" << 'TMPL'
# Test Design

## Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What is this? -->

## Architecture
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- How does it work? -->

## Optional Feature
<!-- PHASE:3 -->
<!-- This is optional -->
TMPL

# Test 1: Empty answer file should NOT be complete
echo "Test 1: Empty answer file is marked incomplete"

PROJECT_DIR="${TEST_TMP}/project_empty"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true

if ! answer_file_complete; then
    pass "Empty answer file is correctly marked incomplete"
else
    fail "Empty answer file should not be complete"
fi

# Test 2: Partially filled answer file should NOT be complete
echo "Test 2: Partially filled answer file is marked incomplete"

PROJECT_DIR="${TEST_TMP}/project_partial"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Overview content" 2>/dev/null || true
# Note: architecture is still empty

if ! answer_file_complete; then
    pass "Partially filled answer file is marked incomplete"
else
    fail "Answer file with only some required sections should not be complete"
fi

# Test 3: Fully filled answer file SHOULD be complete
echo "Test 3: Fully filled answer file is marked complete"

PROJECT_DIR="${TEST_TMP}/project_complete"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Complete overview" 2>/dev/null || true
save_answer "architecture" "Complete architecture" 2>/dev/null || true
# optional_feature is not filled, but that's OK since it's optional

if answer_file_complete; then
    pass "Fully filled answer file is marked complete"
else
    fail "Answer file with all required sections should be complete"
fi

# Test 4: TBD answers should mark as incomplete
echo "Test 4: TBD placeholder marks answer as incomplete"

PROJECT_DIR="${TEST_TMP}/project_tbd"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "TBD" 2>/dev/null || true
save_answer "architecture" "Complete architecture" 2>/dev/null || true

if ! answer_file_complete; then
    pass "Answer file with TBD placeholder is marked incomplete"
else
    fail "TBD answers should mark file as incomplete"
fi

# Test 5: SKIP placeholder marks as incomplete
echo "Test 5: SKIP placeholder marks answer as incomplete"

PROJECT_DIR="${TEST_TMP}/project_skip"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Good overview" 2>/dev/null || true
save_answer "architecture" "SKIP" 2>/dev/null || true

if ! answer_file_complete; then
    pass "SKIP placeholder marks file as incomplete"
else
    fail "SKIP answers should mark file as incomplete"
fi

# Test 6: Imported complete answers should pass completeness check
echo "Test 6: Imported complete answers pass completeness check"

PROJECT_DIR="${TEST_TMP}/project_import"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

# Create and fill initial answer file
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Imported overview" 2>/dev/null || true
save_answer "architecture" "Imported architecture" 2>/dev/null || true

# Export to import file
IMPORT_FILE="${TEST_TMP}/complete_answers.yaml"
cp "$PLAN_ANSWER_FILE" "$IMPORT_FILE"

# Reset and import
rm -f "$PLAN_ANSWER_FILE"
import_answer_file "$IMPORT_FILE" 2>/dev/null || true

# Verify imported file is complete
if answer_file_complete; then
    pass "Imported complete answers pass completeness check"
else
    fail "Imported answers should pass completeness check if all required sections have answers"
fi

# Test 7: Imported incomplete answers should fail completeness check
echo "Test 7: Imported incomplete answers fail completeness check"

PROJECT_DIR="${TEST_TMP}/project_import_incomplete"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

# Create incomplete answer file
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Overview only" 2>/dev/null || true
# architecture not filled

# Export to import file
IMPORT_FILE_INCOMPLETE="${TEST_TMP}/incomplete_answers.yaml"
cp "$PLAN_ANSWER_FILE" "$IMPORT_FILE_INCOMPLETE"

# Reset and import
rm -f "$PLAN_ANSWER_FILE"
if import_answer_file "$IMPORT_FILE_INCOMPLETE" 2>/dev/null; then
    # import_answer_file should return 1 if answers are incomplete
    fail "Importing incomplete answers should fail"
else
    pass "Importing incomplete answers fails as expected"
fi

# Test 8: Answer file with whitespace-only answers is incomplete
echo "Test 8: Whitespace-only answers are treated as empty"

PROJECT_DIR="${TEST_TMP}/project_whitespace"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "   " 2>/dev/null || true  # spaces only
save_answer "architecture" "Architecture content" 2>/dev/null || true

# The completeness check should trim whitespace and treat it as empty
if ! answer_file_complete; then
    pass "Whitespace-only answers are treated as incomplete"
else
    fail "Whitespace-only answers should be treated as empty"
fi

# Test 9: Multi-line answers with content are valid
echo "Test 9: Multi-line answers with content are marked complete"

PROJECT_DIR="${TEST_TMP}/project_multiline"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true

# Create a multi-line answer using block scalar format
MULTILINE_OVERVIEW=$'This is the first line\nThis is the second line\nThis is the third line'
save_answer "overview" "$MULTILINE_OVERVIEW" 2>/dev/null || true
save_answer "architecture" "Single line architecture" 2>/dev/null || true

if answer_file_complete; then
    pass "Multi-line answers with content are valid"
else
    fail "Multi-line answers should be treated as valid content"
fi

# Test 10: Verify imported answers prevent re-initialization
echo "Test 10: Imported answers prevent blank template initialization"

PROJECT_DIR="${TEST_TMP}/project_guard_prevent_init"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

# Create complete answers
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Guard test overview" 2>/dev/null || true
save_answer "architecture" "Guard test architecture" 2>/dev/null || true
IMPORT_FILE="${TEST_TMP}/guard_test_answers.yaml"
cp "$PLAN_ANSWER_FILE" "$IMPORT_FILE"

# Simulate the guard condition from plan_interview.sh lines 264-277
# When PLAN_ANSWERS_IMPORT is set and file exists, should NOT initialize
PLAN_ANSWERS_IMPORT="$IMPORT_FILE"

# Reset answer file
rm -f "$PLAN_ANSWER_FILE"

# Import the answers
import_answer_file "$PLAN_ANSWERS_IMPORT" 2>/dev/null || true

# Verify that the imported content is there (not blank template)
OVERVIEW=$(load_answer "overview" 2>/dev/null || true)
if [[ "$OVERVIEW" == *"Guard test overview"* ]]; then
    pass "Imported answers prevent blank template initialization"
else
    fail "Imported content should not be overwritten with blank template"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
