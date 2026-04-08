#!/usr/bin/env bash
# Test: plan_answers.sh — YAML escape/unescape and answer file operations
# Tests the fix for double-quote escaping in answer templates
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
export TEKHTON_VERSION="3.65.0"
export PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"

# Source libraries
source "${TEKHTON_HOME}/lib/plan_answers.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

echo "=== Testing YAML Escape/Unescape (_yaml_escape_dq, _yaml_unescape_dq) ==="

# Test 1: Simple string without special chars
test_str="hello world"
escaped=$(_yaml_escape_dq "$test_str")
unescaped=$(_yaml_unescape_dq "$escaped")
if [[ "$unescaped" == "$test_str" ]]; then
    pass "Simple string round-trip"
else
    fail "Simple string round-trip: expected '$test_str', got '$unescaped'"
fi

# Test 2: String with double quotes
test_str='say "hello"'
escaped=$(_yaml_escape_dq "$test_str")
unescaped=$(_yaml_unescape_dq "$escaped")
if [[ "$unescaped" == "$test_str" ]]; then
    pass "String with double quotes round-trip"
else
    fail "String with double quotes: expected '$test_str', got '$unescaped'"
fi

# Test 3: String with backslashes
test_str='path\to\file'
escaped=$(_yaml_escape_dq "$test_str")
unescaped=$(_yaml_unescape_dq "$escaped")
if [[ "$unescaped" == "$test_str" ]]; then
    pass "String with backslashes round-trip"
else
    fail "String with backslashes: expected '$test_str', got '$unescaped'"
fi

# Test 4: String with both quotes and backslashes
test_str='C:\path\to\"file\"'
escaped=$(_yaml_escape_dq "$test_str")
unescaped=$(_yaml_unescape_dq "$escaped")
if [[ "$unescaped" == "$test_str" ]]; then
    pass "String with quotes and backslashes round-trip"
else
    fail "String with quotes and backslashes: expected '$test_str', got '$unescaped'"
fi

# Test 5: Empty string
test_str=""
escaped=$(_yaml_escape_dq "$test_str")
unescaped=$(_yaml_unescape_dq "$escaped")
if [[ "$unescaped" == "$test_str" ]]; then
    pass "Empty string round-trip"
else
    fail "Empty string: expected '$test_str', got '$unescaped'"
fi

# Test 6: Multiple consecutive quotes
test_str='""""'
escaped=$(_yaml_escape_dq "$test_str")
unescaped=$(_yaml_unescape_dq "$escaped")
if [[ "$unescaped" == "$test_str" ]]; then
    pass "Multiple consecutive quotes round-trip"
else
    fail "Multiple consecutive quotes: expected '$test_str', got '$unescaped'"
fi

# Test 7: Multiple consecutive backslashes
test_str='\\\\'
escaped=$(_yaml_escape_dq "$test_str")
unescaped=$(_yaml_unescape_dq "$escaped")
if [[ "$unescaped" == "$test_str" ]]; then
    pass "Multiple consecutive backslashes round-trip"
else
    fail "Multiple consecutive backslashes: expected '$test_str', got '$unescaped'"
fi

echo
echo "=== Testing Answer File Initialization (init_answer_file) ==="

# Create a test template
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

## Configuration
<!-- PHASE:3 -->
<!-- What config? -->
TMPL

# Initialize answer file
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true

# Test that file was created
if [[ -f "$PLAN_ANSWER_FILE" ]]; then
    pass "Answer file created at ${PLAN_ANSWER_FILE}"
else
    fail "Answer file not created"
fi

# Test file header
if head -1 "$PLAN_ANSWER_FILE" 2>/dev/null | grep -q '^# Tekhton Planning Answers'; then
    pass "Answer file has correct header"
else
    fail "Answer file header incorrect"
fi

# Test sections block exists
if grep -q '^sections:' "$PLAN_ANSWER_FILE"; then
    pass "Answer file has sections block"
else
    fail "Answer file missing sections block"
fi

echo "=== Testing Section Names with Special Characters ==="

TEST_TEMPLATE2="${TEST_TMP}/test_template2.md"
cat > "$TEST_TEMPLATE2" << 'TMPL'
# Test Design

