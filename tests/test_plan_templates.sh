#!/usr/bin/env bash
# Test: Planning phase template existence and content
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${TEKHTON_HOME}/templates/plans"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Expected types → minimum required section count (from CODER_SUMMARY.md)
declare -A EXPECTED_REQUIRED
EXPECTED_REQUIRED["web-app"]=10
EXPECTED_REQUIRED["web-game"]=11
EXPECTED_REQUIRED["cli-tool"]=11
EXPECTED_REQUIRED["api-service"]=10
EXPECTED_REQUIRED["mobile-app"]=10
EXPECTED_REQUIRED["library"]=9
EXPECTED_REQUIRED["custom"]=9

echo "=== Template Existence ==="

for type in "${!EXPECTED_REQUIRED[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    if [ -f "$tmpl" ]; then
        pass "${type}.md exists"
    else
        fail "${type}.md missing at ${tmpl}"
    fi
done

echo
echo "=== REQUIRED Marker Count ==="

for type in "${!EXPECTED_REQUIRED[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    [ -f "$tmpl" ] || continue

    expected="${EXPECTED_REQUIRED[$type]}"
    actual=$(grep -c '<!-- REQUIRED -->' "$tmpl" || true)

    if [ "$actual" -eq "$expected" ]; then
        pass "${type}.md: ${actual} REQUIRED markers"
    else
        fail "${type}.md: expected ${expected} REQUIRED markers, got ${actual}"
    fi
done

echo
echo "=== Total Section Count Minimums (Milestone 1 requirements) ==="

# Total ## section counts per template type (from CLAUDE.md Milestone 1)
declare -A EXPECTED_MIN_SECTIONS
EXPECTED_MIN_SECTIONS["web-app"]=18
EXPECTED_MIN_SECTIONS["web-game"]=20
EXPECTED_MIN_SECTIONS["cli-tool"]=15
EXPECTED_MIN_SECTIONS["api-service"]=18
EXPECTED_MIN_SECTIONS["mobile-app"]=18
EXPECTED_MIN_SECTIONS["library"]=15
EXPECTED_MIN_SECTIONS["custom"]=12

for type in "${!EXPECTED_MIN_SECTIONS[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    [ -f "$tmpl" ] || continue

    min="${EXPECTED_MIN_SECTIONS[$type]}"
    actual=$(grep -c '^## ' "$tmpl" || true)

    if [ "$actual" -ge "$min" ]; then
        pass "${type}.md: ${actual} total sections (>= ${min} minimum)"
    else
        fail "${type}.md: expected >= ${min} total sections, got ${actual}"
    fi
done

echo
echo "=== PHASE Marker Parsing (_extract_template_sections) ==="

# Source plan.sh to get _extract_template_sections
TEST_TMPDIR_TMPL=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR_TMPL"
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# shellcheck source=../lib/plan.sh
source "${TEKHTON_HOME}/lib/plan.sh"

# Create a test template with known PHASE markers
cat > "${TEST_TMPDIR_TMPL}/phase_test.md" << 'PHASEEOF'
# Test Design Document

## Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What is this project? -->

## Tech Stack
<!-- PHASE:1 -->
<!-- What technologies? -->

## Core Systems
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- Describe each system -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- Config values and formats -->

## No Phase Marker
<!-- Some guidance -->
PHASEEOF

# Verify 4-field output: NAME|REQUIRED|GUIDANCE|PHASE
section_output=$(_extract_template_sections "${TEST_TMPDIR_TMPL}/phase_test.md")

# Check field count (pipe-separated)
first_line=$(echo "$section_output" | head -1)
field_count=$(echo "$first_line" | awk -F'|' '{print NF}')
if [ "$field_count" -eq 4 ]; then
    pass "_extract_template_sections outputs 4-field format (NAME|REQUIRED|GUIDANCE|PHASE)"
else
    fail "expected 4 fields per line, got ${field_count}: '${first_line}'"
fi

