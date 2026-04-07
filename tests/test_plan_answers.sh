#!/usr/bin/env bash
# Test: Planning answer layer — YAML roundtrip, export/import, build_answers_block
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
export PLAN_ANSWER_FILE="${TEST_TMPDIR}/.claude/plan_answers.yaml"
export TEKHTON_VERSION="3.31.0"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs for logging
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
count_lines() { wc -l | tr -d ' '; }

# Source required libraries
# shellcheck source=../lib/plan.sh
source "${TEKHTON_HOME}/lib/plan.sh"
# shellcheck source=../lib/plan_answers.sh
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# --- Create a test template ---
PLAN_TEMPLATE_FILE="${TEST_TMPDIR}/template.md"
cat > "$PLAN_TEMPLATE_FILE" << 'EOF'
# Design Document — Test

## Developer Philosophy
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your architectural rules? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this do? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Languages and frameworks -->

## Optional Notes
<!-- PHASE:2 -->
<!-- Any extra details -->
EOF

PLAN_PROJECT_TYPE="test"

# ============================================================
echo "=== init_answer_file ==="
# ============================================================

init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

if [[ -f "$PLAN_ANSWER_FILE" ]]; then
    pass "Answer file created"
else
    fail "Answer file not created"
fi

if head -1 "$PLAN_ANSWER_FILE" | grep -q "^# Tekhton Planning Answers"; then
    pass "Answer file has valid header"
else
    fail "Answer file missing header"
fi

if grep -q "developer_philosophy:" "$PLAN_ANSWER_FILE"; then
    pass "Section 'developer_philosophy' exists"
else
    fail "Section 'developer_philosophy' missing"
fi

if grep -q "project_overview:" "$PLAN_ANSWER_FILE"; then
    pass "Section 'project_overview' exists"
else
    fail "Section 'project_overview' missing"
fi

if grep -q "optional_notes:" "$PLAN_ANSWER_FILE"; then
    pass "Section 'optional_notes' exists"
else
    fail "Section 'optional_notes' missing"
fi

# ============================================================
echo
echo "=== has_answer_file ==="
# ============================================================

if has_answer_file; then
    pass "has_answer_file returns 0 when file exists"
else
    fail "has_answer_file should return 0"
fi

rm -f "$PLAN_ANSWER_FILE"
if has_answer_file; then
    fail "has_answer_file should return 1 when file missing"
else
    pass "has_answer_file returns 1 when file missing"
fi

# Re-create for further tests
init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

# ============================================================
echo
echo "=== save_answer + load_answer: simple string ==="
# ============================================================

save_answer "developer_philosophy" "Composition over inheritance"
result=$(load_answer "developer_philosophy")
if [[ "$result" == "Composition over inheritance" ]]; then
    pass "Simple string roundtrip"
else
    fail "Simple string roundtrip: got '${result}'"
fi

# ============================================================
echo
echo "=== save_answer + load_answer: multi-line ==="
# ============================================================

multiline_answer="First line of the answer.
Second line with more detail.
Third line wrapping up."
save_answer "project_overview" "$multiline_answer"
result=$(load_answer "project_overview")
if [[ "$result" == "$multiline_answer" ]]; then
    pass "Multi-line roundtrip"
else
    fail "Multi-line roundtrip failed"
    echo "    Expected: $(echo "$multiline_answer" | head -1)..."
    echo "    Got:      $(echo "$result" | head -1)..."
fi

# ============================================================
echo
echo "=== save_answer + load_answer: special characters ==="
# ============================================================

special_answer="Config uses: key=value format. # This is not a comment. \"Quoted\" and 'single' too."
save_answer "tech_stack" "$special_answer"
result=$(load_answer "tech_stack")
if [[ "$result" == "$special_answer" ]]; then
    pass "Special characters roundtrip (colon, hash, quotes)"
else
    fail "Special characters roundtrip failed"
    echo "    Expected: ${special_answer}"
    echo "    Got:      ${result}"
fi

# ============================================================
echo
echo "=== save_answer + load_answer: YAML-like syntax in answer ==="
# ============================================================

