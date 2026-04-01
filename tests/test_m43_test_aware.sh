#!/usr/bin/env bash
# Test: M43 — Test-aware coding: scout report extraction, template rendering
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { echo "=== $* ==="; }

RED="" CYAN="" YELLOW="" NC=""

# --------------------------------------------------------------------------
echo "Suite 1: Affected Test Files extraction from scout report"
# --------------------------------------------------------------------------

# Helper: extract affected test files using the same awk logic as coder.sh.
# NOTE: This duplicates inline logic from stages/coder.sh (around line 325-336).
# Source of truth is coder.sh — if that logic changes, update this helper too.
# Sourcing coder.sh directly is impractical due to its heavy dependency chain.
_extract_affected_test_files() {
    local report_file="$1"
    local result
    result=$(awk '
        /^## Affected Test Files/{found=1; next}
        found && /^## /{exit}
        found{print}
    ' "$report_file" | sed '/^[[:space:]]*$/d')
    # Suppress if scout wrote "None identified"
    if [[ "$result" == *"None identified"* ]]; then
        result=""
    fi
    printf '%s' "$result"
}

# Test: report with affected test files section
cat > "${TEST_TMPDIR}/scout_report.md" <<'EOF'
## Relevant Files
- lib/foo.sh — main logic

## Key Symbols
- validate_config — lib/foo.sh

## Suspected Root Cause Areas
- lib/foo.sh:validate_config function

## Affected Test Files
- tests/test_foo.sh — tests functions in lib/foo.sh (naming convention)
- tests/test_bar.sh — calls validate_config() which is modified (cross-reference)

## Complexity Estimate
Files to modify: 2
Estimated lines of change: 50
Interconnected systems: low
Recommended coder turns: 25
Recommended reviewer turns: 8
Recommended tester turns: 20
EOF

result=$(_extract_affected_test_files "${TEST_TMPDIR}/scout_report.md")
if echo "$result" | grep -q "tests/test_foo.sh"; then
    pass "Extracts test_foo.sh from Affected Test Files section"
else
    fail "Should extract test_foo.sh (got: $result)"
fi

if echo "$result" | grep -q "tests/test_bar.sh"; then
    pass "Extracts test_bar.sh from Affected Test Files section"
else
    fail "Should extract test_bar.sh (got: $result)"
fi

# Verify it does not include content from other sections
if echo "$result" | grep -q "lib/foo.sh — main logic"; then
    fail "Should not include Relevant Files content"
else
    pass "Does not leak content from Relevant Files section"
fi

if echo "$result" | grep -q "Files to modify"; then
    fail "Should not include Complexity Estimate content"
else
    pass "Does not leak content from Complexity Estimate section"
fi

# Test: report without affected test files section (graceful)
cat > "${TEST_TMPDIR}/scout_report_no_tests.md" <<'EOF'
## Relevant Files
- lib/foo.sh — main logic

## Key Symbols
- validate_config — lib/foo.sh

## Suspected Root Cause Areas
- lib/foo.sh

## Complexity Estimate
Files to modify: 1
Estimated lines of change: 10
Interconnected systems: low
Recommended coder turns: 15
Recommended reviewer turns: 5
Recommended tester turns: 15
EOF

result=$(_extract_affected_test_files "${TEST_TMPDIR}/scout_report_no_tests.md")
if [[ -z "$result" ]]; then
    pass "Empty result when Affected Test Files section absent"
else
    fail "Should be empty when section absent (got: $result)"
fi

# Test: report with "None identified" in section
cat > "${TEST_TMPDIR}/scout_report_none.md" <<'EOF'
## Affected Test Files
None identified

## Complexity Estimate
Files to modify: 1
EOF

result=$(_extract_affected_test_files "${TEST_TMPDIR}/scout_report_none.md")
if [[ -z "$result" ]]; then
    pass "Empty result when section says 'None identified'"
else
    fail "Should be empty when 'None identified' (got: $result)"
fi

# --------------------------------------------------------------------------
echo "Suite 2: Test baseline summary generation"
# --------------------------------------------------------------------------

# Simulate baseline JSON parsing (same logic as coder.sh).
# NOTE: This duplicates inline logic from stages/coder.sh (around line 344-358).
# Source of truth is coder.sh — if that logic changes, update this helper too.
_build_test_baseline_summary() {
    local baseline_json="$1"
    local exit_code failures summary=""
    exit_code=$(grep -oP '"exit_code"\s*:\s*\K[0-9]+' "$baseline_json" 2>/dev/null || echo "")
    failures=$(grep -oP '"failure_count"\s*:\s*\K[0-9]+' "$baseline_json" 2>/dev/null || echo "0")
    if [[ -n "$exit_code" ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            summary="All tests passed before your changes (exit code 0, 0 failures)."
        else
            summary="Tests had ${failures} pre-existing failure(s) before your changes (exit code ${exit_code}). These are NOT caused by your work."
        fi
    fi
    printf '%s' "$summary"
}

# Test: passing baseline
cat > "${TEST_TMPDIR}/baseline_pass.json" <<'EOF'
{
  "timestamp": "2026-03-30T10:00:00Z",
  "milestone": "43",
  "exit_code": 0,
  "output_hash": "abc123",
  "failure_hash": "def456",
  "failure_count": 0
}
EOF

result=$(_build_test_baseline_summary "${TEST_TMPDIR}/baseline_pass.json")
if [[ "$result" == *"All tests passed"* ]]; then
    pass "Passing baseline produces correct summary"
else
    fail "Should say 'All tests passed' (got: $result)"
fi

# Test: failing baseline
cat > "${TEST_TMPDIR}/baseline_fail.json" <<'EOF'
{
  "timestamp": "2026-03-30T10:00:00Z",
  "milestone": "43",
  "exit_code": 1,
  "output_hash": "abc123",
  "failure_hash": "def456",
  "failure_count": 3
}
EOF

result=$(_build_test_baseline_summary "${TEST_TMPDIR}/baseline_fail.json")
if [[ "$result" == *"3 pre-existing failure(s)"* ]]; then
    pass "Failing baseline includes failure count"
else
    fail "Should mention 3 pre-existing failures (got: $result)"
fi

if [[ "$result" == *"NOT caused by your work"* ]]; then
    pass "Failing baseline includes reassurance message"
else
    fail "Should say 'NOT caused by your work' (got: $result)"
fi

# Test: missing baseline file
result=$(_build_test_baseline_summary "${TEST_TMPDIR}/nonexistent.json")
if [[ -z "$result" ]]; then
    pass "Empty summary when baseline file missing"
else
    fail "Should be empty when file missing (got: $result)"
fi

# --------------------------------------------------------------------------
echo "Suite 3: Template conditional blocks"
# --------------------------------------------------------------------------

# Source prompts.sh to test render_prompt
export PROMPTS_DIR="${TEKHTON_HOME}/prompts"

# Test: coder.prompt.md includes AFFECTED_TEST_FILES conditional
if grep -q '{{IF:AFFECTED_TEST_FILES}}' "${PROMPTS_DIR}/coder.prompt.md"; then
    pass "coder.prompt.md has AFFECTED_TEST_FILES conditional"
else
    fail "coder.prompt.md should have AFFECTED_TEST_FILES conditional"
fi

if grep -q '{{IF:TEST_BASELINE_SUMMARY}}' "${PROMPTS_DIR}/coder.prompt.md"; then
    pass "coder.prompt.md has TEST_BASELINE_SUMMARY conditional"
else
    fail "coder.prompt.md should have TEST_BASELINE_SUMMARY conditional"
fi

# Test: scout.prompt.md includes Affected Test Files in output format
if grep -q '## Affected Test Files' "${PROMPTS_DIR}/scout.prompt.md"; then
    pass "scout.prompt.md includes Affected Test Files section in output format"
else
    fail "scout.prompt.md should include Affected Test Files section"
fi

# Test: tester.prompt.md updated rule
if grep -q 'intentional API/behavior changes' "${PROMPTS_DIR}/tester.prompt.md"; then
    pass "tester.prompt.md has updated intentional API change rule"
else
    fail "tester.prompt.md should have updated rule for intentional API changes"
fi

if grep -q 'REPORT THE BUG.*do not fix the test' "${PROMPTS_DIR}/tester.prompt.md"; then
    fail "tester.prompt.md still has old blanket 'report the bug' rule"
else
    pass "tester.prompt.md old blanket rule replaced"
fi

# Test: coder.prompt.md has test maintenance section
if grep -q '## Test Maintenance (mandatory)' "${PROMPTS_DIR}/coder.prompt.md"; then
    pass "coder.prompt.md has Test Maintenance section"
else
    fail "coder.prompt.md should have Test Maintenance section"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