# Check Phase 1 sections
phase1_count=$(echo "$section_output" | awk -F'|' '$4 == "1"' | wc -l | tr -d ' ')
if [ "$phase1_count" -ge 2 ]; then
    pass "PHASE:1 sections detected (${phase1_count})"
else
    fail "expected >= 2 PHASE:1 sections, got ${phase1_count}"
fi

# Check Phase 2 sections
phase2_count=$(echo "$section_output" | awk -F'|' '$4 == "2"' | wc -l | tr -d ' ')
if [ "$phase2_count" -ge 1 ]; then
    pass "PHASE:2 sections detected (${phase2_count})"
else
    fail "expected >= 1 PHASE:2 sections, got ${phase2_count}"
fi

# Check Phase 3 sections
phase3_count=$(echo "$section_output" | awk -F'|' '$4 == "3"' | wc -l | tr -d ' ')
if [ "$phase3_count" -ge 1 ]; then
    pass "PHASE:3 sections detected (${phase3_count})"
else
    fail "expected >= 1 PHASE:3 sections, got ${phase3_count}"
fi

# Section with no PHASE marker should default to phase 1
no_phase_line=$(echo "$section_output" | grep 'No Phase Marker' || true)
no_phase_val=$(echo "$no_phase_line" | awk -F'|' '{print $4}')
if [ "$no_phase_val" = "1" ]; then
    pass "Section without PHASE marker defaults to phase 1"
else
    fail "expected default phase 1 for unmarked section, got '${no_phase_val}'"
fi

# Verify all 7 real templates have PHASE markers in all 3 phases
for type in "${!EXPECTED_REQUIRED[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    [ -f "$tmpl" ] || continue

    phases_found=$(grep -oP '<!-- PHASE:\K[0-9]+' "$tmpl" | sort -u | tr '\n' ',' || true)
    if echo "$phases_found" | grep -q '1,' && echo "$phases_found" | grep -q '2,' && echo "$phases_found" | grep -q '3,'; then
        pass "${type}.md: has PHASE:1, PHASE:2, and PHASE:3 markers"
    else
        fail "${type}.md: missing some PHASE markers (found: ${phases_found})"
    fi
done

rm -rf "$TEST_TMPDIR_TMPL"

echo
echo "=== Section Heading Structure ==="

for type in "${!EXPECTED_REQUIRED[@]}"; do
    tmpl="${TEMPLATES_DIR}/${type}.md"
    [ -f "$tmpl" ] || continue

    # Every template must have an Overview or Project Overview section
    if grep -q '^## .*Overview' "$tmpl"; then
        pass "${type}.md: has Overview section"
    else
        fail "${type}.md: missing Overview section"
    fi

    # Every template must have a Tech Stack section
    if grep -q '^## Tech Stack' "$tmpl"; then
        pass "${type}.md: has Tech Stack section"
    else
        fail "${type}.md: missing Tech Stack section"
    fi

    # Every template must have a "Developer Philosophy & Constraints" section by exact name
    if grep -q '^## Developer Philosophy & Constraints$' "$tmpl"; then
        pass "${type}.md: has 'Developer Philosophy & Constraints' section"
    else
        fail "${type}.md: missing '## Developer Philosophy & Constraints' section"
    fi

    # Every template must have a "Config Architecture" section by exact name
    if grep -q '^## Config Architecture$' "$tmpl"; then
        pass "${type}.md: has 'Config Architecture' section"
    else
        fail "${type}.md: missing '## Config Architecture' section"
    fi

    # Sections that have REQUIRED markers must be ## headings directly above the marker
    # Check that no REQUIRED marker appears without a ## heading preceding it
    prev_line=""
    while IFS= read -r line; do
        if [[ "$line" == "<!-- REQUIRED -->" ]]; then
            if [[ "$prev_line" =~ ^## ]]; then
                pass "${type}.md: REQUIRED marker follows a ## heading ('${prev_line}')"
            else
                fail "${type}.md: REQUIRED marker not directly after ## heading (prev: '${prev_line}')"
            fi
        fi
        prev_line="$line"
    done < "$tmpl"
done

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
