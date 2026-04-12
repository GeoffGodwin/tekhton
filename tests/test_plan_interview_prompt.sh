#!/usr/bin/env bash
# Test: plan_interview.prompt.md — template variables, required content, rendering
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_FILE="${TEKHTON_HOME}/prompts/plan_interview.prompt.md"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PROJECT_DIR="$TMPDIR_BASE"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Prompt File Existence ==="

if [ -f "$PROMPT_FILE" ]; then
    pass "plan_interview.prompt.md exists"
else
    fail "plan_interview.prompt.md missing at ${PROMPT_FILE}"
fi

echo
echo "=== Required Template Variables ==="

# Must contain {{TEMPLATE_CONTENT}} placeholder
if grep -q '{{TEMPLATE_CONTENT}}' "$PROMPT_FILE"; then
    pass "contains {{TEMPLATE_CONTENT}} placeholder"
else
    fail "missing {{TEMPLATE_CONTENT}} placeholder"
fi

# Must contain {{PROJECT_TYPE}} placeholder
if grep -q '{{PROJECT_TYPE}}' "$PROMPT_FILE"; then
    pass "contains {{PROJECT_TYPE}} placeholder"
else
    fail "missing {{PROJECT_TYPE}} placeholder"
fi

echo
echo "=== Interview Rule Content ==="

# Must instruct agent to write design file (DESIGN.md or {{DESIGN_FILE}})
if grep -q 'DESIGN' "$PROMPT_FILE"; then
    pass "mentions DESIGN file (output file)"
else
    fail "does not mention DESIGN file"
fi

# Must mention REQUIRED sections
if grep -q 'REQUIRED' "$PROMPT_FILE"; then
    pass "mentions REQUIRED sections"
else
    fail "does not mention REQUIRED sections"
fi

# Must contain {{INTERVIEW_ANSWERS_BLOCK}} placeholder (synthesis approach)
if grep -q 'INTERVIEW_ANSWERS_BLOCK' "$PROMPT_FILE"; then
    pass "contains {{INTERVIEW_ANSWERS_BLOCK}} for synthesis answers"
else
    fail "does not reference interview answers (INTERVIEW_ANSWERS_BLOCK)"
fi

# Must mention progressive writing (complete file each time)
if grep -qi 'progressive\|complete.*file\|COMPLETE' "$PROMPT_FILE"; then
    pass "instructs progressive/complete DESIGN.md writes"
else
    fail "does not instruct progressive DESIGN.md writes"
fi

# Must mention removing guidance comments
if grep -qi 'comment\|<!--' "$PROMPT_FILE"; then
    pass "mentions removing guidance comments"
else
    fail "does not mention guidance comments cleanup"
fi

echo
echo "=== Depth Instructions (Milestone 2+3 requirements) ==="

# Must instruct agent to create sub-sections (### headings)
if grep -qi 'sub.section\|### ' "$PROMPT_FILE"; then
    pass "instructs creation of sub-sections (### headings)"
else
    fail "does not instruct creation of sub-sections"
fi

# Must instruct agent to include tables
if grep -qi 'table' "$PROMPT_FILE"; then
    pass "instructs inclusion of tables"
else
    fail "does not instruct inclusion of tables"
fi

# Must instruct agent to include config examples
if grep -qi 'config.*example\|example.*config\|fenced code' "$PROMPT_FILE"; then
    pass "instructs inclusion of config examples"
else
    fail "does not instruct config examples"
fi

# Must instruct agent to document edge cases
if grep -qi 'edge.case' "$PROMPT_FILE"; then
    pass "instructs edge case documentation"
else
    fail "does not instruct edge case documentation"
fi

# Must instruct deep prose (not just 2-6 sentences)
if grep -qi 'multi.paragraph\|20.50 lines\|not.*2.6 sentences\|as much.*detail' "$PROMPT_FILE"; then
    pass "instructs deep multi-paragraph prose"
else
    fail "does not instruct deep multi-paragraph prose"
fi

# Must mention the three interview phases
if grep -qi 'phase 1\|phase 2\|phase 3' "$PROMPT_FILE"; then
    pass "references three interview phases"
else
    fail "does not reference interview phases"
fi

echo
echo "=== Prompt Rendering ==="

# Render the prompt with mock variables — verify substitution works
export TEMPLATE_CONTENT="## Project Overview
<!-- REQUIRED -->
Describe your project."
export PROJECT_TYPE="web-app"

rendered=$(render_prompt "plan_interview")

# PROJECT_TYPE should be substituted in the output
if echo "$rendered" | grep -q 'web-app'; then
    pass "{{PROJECT_TYPE}} rendered correctly"
else
    fail "{{PROJECT_TYPE}} not substituted in rendered output"
fi

# TEMPLATE_CONTENT should be substituted (check for a unique string from it)
if echo "$rendered" | grep -q 'Project Overview'; then
    pass "{{TEMPLATE_CONTENT}} rendered correctly"
else
    fail "{{TEMPLATE_CONTENT}} not substituted in rendered output"
fi

# The raw placeholder must not appear in the output
if echo "$rendered" | grep -q '{{TEMPLATE_CONTENT}}'; then
    fail "{{TEMPLATE_CONTENT}} placeholder not replaced in output"
else
    pass "{{TEMPLATE_CONTENT}} placeholder fully replaced"
fi

if echo "$rendered" | grep -q '{{PROJECT_TYPE}}'; then
    fail "{{PROJECT_TYPE}} placeholder not replaced in output"
else
    pass "{{PROJECT_TYPE}} placeholder fully replaced"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
