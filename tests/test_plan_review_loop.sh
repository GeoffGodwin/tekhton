#!/usr/bin/env bash
# Test: Planning phase milestone review loop
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_TEST_MODE=1
TEST_PROJECT_DIR="/tmp/tekhton_review_loop_test"
export PROJECT_DIR="$TEST_PROJECT_DIR"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Setup and cleanup
setup() {
    mkdir -p "$PROJECT_DIR"
}

cleanup() {
    rm -rf "$PROJECT_DIR"
}

trap cleanup EXIT

# Create a sample CLAUDE.md for testing
create_claude_md() {
    cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# Test Project

## Milestone 1: Setup Database
## Milestone 2: Implement API
## Milestone 3: Add Tests
EOF
}

# Create a sample DESIGN.md for testing
create_design_md() {
    cat > "$PROJECT_DIR/DESIGN.md" << 'EOF'
# Test Project Design

## Overview
This is a test project.

## Requirements
- Database setup
- API endpoints
- Test coverage
EOF
}

# Mock run_plan_generate for testing [r] option
mock_run_plan_generate() {
    log "Mock: run_plan_generate would be called here"
    return 0
}

# Helper: Run run_plan_review() with piped input
# Returns the exit code and captures output
run_review_with_input() {
    local input="$1"
    local output
    output=$(printf '%s\n' "$input" | bash -c '
        TEKHTON_HOME="'"${TEKHTON_HOME}"'"
        TEST_PROJECT_DIR="'"${TEST_PROJECT_DIR}"'"
        PROJECT_DIR="$TEST_PROJECT_DIR"
        export TEKHTON_HOME PROJECT_DIR TEKHTON_TEST_MODE=1
        source "${TEKHTON_HOME}/lib/common.sh"
        source "${TEKHTON_HOME}/lib/plan.sh"

        # Mock run_plan_generate for [r] option testing
        run_plan_generate() {
            log "Mock: run_plan_generate would be called here"
            return 0
        }

        run_plan_review 2>&1
    ')
    local exit_code=$?
    echo "===EXIT_CODE:${exit_code}==="
    echo "$output"
}

setup
create_claude_md
create_design_md

echo "=== Test [y] Accept Choice ==="

# Test: [y] should accept and return 0
output=$(run_review_with_input "y")
exit_code=$(echo "$output" | grep "===EXIT_CODE:" | sed 's/.*===EXIT_CODE://' | sed 's/===.*//')

if [ "$exit_code" = "0" ]; then
    pass "[y] choice returns exit code 0"
else
    fail "[y] choice: expected exit code 0, got $exit_code"
fi

if echo "$output" | grep -q "Files confirmed at"; then
    pass "[y] choice prints success message"
else
    fail "[y] choice missing success message"
fi

if echo "$output" | grep -q "Next steps:"; then
    pass "[y] choice prints next steps"
else
    fail "[y] choice missing next steps"
fi

echo
echo "=== Test [n] Abort Choice ==="

# Test: [n] should abort and return 1
output=$(run_review_with_input "n")
exit_code=$(echo "$output" | grep "===EXIT_CODE:" | sed 's/.*===EXIT_CODE://' | sed 's/===.*//')

if [ "$exit_code" != "0" ]; then
    pass "[n] choice returns non-zero exit code"
else
    fail "[n] choice: expected non-zero exit code, got $exit_code"
fi

if echo "$output" | grep -q "Aborted"; then
    pass "[n] choice prints abort message"
else
    fail "[n] choice missing abort message"
fi

if echo "$output" | grep -q "DESIGN.md is preserved"; then
    pass "[n] choice mentions preserved DESIGN.md"
else
    fail "[n] choice doesn't mention preserved files"
fi

echo
echo "=== Test Invalid Then Valid Input ==="

# Test: Invalid choice followed by valid choice
output=$(run_review_with_input $'invalid\ny')
exit_code=$(echo "$output" | grep "===EXIT_CODE:" | sed 's/.*===EXIT_CODE://' | sed 's/===.*//')

if [ "$exit_code" = "0" ]; then
    pass "Invalid then [y] eventually returns 0"
else
    fail "Invalid then [y]: expected exit code 0, got $exit_code"
fi

if echo "$output" | grep -q "Invalid choice"; then
    pass "Invalid input produces warning message"
else
    fail "Invalid input should warn about invalid choice"
fi

echo
echo "=== Test Case Insensitivity ==="

# Test: Uppercase Y should work
output=$(run_review_with_input "Y")
exit_code=$(echo "$output" | grep "===EXIT_CODE:" | sed 's/.*===EXIT_CODE://' | sed 's/===.*//')

if [ "$exit_code" = "0" ]; then
    pass "Uppercase [Y] returns exit code 0"
else
    fail "Uppercase [Y]: expected exit code 0, got $exit_code"
fi

# Test: Lowercase n should work
output=$(run_review_with_input "n")
exit_code=$(echo "$output" | grep "===EXIT_CODE:" | sed 's/.*===EXIT_CODE://' | sed 's/===.*//')

if [ "$exit_code" != "0" ]; then
    pass "Lowercase [n] returns non-zero exit code"
else
    fail "Lowercase [n]: expected non-zero exit code"
fi

echo
echo "=== Test Missing CLAUDE.md ==="

# Remove CLAUDE.md to test error handling
rm -f "$PROJECT_DIR/CLAUDE.md"

output=$(run_review_with_input "y")
exit_code=$(echo "$output" | grep "===EXIT_CODE:" | sed 's/.*===EXIT_CODE://' | sed 's/===.*//')

if [ "$exit_code" != "0" ]; then
    pass "Missing CLAUDE.md returns error code"
else
    fail "Missing CLAUDE.md should return error"
fi

if echo "$output" | grep -q "CLAUDE.md not found"; then
    pass "Missing CLAUDE.md shows appropriate error"
else
    fail "Missing CLAUDE.md error message not found"
fi

echo
echo "=== Test [r] Re-generate Choice ==="

# Recreate CLAUDE.md
create_claude_md

# For the [r] test, we need to mock run_plan_generate
# Run with [r] followed by [y] to test the re-generate path
output=$(run_review_with_input $'r\ny')
exit_code=$(echo "$output" | grep "===EXIT_CODE:" | sed 's/.*===EXIT_CODE://' | sed 's/===.*//')

if [ "$exit_code" = "0" ]; then
    pass "[r] then [y] eventually accepts"
else
    fail "[r] then [y]: expected exit code 0, got $exit_code"
fi

if echo "$output" | grep -q "Re-generating CLAUDE.md"; then
    pass "[r] choice shows re-generation message"
else
    fail "[r] choice missing re-generation message"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
