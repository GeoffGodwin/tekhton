#!/usr/bin/env bash
# Test: Milestone 18 — _budget_allocator surplus redistribution and _truncate_section
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source detect.sh for _DETECT_EXCLUDE_DIRS and _extract_json_keys
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/crawler.sh
source "${TEKHTON_HOME}/lib/crawler.sh"

# =============================================================================
# _budget_allocator — all sections fill allocation exactly
# Budget=100000: tree=10000, inv=15000, dep=10000, cfg=5000, test=5000
# surplus=0, sample=55000
# =============================================================================
echo "=== _budget_allocator: all sections fill allocation → sample gets base 55% ==="

result=$(_budget_allocator 100000 10000 15000 10000 5000 5000)
expected=55000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator returns 55000 when all sections fill their allocation"
else
    fail "_budget_allocator expected ${expected}, got ${result}"
fi

# =============================================================================
# _budget_allocator — all sections are empty → full surplus added to sample
# surplus = 10000+15000+10000+5000+5000 = 45000; sample = 55000+45000 = 100000
# =============================================================================
echo "=== _budget_allocator: all sections empty → sample gets 55% + full surplus ==="

result=$(_budget_allocator 100000 0 0 0 0 0)
expected=100000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator returns 100000 when all sections are empty (full surplus)"
else
    fail "_budget_allocator expected ${expected}, got ${result}"
fi

# =============================================================================
# _budget_allocator — partial underflow: only tree and deps empty
# tree surplus=10000, dep surplus=10000; inv/cfg/test fill exactly
# sample = 55000 + 20000 = 75000
# =============================================================================
echo "=== _budget_allocator: partial underflow (tree+dep empty) → correct surplus ==="

result=$(_budget_allocator 100000 0 15000 0 5000 5000)
expected=75000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator returns 75000 for partial underflow (tree+dep empty)"
else
    fail "_budget_allocator expected 75000, got ${result}"
fi

# =============================================================================
# _budget_allocator — sections exceed allocation (overflow) are NOT penalized
# The allocator only adds surplus from underflows; overflow sections don't reduce sample
# tree=20000 (overflows 10000 alloc), sample must still be 55000 (no penalty)
# =============================================================================
echo "=== _budget_allocator: overflow sections do not reduce sample budget ==="

result=$(_budget_allocator 100000 20000 15000 10000 5000 5000)
expected=55000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator does not penalize sample for overflow sections"
else
    fail "_budget_allocator expected 55000 for overflow sections, got ${result}"
fi

# =============================================================================
# _budget_allocator — small budget (1000 chars): proportions remain correct
# tree=100, inv=150, dep=100, cfg=50, test=50; actual all 0 → surplus=450; sample=550+450=1000
# =============================================================================
echo "=== _budget_allocator: small budget proportions correct ==="

result=$(_budget_allocator 1000 0 0 0 0 0)
expected=1000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator proportions correct for small budget (1000 chars)"
else
    fail "_budget_allocator expected 1000, got ${result}"
fi

# =============================================================================
# _truncate_section — text within budget → returned unchanged
# =============================================================================
echo "=== _truncate_section: text within budget returned unchanged ==="

text="line one
line two
line three"
budget=1000
result=$(_truncate_section "$text" "$budget")
if [[ "$result" == "$text" ]]; then
    pass "_truncate_section returns text unchanged when within budget"
else
    fail "_truncate_section modified text that fit within budget"
fi

# =============================================================================
# _truncate_section — text exactly at budget → returned unchanged
# =============================================================================
echo "=== _truncate_section: text at budget boundary returned unchanged ==="

text="hello"
budget=${#text}
result=$(_truncate_section "$text" "$budget")
if [[ "$result" == "$text" ]]; then
    pass "_truncate_section returns text unchanged at exact budget boundary"
else
    fail "_truncate_section modified text at exact budget boundary"
fi

# =============================================================================
# _truncate_section — text over budget → includes truncation marker
# =============================================================================
echo "=== _truncate_section: text over budget includes truncation marker ==="

# Build a text larger than 50 chars
text="line one
line two
line three
line four
line five
line six"
budget=20
result=$(_truncate_section "$text" "$budget")
if echo "$result" | grep -q "truncated"; then
    pass "_truncate_section includes 'truncated' marker when text exceeds budget"
else
    fail "_truncate_section did not add truncation marker for oversized text"
fi

# =============================================================================
# _truncate_section — truncated output must not exceed budget + marker overhead
# (The truncation cuts at last newline and then appends a marker, so the final
#  result can be slightly larger than budget due to marker. Verify prefix stays
#  within budget chars.)
# =============================================================================
echo "=== _truncate_section: truncated prefix stays within budget ==="

# Build 200-char text
long_text=$(printf 'abcdefghijklmnopqrstuvwxyz\n%.0s' {1..8})
budget=50
result=$(_truncate_section "$long_text" "$budget")
# Extract prefix before the marker
prefix="${result%%...*}"
if [[ ${#prefix} -le $((budget + 2)) ]]; then
    pass "_truncate_section prefix stays within budget (${#prefix} <= $((budget+2)) chars)"
else
    fail "_truncate_section prefix too large: ${#prefix} chars for budget ${budget}"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