## Section with "Quotes" & Special
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Guidance about "quotes" -->

## Another Section
<!-- Guidance -->
TMPL

# Set PLAN_ANSWER_FILE BEFORE calling init_answer_file
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers2.yaml"
init_answer_file "test2" "$TEST_TEMPLATE2" 2>/dev/null || true

if [[ -f "$PLAN_ANSWER_FILE" ]]; then
    pass "Answer file created with special section names"

    # Verify escaped quotes in title field
    if grep -q 'title:.*\\\"' "$PLAN_ANSWER_FILE"; then
        pass "Special characters in section names are escaped"
    else
        fail "Section names with special chars not properly escaped"
    fi
else
    fail "Answer file with special section names not created"
fi

echo
echo "=== Testing Answer Save/Load Round-Trip ==="

# Reset answer file for save/load tests
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true

# Test 1: Simple answer save and load
simple_answer="This is a simple answer"
save_answer "overview" "$simple_answer" 2>/dev/null || true
loaded=$(_parse_answer_field "$PLAN_ANSWER_FILE" "overview" 2>/dev/null)

if [[ "$loaded" == "$simple_answer" ]]; then
    pass "Simple answer save and load round-trip"
else
    fail "Simple answer round-trip: expected '$simple_answer', got '$loaded'"
fi

# Test 2: Answer with quotes
quoted_answer='He said "hello world"'
save_answer "architecture" "$quoted_answer" 2>/dev/null || true
loaded=$(_parse_answer_field "$PLAN_ANSWER_FILE" "architecture" 2>/dev/null)

if [[ "$loaded" == "$quoted_answer" ]]; then
    pass "Answer with quotes save and load round-trip"
else
    fail "Answer with quotes: expected '$quoted_answer', got '$loaded'"
fi

# Test 3: Multi-line answer (block scalar)
multiline_answer="Line 1
Line 2
Line 3"
save_answer "configuration" "$multiline_answer" 2>/dev/null || true
loaded=$(_parse_answer_field "$PLAN_ANSWER_FILE" "configuration" 2>/dev/null)

if [[ "$loaded" == "$multiline_answer" ]]; then
    pass "Multi-line answer save and load round-trip"
else
    fail "Multi-line answer: expected '$multiline_answer', got '$loaded'"
fi

echo
echo "=== Testing load_all_answers Function ==="

# Verify load_all_answers correctly unescapes values
all_answers=$(load_all_answers)

# Count loaded answers (should have 3 sections)
line_count=$(echo "$all_answers" | wc -l | tr -d ' ')
if [[ "$line_count" -ge 3 ]]; then
    pass "load_all_answers returns multiple sections ($line_count)"
else
    fail "load_all_answers returned fewer sections than expected"
fi

# Verify pipe-separated format (5 fields: id|title|phase|required|answer)
first_line=$(echo "$all_answers" | head -1)
field_count=$(echo "$first_line" | awk -F'|' '{print NF}')
if [[ "$field_count" -eq 5 ]]; then
    pass "load_all_answers outputs 5-field format"
else
    fail "load_all_answers: expected 5 fields, got $field_count in '$first_line'"
fi

echo
echo "=== Testing export_question_template Function ==="

export_path="${TEST_TMP}/export_test.yaml"
export_question_template "$TEST_TEMPLATE" "$export_path" 2>/dev/null || true

if [[ -f "$export_path" ]]; then
    pass "export_question_template creates output file"

    # Verify header
    if head -1 "$export_path" | grep -q '^# Tekhton Planning Answers'; then
        pass "Exported template has correct header"
    else
        fail "Exported template header incorrect"
    fi

    # Verify sections block
    if grep -q '^sections:' "$export_path"; then
        pass "Exported template has sections block"
    else
        fail "Exported template missing sections block"
    fi
else
    fail "export_question_template did not create output file"
fi

echo
echo "=== Testing has_answer_file Function ==="

# Test with existing file
if has_answer_file; then
    pass "has_answer_file returns 0 for valid file"
else
    fail "has_answer_file should return 0 for valid file"
