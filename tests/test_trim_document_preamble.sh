#!/usr/bin/env bash
# Test: _trim_document_preamble() helper function
# Tests the shared helper that removes preamble text before the first `# ` heading
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Load the function
source "${TEKHTON_HOME}/lib/plan_batch.sh"

echo "=== Test 1: Fast path - input already starts with # ==="
input="# Heading
## Section
Content here"

output=$(printf '%s' "$input" | _trim_document_preamble)
if [[ "$output" == "$input" ]]; then
    pass "Fast path returns input unchanged when it starts with heading"
else
    fail "Fast path did not return input unchanged"
fi

echo ""
echo "=== Test 2: Single preamble line before heading ==="
input="I have enough context to generate this document.
# Project Name
## Section
Content here"

output=$(printf '%s' "$input" | _trim_document_preamble)
first_line=$(printf '%s' "$output" | head -1)
if [[ "$first_line" == "# Project Name" ]]; then
    pass "Single preamble line trimmed correctly"
else
    fail "First line after trim is: $first_line (expected '# Project Name')"
fi

echo ""
echo "=== Test 3: Multiple preamble lines before heading ==="
input="Here is the generated document.
I have enough context.
This is a valid document.
# CLAUDE.md
## Architecture
Content"

output=$(printf '%s' "$input" | _trim_document_preamble)
first_line=$(printf '%s' "$output" | head -1)
if [[ "$first_line" == "# CLAUDE.md" ]]; then
    pass "Multiple preamble lines trimmed correctly"
else
    fail "First line after trim is: $first_line (expected '# CLAUDE.md')"
fi

echo ""
echo "=== Test 4: Preamble with empty lines before heading ==="
input="Here is the DESIGN.md I generated.

# Design Document
## Overview
Content"

output=$(printf '%s' "$input" | _trim_document_preamble)
first_line=$(printf '%s' "$output" | head -1)
if [[ "$first_line" == "# Design Document" ]]; then
    pass "Preamble with empty lines trimmed correctly"
else
    fail "First line after trim is: $first_line (expected '# Design Document')"
fi

echo ""
echo "=== Test 5: No heading found - return input unchanged ==="
input="This document has no heading.
Just some content.
More content without markdown headings."

output=$(printf '%s' "$input" | _trim_document_preamble)
if [[ "$output" == "$input" ]]; then
    pass "Input returned unchanged when no heading found"
else
    fail "Output differs from input when no heading found"
fi

echo ""
echo "=== Test 6: Empty input ==="
input=""
output=$(printf '%s' "$input" | _trim_document_preamble)
if [[ -z "$output" ]]; then
    pass "Empty input returns empty output"
else
    fail "Empty input did not return empty output"
fi

echo ""
echo "=== Test 7: Only a heading, no content ==="
input="# Title"
output=$(printf '%s' "$input" | _trim_document_preamble)
if [[ "$output" == "# Title" ]]; then
    pass "Single heading line returned unchanged"
else
    fail "Single heading line not returned correctly"
fi

echo ""
echo "=== Test 8: Heading in middle of content (preamble before, content after) ==="
input="Preamble text before the first heading.
# Main Heading
## Subsection
More content here
And more content"

output=$(printf '%s' "$input" | _trim_document_preamble)
lines=$(printf '%s' "$output" | wc -l | tr -d '[:space:]')
first=$(printf '%s' "$output" | head -1)

if [[ "$first" == "# Main Heading" ]]; then
    pass "Heading correctly identified and preamble trimmed"
else
    fail "Heading not found or preamble not trimmed correctly"
fi

# Verify we kept content after the heading
if printf '%s' "$output" | grep -q "And more content"; then
    pass "Content after heading preserved"
else
    fail "Content after heading was lost"
fi

echo ""
echo "=== Test 9: Hash in non-heading position not matched ==="
input="Preamble: Use this command: grep '#' file.txt
# Real Heading
Content"

output=$(printf '%s' "$input" | _trim_document_preamble)
first=$(printf '%s' "$output" | head -1)

if [[ "$first" == "# Real Heading" ]]; then
    pass "Hash in preamble not matched as heading"
else
    fail "Non-heading hash incorrectly matched"
fi

echo ""
echo "=== Test 10: Multiple headings - stops at first ==="
input="This is a preamble.
# First Heading
## Sub heading
Content
# Second Heading
More content"

output=$(printf '%s' "$input" | _trim_document_preamble)
first=$(printf '%s' "$output" | head -1)
second=$(printf '%s' "$output" | grep "^# Second" || true)

if [[ "$first" == "# First Heading" ]]; then
    pass "Correctly identifies and keeps first heading"
else
    fail "Did not identify first heading correctly"
fi

if [[ -n "$second" ]]; then
    pass "Subsequent headings preserved in output"
else
    fail "Subsequent headings were lost"
fi

echo ""
echo "=== Test 11: Preamble with special characters ==="
input="Generated on \$(date) with special chars: !@#$%
# Document
Content"

output=$(printf '%s' "$input" | _trim_document_preamble)
first=$(printf '%s' "$output" | head -1)

if [[ "$first" == "# Document" ]]; then
    pass "Preamble with special characters trimmed correctly"
else
    fail "Special characters in preamble caused issues"
fi

echo ""
echo "=== Test 12: Realistic CLAUDE.md generation case ==="
# Simulates actual Claude output with verbose preamble
input="I've analyzed your DESIGN.md and generated a comprehensive CLAUDE.md.
Here's the complete file:

# MyProject
## Project Identity
This project builds X.
## Architecture Philosophy
The system uses Y pattern.
## Implementation Milestones
Milestone 1: Setup
Milestone 2: Core Features"

output=$(printf '%s' "$input" | _trim_document_preamble)
first=$(printf '%s' "$output" | head -1)
line_count=$(printf '%s' "$output" | wc -l | tr -d '[:space:]')

if [[ "$first" == "# MyProject" ]]; then
    pass "Realistic preamble trimmed correctly"
else
    fail "Realistic case failed: first line is $first"
fi

if [[ "$line_count" -gt 4 ]]; then
    pass "Content after heading preserved ($line_count lines)"
else
    fail "Content may have been lost (only $line_count lines)"
fi

echo ""
echo "=== Test 13: Long preamble (5+ lines) ==="
input="Here is the generated document.
I have analyzed the requirements.
I have enough context.
Now I will output the document.
The document is ready.
# Generated Document
## Section 1
Content"

output=$(printf '%s' "$input" | _trim_document_preamble)
first=$(printf '%s' "$output" | head -1)

if [[ "$first" == "# Generated Document" ]]; then
    pass "Long preamble (5 lines) trimmed correctly"
else
    fail "Long preamble not handled correctly"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
