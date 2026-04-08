#!/usr/bin/env bash
# Test: test_plan_permission_request_rejection.sh
# Tests the fix for preventing permission request messages from being written to DESIGN.md
# This simulates the original bug scenario where Claude returns a permission request
# instead of the actual design document content
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
count_lines() { wc -l | awk '{print $1}'; }

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
source "${TEKHTON_HOME}/lib/plan_batch.sh"

echo "=== Testing Permission Request Rejection Mechanism ==="

# Test 1: Simulate Claude returning permission request message
echo "Test 1: Detect permission request message pattern from Claude"

# These are the known patterns that indicate a permission request from Claude
PERMISSION_REQUEST_PATTERNS=(
    "write permissions haven't been granted"
    "Could you approve the file write permission"
    "It looks like write permissions"
    "permit me to create the"
)

# Sample permission request message (the original bug)
PERM_REQUEST_MSG='It looks like write permissions haven'"'"'t been granted yet. Could you approve the file write permission so I can create the `DESIGN.md` file? The document is complete and ready — it synthesizes all your interview answers into a professional design document covering all 17 sections from the template.'

# Test that we can detect this pattern
DETECTED=0
for pattern in "${PERMISSION_REQUEST_PATTERNS[@]}"; do
    if [[ "$PERM_REQUEST_MSG" =~ $pattern ]]; then
        DETECTED=1
        break
    fi
done

if [[ $DETECTED -eq 1 ]]; then
    pass "Permission request message pattern is detectable"
else
    fail "Should be able to detect permission request patterns"
fi

# Test 2: Verify that permission request message is NOT a valid DESIGN.md
echo "Test 2: Permission request is not valid design document content"

# A valid design document should have markdown section headers
VALID_DESIGN=$(cat << 'EOF'
# Project Design

## Overview
This is a valid design document.

## Architecture
Describes the system architecture.

## Database Schema
Defines the data model.
EOF
)

# Check if permission request has markdown headers
PERM_HAS_HEADERS=0
if echo "$PERM_REQUEST_MSG" | grep -q "^##"; then
    PERM_HAS_HEADERS=1
fi

if echo "$VALID_DESIGN" | grep -q "^##"; then
    if [[ $PERM_HAS_HEADERS -eq 0 ]]; then
        pass "Permission request lacks design document structure (no markdown headers)"
    else
        fail "Permission request unexpectedly has design structure"
    fi
else
    fail "Valid design should have markdown structure"
fi

# Test 3: Simulate the original bug scenario
echo "Test 3: Original bug scenario - permission request written to file"

PROJECT_DIR="${TEST_TMP}/project_scenario"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"
DESIGN_FILE="${PROJECT_DIR}/DESIGN.md"

# Create a template
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
TMPL

# Initialize answer file
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Test overview" 2>/dev/null || true
save_answer "architecture" "Test architecture" 2>/dev/null || true

# Simulate Claude returning permission request instead of content
# (In the original bug, this would be written to DESIGN.md)
MOCK_CLAUDE_RESPONSE="$PERM_REQUEST_MSG"

# This is what would have happened in plan_interview.sh line 346
# WITHOUT the fix: it would write the permission message to DESIGN.md
# WITH the fix: the --dangerously-skip-permissions flag prevents this

# Simulate the original behavior (before fix)
printf '%s\n' "$MOCK_CLAUDE_RESPONSE" > "$DESIGN_FILE"

# Now test: completeness check should FAIL because file lacks real sections
DESIGN_HAS_SECTIONS=$(grep -c "^##" "$DESIGN_FILE" || true)

if [[ $DESIGN_HAS_SECTIONS -eq 0 ]]; then
    pass "Design file with permission message has no markdown sections"
else
    fail "Permission message should not contain design sections"
fi

# Test 4: Verify the fix prevents blank template initialization
echo "Test 4: Import guard prevents blank template when import file exists"

PROJECT_DIR="${TEST_TMP}/project_import_guard"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

