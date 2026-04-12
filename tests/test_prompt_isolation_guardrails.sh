#!/usr/bin/env bash
set -euo pipefail

# Test: Verify test isolation guardrails in tester and audit prompts
# These guardrails prevent state-dependent, flaky tests by requiring fixture isolation.

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper
assert_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if grep -q "$pattern" "$file"; then
        echo "PASS: $description"
        ((TESTS_PASSED++)) || return 0
    else
        echo "FAIL: $description"
        echo "  File: $file"
        echo "  Pattern not found: $pattern"
        ((TESTS_FAILED++)) || return 0
    fi
}

# Test helper for line content
assert_line_contains() {
    local file="$1"
    local line_pattern="$2"
    local content_pattern="$3"
    local description="$4"

    if grep "$line_pattern" "$file" | grep -q "$content_pattern"; then
        echo "PASS: $description"
        ((TESTS_PASSED++)) || return 0
    else
        echo "FAIL: $description"
        echo "  File: $file"
        echo "  Line pattern: $line_pattern"
        echo "  Content pattern not found: $content_pattern"
        ((TESTS_FAILED++)) || return 0
    fi
}

# Test 1: Tester prompt has "CRITICAL: Test Integrity Rules" section
assert_contains \
    "prompts/tester.prompt.md" \
    "^## CRITICAL: Test Integrity Rules" \
    "Tester prompt has CRITICAL: Test Integrity Rules section"

# Test 2: Tester prompt includes isolation rule about not reading live repo files
assert_contains \
    "prompts/tester.prompt.md" \
    "NEVER read live repo artifact files" \
    "Tester prompt warns against reading live repo artifact files"

# Test 3: Tester prompt specifies which files NOT to read (build reports, logs, etc)
assert_contains \
    "prompts/tester.prompt.md" \
    "build reports, logs, pipeline state" \
    "Tester prompt lists specific mutable files to avoid"

# Test 4: Tester prompt requires controlled fixtures in temp directory
assert_contains \
    "prompts/tester.prompt.md" \
    "Always create controlled fixtures in a temp" \
    "Tester prompt requires fixtures in temp directories"

# Test 5: Tester prompt states tests must be deterministic
assert_contains \
    "prompts/tester.prompt.md" \
    "Tests must be deterministic" \
    "Tester prompt emphasizes deterministic tests"

# Test 6: Tester prompt clarifies pipeline outcome tests belong in commit messages
assert_contains \
    "prompts/tester.prompt.md" \
    "Tests that validate specific run outcomes" \
    "Tester prompt clarifies where pipeline outcome tests belong"

# Test 7: Audit prompt has Six/Seven-Point (or just) "Audit Rubric" section
assert_contains \
    "prompts/test_audit.prompt.md" \
    "## .*Audit Rubric" \
    "Audit prompt has an Audit Rubric section"

# Test 8: Audit prompt has section 7 for Test Isolation
assert_line_contains \
    "prompts/test_audit.prompt.md" \
    "^### 7. Test Isolation" \
    "Test Isolation" \
    "Audit prompt has Section 7: Test Isolation"

# Test 9: Section 7 flags tests reading live files without fixtures
assert_contains \
    "prompts/test_audit.prompt.md" \
    "FLAG: Tests that read live build reports, pipeline logs, config state files" \
    "Audit Section 7 flags tests reading live artifact files"

# Test 10: Section 7 flags order-dependent tests
assert_contains \
    "prompts/test_audit.prompt.md" \
    "Tests whose pass/fail outcome depends on prior pipeline runs or repo state" \
    "Audit Section 7 flags order-dependent tests"

# Test 11: Section 7 defines good test isolation practice
assert_contains \
    "prompts/test_audit.prompt.md" \
    "Tests that create their own fixture data in a temp directory" \
    "Audit Section 7 defines good isolation practice"

# Test 12: Section 7 marks isolation violations as HIGH severity
assert_contains \
    "prompts/test_audit.prompt.md" \
    "Severity: HIGH" \
    "Audit Section 7 marks isolation violations as HIGH severity"

# Test 13: Verify mutable project files are specifically listed
assert_contains \
    "prompts/test_audit.prompt.md" \
    "CODER_SUMMARY_FILE.*REVIEWER_REPORT_FILE.*BUILD_ERRORS_FILE" \
    "Audit Section 7 lists example mutable project files"

# Test 14: Verify isolation is listed as a category in the output rules
assert_contains \
    "prompts/test_audit.prompt.md" \
    "Categories:.*ISOLATION" \
    "Audit finding categories include ISOLATION"

# Test 15: Verify context for audit includes test_audit section markers
assert_contains \
    "prompts/test_audit.prompt.md" \
    "TEST_AUDIT_CONTEXT" \
    "Audit prompt references TEST_AUDIT_CONTEXT for file listing"

# Summary
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "=========================================="

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed!"
    exit 1
fi
