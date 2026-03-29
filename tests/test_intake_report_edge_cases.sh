#!/usr/bin/env bash
# =============================================================================
# test_intake_report_edge_cases.sh — Intake Report edge cases and integration
#
# Tests:
#   1. Missing INTAKE_REPORT.md file handling
#   2. Partial INTAKE_REPORT.md (missing fields)
#   3. Very long task_text truncation (head -5)
#   4. Multiple Tweaked Content sections (only first used)
#   5. Verdict/Confidence with various capitalizations
#   6. Task text with leading/trailing whitespace
#   7. Empty confidence yields 0
#   8. Invalid JSON in INTAKE_REPORT (non-YAML content)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

echo "=== Test Suite: Intake Report Edge Cases ==="

# =============================================================================
# Test 1: Missing INTAKE_REPORT.md
# =============================================================================
echo ""
echo "--- Test 1: Missing file handling ---"

result=$(_parse_intake_report "$TEST_TMPDIR/NONEXISTENT.md")
if [[ "$result" == "null" ]]; then
    pass "1.1 — Missing file returns null"
else
    fail "1.1 — Expected null for missing file, got: $result"
fi

# =============================================================================
# Test 2: Partial INTAKE_REPORT.md (only Verdict, no Confidence or Task)
# =============================================================================
echo ""
echo "--- Test 2: Partial file handling ---"

cat > "$TEST_TMPDIR/INTAKE_PARTIAL.md" << 'EOF'
## Verdict
APPROVED
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_PARTIAL.md")

# Should have verdict but zero confidence and empty task_text
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null || true)
confidence=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confidence',0))" 2>/dev/null || true)
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

if [[ "$verdict" == "APPROVED" ]]; then
    pass "2.1 — Verdict extracted from partial file"
else
    fail "2.1 — Verdict not extracted: '$verdict'"
fi

if [[ "$confidence" == "0" ]]; then
    pass "2.2 — Missing confidence yields 0"
else
    fail "2.2 — Expected confidence=0, got '$confidence'"
fi

if [[ -z "$task_text" ]]; then
    pass "2.3 — Missing Tweaked Content yields empty task_text"
else
    fail "2.3 — Expected empty task_text, got '$task_text'"
fi

# =============================================================================
# Test 3: Very long task_text (should use head -5 for first 5 lines)
# =============================================================================
echo ""
echo "--- Test 3: Long task text handling ---"

cat > "$TEST_TMPDIR/INTAKE_LONG.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
70

## Tweaked Content

Line 1 of task text
Line 2 of task text
Line 3 of task text
Line 4 of task text
Line 5 of task text
Line 6 of task text (should be truncated)
Line 7 of task text (should be truncated)
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_LONG.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

# Should have Lines 1-5 but not 6-7
if [[ "$task_text" == *"Line 5"* ]] && [[ "$task_text" != *"Line 6"* ]]; then
    pass "3.1 — Long task text truncated at 5 lines"
else
    fail "3.1 — Task text not properly truncated: '$task_text'"
fi

# =============================================================================
# Test 4: Multiple Tweaked Content sections (only first should be used)
# =============================================================================
echo ""
echo "--- Test 4: Multiple Tweaked Content sections ---"

cat > "$TEST_TMPDIR/INTAKE_MULTI_TWEAKED.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
60

## Tweaked Content

First tweaked content section

## Some Other Section

Content in between

## Tweaked Content

Second tweaked content section (should be ignored)
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_MULTI_TWEAKED.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

if [[ "$task_text" == *"First tweaked"* ]] && [[ "$task_text" != *"Second tweaked"* ]]; then
    pass "4.1 — Only first Tweaked Content section used"
else
    fail "4.1 — Multiple sections incorrectly processed: '$task_text'"
fi

# =============================================================================
# Test 5: Case variations in headers
# =============================================================================
echo ""
echo "--- Test 5: Case insensitivity ---"

cat > "$TEST_TMPDIR/INTAKE_CASE.md" << 'EOF'
## verdict
PASS

## confidence
85

## tweaked content

Some content here
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_CASE.md")
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null || true)

# Should handle lowercase verdict/confidence
if [[ "$verdict" == "PASS" ]]; then
    pass "5.1 — Lowercase 'verdict' header recognized"