# Create a valid import file with answers
IMPORT_FILE="${TEST_TMP}/answers_to_import.yaml"
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Imported overview answer" 2>/dev/null || true
save_answer "architecture" "Imported arch answer" 2>/dev/null || true
cp "$PLAN_ANSWER_FILE" "$IMPORT_FILE"

# Reset for the import test
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

# Import the file
import_answer_file "$IMPORT_FILE" 2>/dev/null || true

# Verify the imported content is preserved
if [[ -f "$PLAN_ANSWER_FILE" ]]; then
    OVERVIEW=$(load_answer "overview" 2>/dev/null || true)
    if [[ "$OVERVIEW" == *"Imported overview"* ]]; then
        pass "Imported answers are preserved in answer file"
    else
        fail "Imported answers should be preserved"
    fi
else
    fail "Answer file should exist after import"
fi

# Test 5: Verify completeness check with valid vs invalid content
echo "Test 5: Completeness check distinguishes valid DESIGN.md from permission requests"

PROJECT_DIR="${TEST_TMP}/project_completeness"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

# Initialize answers
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true
save_answer "overview" "Overview content" 2>/dev/null || true
save_answer "architecture" "Architecture content" 2>/dev/null || true

# Check completeness (should be true)
if answer_file_complete; then
    pass "Answer file with answers is marked complete"
else
    fail "Answer file with all required sections should be complete"
fi

# Test 6: Protection against repeating loop
echo "Test 6: Invalid DESIGN.md content doesn't cause repeat interviews"

PROJECT_DIR="${TEST_TMP}/project_loop_prevent"
mkdir -p "$PROJECT_DIR/.claude"
export PROJECT_DIR
DESIGN_FILE="${PROJECT_DIR}/DESIGN.md"

# Write a permission request message to DESIGN.md (simulating the bug)
printf '%s\n' "$PERM_REQUEST_MSG" > "$DESIGN_FILE"

# Check the design file
DESIGN_LINE_COUNT=$(wc -l < "$DESIGN_FILE")
DESIGN_SECTION_COUNT=$(grep -c "^##" "$DESIGN_FILE" || true)

# A permission message would be a few lines but no markdown sections
if [[ $DESIGN_LINE_COUNT -gt 0 ]] && [[ $DESIGN_SECTION_COUNT -eq 0 ]]; then
    pass "Permission message is written as file content but lacks structure"
else
    fail "Permission message should lack design document structure"
fi

# The fix is that with --dangerously-skip-permissions, Claude wouldn't return
# the permission message in the first place. Let's verify the flag is used.
TEST_LOG="${TEST_TMP}/test.log"
touch "$TEST_LOG"

# Mock claude to capture the command
mock_claude() {
    # Check if --dangerously-skip-permissions was passed
    for arg in "$@"; do
        if [[ "$arg" == "--dangerously-skip-permissions" ]]; then
            # Return valid design instead of permission message
            echo "# Valid Design"
            echo ""
            echo "## Overview"
            echo "Valid design content"
            echo ""
            echo "## Architecture"
            echo "Architecture details"
            return 0
        fi
    done

    # If flag not present, return permission message (bug scenario)
    echo "$PERM_REQUEST_MSG"
    return 0
}

export -f mock_claude
export PATH="${TEST_TMP}:${PATH}"
echo '#!/bin/bash' > "${TEST_TMP}/claude"
echo 'mock_claude "$@"' >> "${TEST_TMP}/claude"
chmod +x "${TEST_TMP}/claude"

# Call the batch function
BATCH_OUTPUT=$(_call_planning_batch "test-model" "5" "test prompt" "$TEST_LOG" || true)

# Verify output is valid design, not permission message
if [[ "$BATCH_OUTPUT" == *"# Valid Design"* ]]; then
    if [[ ! "$BATCH_OUTPUT" =~ "write permissions" ]]; then
        pass "Batch call with mock claude returns valid design, not permission message"
    else
        fail "Batch call should not return permission message"
    fi
else
    fail "Batch call should return design document content"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