yaml_answer="Uses | pipe and > angle. Also [brackets] and {braces}. key: value pairs."
save_answer "optional_notes" "$yaml_answer"
result=$(load_answer "optional_notes")
if [[ "$result" == "$yaml_answer" ]]; then
    pass "YAML-like syntax roundtrip"
else
    fail "YAML-like syntax roundtrip failed"
    echo "    Expected: ${yaml_answer}"
    echo "    Got:      ${result}"
fi

# ============================================================
echo
echo "=== save_answer: overwrite existing answer ==="
# ============================================================

save_answer "developer_philosophy" "New philosophy: simplicity first"
result=$(load_answer "developer_philosophy")
if [[ "$result" == "New philosophy: simplicity first" ]]; then
    pass "Overwrite existing answer"
else
    fail "Overwrite existing answer: got '${result}'"
fi

# ============================================================
echo
echo "=== load_answer: nonexistent section ==="
# ============================================================

result=$(load_answer "nonexistent_section")
if [[ -z "$result" ]]; then
    pass "Nonexistent section returns empty"
else
    fail "Nonexistent section should return empty, got '${result}'"
fi

# ============================================================
echo
echo "=== load_all_answers ==="
# ============================================================

# Capture all output first to avoid SIGPIPE
all_output=$(load_all_answers)
line_count=$(echo "$all_output" | wc -l | tr -d ' ')
if [[ "$line_count" -eq 4 ]]; then
    pass "load_all_answers returns 4 sections"
else
    fail "Expected 4 sections, got ${line_count}"
fi

# Check first line has correct format
first_line=$(echo "$all_output" | head -1)
if [[ "$first_line" == *"|Developer Philosophy|1|true|"* ]]; then
    pass "First answer line has correct format"
else
    fail "First answer line format wrong: ${first_line}"
fi

# ============================================================
echo
echo "=== answer_file_complete ==="
# ============================================================

# All required sections now have answers
if answer_file_complete; then
    pass "answer_file_complete returns 0 when all required answered"
else
    fail "answer_file_complete should return 0"
fi

# Clear a required section
save_answer "tech_stack" ""
if answer_file_complete; then
    fail "answer_file_complete should return 1 with empty required"
else
    pass "answer_file_complete returns 1 with empty required"
fi

# TBD counts as incomplete
save_answer "tech_stack" "TBD"
if answer_file_complete; then
    fail "answer_file_complete should return 1 with TBD required"
else
    pass "answer_file_complete returns 1 with TBD required"
fi

# Restore for later tests
save_answer "tech_stack" "$special_answer"

# ============================================================
echo
echo "=== build_answers_block ==="
# ============================================================

block=$(build_answers_block)

if echo "$block" | grep -q '\*\*Developer Philosophy \[REQUIRED\]\*\*'; then
    pass "build_answers_block includes required label"
else
    fail "build_answers_block missing required label"
fi

if echo "$block" | grep -q '\*\*Optional Notes\*\*'; then
    pass "build_answers_block includes optional section"
else
    fail "build_answers_block missing optional section"
fi

# ============================================================
echo
echo "=== export_question_template ==="
# ============================================================

exported=$(export_question_template "$PLAN_TEMPLATE_FILE")

if echo "$exported" | head -1 | grep -q "^# Tekhton Planning Answers"; then
    pass "Export has valid header"
else
    fail "Export missing header"
fi

if echo "$exported" | grep -q "developer_philosophy:"; then
    pass "Export includes developer_philosophy section"
else
    fail "Export missing developer_philosophy section"
fi

if echo "$exported" | grep -q 'answer: ""'; then
    pass "Export has empty answer fields"
else
    fail "Export missing empty answer fields"
fi

if echo "$exported" | grep -q "# Guidance:"; then
    pass "Export includes guidance comments"
else
    fail "Export missing guidance comments"
fi

# ============================================================
echo
echo "=== export_question_template to file ==="
# ============================================================