else
    fail "5.1 — Case sensitivity issue: got verdict='$verdict'"
fi

# =============================================================================
# Test 6: Task text with leading/trailing whitespace
# =============================================================================
echo ""
echo "--- Test 6: Whitespace normalization ---"

cat > "$TEST_TMPDIR/INTAKE_WHITESPACE.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
55

## Tweaked Content

   [FEAT] Task with leading spaces

   Line 2 with more spaces
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_WHITESPACE.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

# Should strip leading/trailing whitespace but preserve content
if [[ "$task_text" != *"   "* ]] && [[ "$task_text" == *"FEAT"* ]]; then
    pass "6.1 — Leading/trailing whitespace stripped"
else
    fail "6.1 — Whitespace not properly handled: '$task_text'"
fi

# =============================================================================
# Test 7: Verdict with extra whitespace/punctuation
# =============================================================================
echo ""
echo "--- Test 7: Verdict parsing with formatting ---"

cat > "$TEST_TMPDIR/INTAKE_VERDICT_PUNCT.md" << 'EOF'
## Verdict:  CONDITIONAL_PASS
## Confidence: 72
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_VERDICT_PUNCT.md")
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null || true)

# Should preserve verdict value even with whitespace
if [[ "$verdict" == "CONDITIONAL_PASS" ]]; then
    pass "7.1 — Verdict extracted with whitespace trimmed"
else
    fail "7.1 — Verdict extraction failed: '$verdict'"
fi

# =============================================================================
# Test 8: Task text extraction from ### Acceptance Criteria section
# =============================================================================
echo ""
echo "--- Test 8: Extraction stops at ### subsection ---"

cat > "$TEST_TMPDIR/INTAKE_SUBSECTIONS.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
65

## Tweaked Content

[FEAT] Main feature description

### Acceptance Criteria
This content should not be included
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_SUBSECTIONS.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

if [[ "$task_text" == *"Main feature"* ]] && [[ "$task_text" != *"Acceptance"* ]]; then
    pass "8.1 — Extraction stops at ### subsection"
else
    fail "8.1 — Subsection content included: '$task_text'"
fi

# =============================================================================
# Test 9: Empty lines in task text are removed
# =============================================================================
echo ""
echo "--- Test 9: Empty line removal ---"

cat > "$TEST_TMPDIR/INTAKE_EMPTY_LINES.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
50

## Tweaked Content

[FEAT] First line

[and second line with blank before it]
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_EMPTY_LINES.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

# Should collapse multiple lines with blank lines removed
if [[ "$task_text" == "[FEAT] First line [and second"* ]]; then
    pass "9.1 — Empty lines removed from task text"
else
    fail "9.1 — Empty lines not properly handled: '$task_text'"
fi

# =============================================================================
# Test 10: renderIntakeBody integration test (simulated)
# =============================================================================
echo ""
echo "--- Test 10: Integration simulation ---"

# Create sample report data and verify it can be used by app.js
cat > "$TEST_TMPDIR/INTAKE_INTEGRATION.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
62

## Tweaked Content

[FEAT] The "Intake Report" section of the Reports page currently shows only Verdict and Confidence. It should also display the original milestone/task text that was evaluated, and include a link to the full milestone entry in the Milestone Map page.
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_INTEGRATION.md")

# Verify it produces valid JSON
if echo "$result" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    pass "10.1 — Real-world INTAKE_REPORT.md produces valid JSON"
else
    fail "10.1 — JSON production failed"
fi

# Verify all fields exist and have content
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null || true)
confidence=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confidence',0))" 2>/dev/null || true)
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

if [[ -n "$verdict" ]] && [[ "$confidence" != "0" ]] && [[ -n "$task_text" ]]; then
    pass "10.2 — All fields populated in real-world example"
else
    fail "10.2 — Missing fields: verdict='$verdict', confidence='$confidence', task_text='$task_text'"
fi

if [[ "$task_text" == *"Reports page"* ]] && [[ "$task_text" == *"Milestone Map"* ]]; then
    pass "10.3 — Task text contains expected content"
else
    fail "10.3 — Task text missing expected phrases"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

exit 0