fi

# Test with non-existent file
PLAN_ANSWER_FILE="${TEST_TMP}/.claude/nonexistent.yaml"
if ! has_answer_file; then
    pass "has_answer_file returns 1 for missing file"
else
    fail "has_answer_file should return 1 for missing file"
fi

echo
echo "=== Testing answer_file_complete Function ==="

# Reset to a file with some answered sections
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true

# File should be incomplete (no answers yet)
if ! answer_file_complete; then
    pass "answer_file_complete returns 1 for unanswered required sections"
else
    fail "answer_file_complete should return 1 when required answers missing"
fi

# Add answers to required sections
save_answer "overview" "Test overview" 2>/dev/null || true
save_answer "architecture" "Test architecture" 2>/dev/null || true

# Now it should be complete (all required sections answered)
if answer_file_complete; then
    pass "answer_file_complete returns 0 when all required sections answered"
else
    fail "answer_file_complete should return 0 when all required sections answered"
fi

echo
echo "=== Testing Edge Cases ==="

# Test 1: Section name with many special characters
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"
TEST_TEMPLATE3="${TEST_TMP}/test_template3.md"
cat > "$TEST_TEMPLATE3" << 'TMPL'
# Test Design

## Developer Philosophy & Constraints (v1.0, "Best Practices")
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Guidance: Use "quotes" carefully! -->
TMPL

init_answer_file "test3" "$TEST_TEMPLATE3" 2>/dev/null || true

if [[ -f "$PLAN_ANSWER_FILE" ]]; then
    # Verify the escaped section is in the file
    if grep -q "Developer Philosophy" "$PLAN_ANSWER_FILE"; then
        pass "Section with complex special characters handled"
    else
        fail "Section with complex special characters not found"
    fi
else
    fail "Answer file for complex section names not created"
fi

# Test 2: Answer with newlines, quotes, and special YAML chars
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers.yaml"
init_answer_file "test" "$TEST_TEMPLATE" 2>/dev/null || true

complex_answer='- Use "quotes" carefully
- Backslash: \
- Colon: :
- Hash: #'

save_answer "overview" "$complex_answer" 2>/dev/null || true
loaded=$(_parse_answer_field "$PLAN_ANSWER_FILE" "overview" 2>/dev/null)

if [[ "$loaded" == "$complex_answer" ]]; then
    pass "Complex answer with quotes, newlines, special YAML chars round-trip"
else
    fail "Complex answer round-trip failed"
fi

echo
echo "=== Testing Web Mode Integration ==="

# Web mode uses init_answer_file and save_answer - test they work together
PLAN_ANSWER_FILE="${PROJECT_DIR}/.claude/plan_answers_web.yaml"
TEST_TEMPLATE_WEB="${TEST_TMP}/test_template_web.md"
cat > "$TEST_TEMPLATE_WEB" << 'TMPL'
# Web Test Design

## First Section
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Initial guidance -->

## Second Section
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- More guidance with "quotes" -->
TMPL

# Simulate web mode flow: init → save → load
init_answer_file "web_test" "$TEST_TEMPLATE_WEB" 2>/dev/null || true

if [[ ! -f "$PLAN_ANSWER_FILE" ]]; then
    fail "Web mode: answer file not created"
else
    # Save answers as web form would do
    web_answer1='Web mode answer with "quotes"'
    web_answer2='Another answer: part 2'

    save_answer "first_section" "$web_answer1" 2>/dev/null || true
    save_answer "second_section" "$web_answer2" 2>/dev/null || true

    loaded1=$(_parse_answer_field "$PLAN_ANSWER_FILE" "first_section" 2>/dev/null)
    loaded2=$(_parse_answer_field "$PLAN_ANSWER_FILE" "second_section" 2>/dev/null)

    if [[ "$loaded1" == "$web_answer1" ]]; then
        pass "Web mode: first answer loaded correctly"
    else
        fail "Web mode: first answer mismatch"
    fi

    if [[ "$loaded2" == "$web_answer2" ]]; then
        pass "Web mode: second answer loaded correctly"
    else
        fail "Web mode: second answer mismatch"
    fi
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