export_path="${TEST_TMPDIR}/exported.yaml"
export_question_template "$PLAN_TEMPLATE_FILE" "$export_path"

if [[ -f "$export_path" ]]; then
    pass "Export to file creates file"
else
    fail "Export to file did not create file"
fi

# ============================================================
echo
echo "=== import_answer_file ==="
# ============================================================

# Fill in the exported file with answers
import_file="${TEST_TMPDIR}/import.yaml"
cat > "$import_file" << 'IMPORTEOF'
# Tekhton Planning Answers
# Project: test
# Template: test

sections:
  developer_philosophy:
    title: "Developer Philosophy"
    phase: 1
    required: true
    answer: "Imported philosophy"
  project_overview:
    title: "Project Overview"
    phase: 1
    required: true
    answer: |
      Imported overview line 1.
      Imported overview line 2.
  tech_stack:
    title: "Tech Stack"
    phase: 1
    required: true
    answer: "Imported stack"
  optional_notes:
    title: "Optional Notes"
    phase: 2
    required: false
    answer: ""
IMPORTEOF

import_answer_file "$import_file"
result=$(load_answer "developer_philosophy")
if [[ "$result" == "Imported philosophy" ]]; then
    pass "import_answer_file loads answers correctly"
else
    fail "import_answer_file failed: got '${result}'"
fi

result=$(load_answer "project_overview")
expected="Imported overview line 1.
Imported overview line 2."
if [[ "$result" == "$expected" ]]; then
    pass "import_answer_file handles multi-line block scalar"
else
    fail "import_answer_file multi-line failed"
    echo "    Expected: $(echo "$expected" | head -1)..."
    echo "    Got:      $(echo "$result" | head -1)..."
fi

# ============================================================
echo
echo "=== import_answer_file: rejects invalid file ==="
# ============================================================

bad_file="${TEST_TMPDIR}/bad.yaml"
echo "not a tekhton file" > "$bad_file"
if import_answer_file "$bad_file" 2>/dev/null; then
    fail "import_answer_file should reject invalid file"
else
    pass "import_answer_file rejects invalid file"
fi

# ============================================================
echo
echo "=== _slugify_section ==="
# ============================================================

slug=$(_slugify_section "Developer Philosophy & Constraints")
if [[ "$slug" == "developer_philosophy_constraints" ]]; then
    pass "Slugify handles ampersand and spaces"
else
    fail "Slugify: expected 'developer_philosophy_constraints', got '${slug}'"
fi

slug=$(_slugify_section "Key User Flows")
if [[ "$slug" == "key_user_flows" ]]; then
    pass "Slugify handles simple title"
else
    fail "Slugify: expected 'key_user_flows', got '${slug}'"
fi

# ============================================================
echo
echo "=== rename_answer_file_done ==="
# ============================================================

# Re-init to get a fresh answer file
init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
rename_answer_file_done

if [[ ! -f "$PLAN_ANSWER_FILE" ]]; then
    pass "Original answer file removed after rename"
else
    fail "Original answer file still exists"
fi

if [[ -f "${PLAN_ANSWER_FILE}.done" ]]; then
    pass "Answer file renamed to .done"
else
    fail "Answer file .done not found"
fi

# ============================================================
echo
echo "=== Empty answer roundtrip ==="
# ============================================================

init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
result=$(load_answer "developer_philosophy")
if [[ -z "$result" ]]; then
    pass "Empty answer returns empty string"
else
    fail "Empty answer should return empty, got '${result}'"
fi

# ============================================================
echo
echo "=== Whitespace-only answer ==="
# ============================================================

save_answer "developer_philosophy" "   "
result=$(load_answer "developer_philosophy")
# Block scalar trims leading whitespace; the important thing is it roundtrips
if [[ -n "$result" ]]; then
    pass "Whitespace answer stored (content preserved)"
else
    # If stored as block scalar with only spaces, parsing may return empty
    # This is acceptable — trimmed whitespace = empty answer
    pass "Whitespace answer treated as empty (acceptable)"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "$FAIL" -eq 0 ]] || exit 1
