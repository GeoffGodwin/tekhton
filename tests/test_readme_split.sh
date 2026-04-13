#!/usr/bin/env bash
# Test: M79 README restructure verification
# Asserts README is ≤300 lines, all docs/ links resolve, and CHANGELOG exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== M79 README Split Verification ==="

# --- README line count ---
readme_lines=$(wc -l < "$PROJECT_ROOT/README.md")
if [[ "$readme_lines" -le 300 ]]; then
    pass "README.md is $readme_lines lines (≤300)"
else
    fail "README.md is $readme_lines lines (exceeds 300)"
fi

# --- All docs/ links in README resolve ---
# Extract markdown links that point to ./docs/ or docs/
while IFS= read -r link; do
    # Strip leading ./ if present
    link="${link#./}"
    target="$PROJECT_ROOT/$link"
    if [[ -f "$target" ]]; then
        pass "Link resolves: $link"
    else
        fail "Broken link: $link"
    fi
done < <(grep -oP '\(\.?\.?/?docs/[^)#]+' "$PROJECT_ROOT/README.md" | sed 's/^(//' || true)

# --- All 13 required docs/ files exist and are non-empty ---
required_docs=(
    "docs/USAGE.md"
    "docs/MILESTONES.md"
    "docs/cli-reference.md"
    "docs/configuration.md"
    "docs/specialists.md"
    "docs/watchtower.md"
    "docs/metrics.md"
    "docs/context.md"
    "docs/crawling.md"
    "docs/drift.md"
    "docs/resilience.md"
    "docs/debt-sweeps.md"
    "docs/planning.md"
    "docs/security.md"
)

for doc in "${required_docs[@]}"; do
    filepath="$PROJECT_ROOT/$doc"
    if [[ -f "$filepath" ]]; then
        size=$(wc -c < "$filepath")
        if [[ "$size" -gt 0 ]]; then
            pass "$doc exists and is non-empty ($size bytes)"
        else
            fail "$doc exists but is empty"
        fi
    else
        fail "$doc does not exist"
    fi
done

# --- Each docs/ file has a history pointer header ---
for doc in "${required_docs[@]}"; do
    filepath="$PROJECT_ROOT/$doc"
    if [[ -f "$filepath" ]]; then
        if grep -q 'M79' "$filepath" || grep -q 'M80 populates' "$filepath"; then
            pass "$doc has M79/M80 reference"
        else
            fail "$doc missing history pointer or milestone reference"
        fi
    fi
done

# --- CHANGELOG.md exists ---
if [[ -f "$PROJECT_ROOT/CHANGELOG.md" ]]; then
    pass "CHANGELOG.md exists"
else
    fail "CHANGELOG.md does not exist"
fi

# --- README Changelog section is a pointer ---
if grep -q 'See \[CHANGELOG.md\]' "$PROJECT_ROOT/README.md"; then
    pass "README Changelog section points to CHANGELOG.md"
else
    fail "README Changelog section missing pointer to CHANGELOG.md"
fi

# --- README has the required sections in order ---
sections_found=0
prev_line=0
expected_sections=(
    "What is Tekhton"
    "Install"
    "5-Minute Quickstart"
    "How to Use Tekhton Effectively"
    "What's in"
    "Requirements"
    "Contributing"
    "Changelog"
    "License"
)

for section in "${expected_sections[@]}"; do
    line_num=$(grep -n -- "$section" "$PROJECT_ROOT/README.md" | head -1 | cut -d: -f1 || true)
    if [[ -n "$line_num" ]]; then
        if [[ "$line_num" -gt "$prev_line" ]]; then
            pass "Section '$section' found at line $line_num (in order)"
            sections_found=$((sections_found + 1))
            prev_line=$line_num
        else
            fail "Section '$section' at line $line_num is out of order (prev: $prev_line)"
        fi
    else
        fail "Section '$section' not found in README"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
