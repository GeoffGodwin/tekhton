#!/usr/bin/env bash
# Test: replan.prompt.md contains rule 7 (consolidation awareness for repeat replan cycles)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_FILE="${TEKHTON_HOME}/prompts/replan.prompt.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Verify the prompt file exists
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "FATAL: ${PROMPT_FILE} not found"
    exit 1
fi

# ============================================================
# Test 1: Rule 7 exists in the Rules section
# ============================================================
echo "=== replan prompt — rule 7 consolidation awareness present ==="

if grep -q "^7\." "$PROMPT_FILE"; then
    pass "Rule 7 is present in replan.prompt.md"
else
    fail "Rule 7 not found in replan.prompt.md (expected numbered item '7.')"
fi

# ============================================================
# Test 2: Rule 7 mentions consolidation
# ============================================================
echo "=== replan prompt — rule 7 mentions consolidation ==="

if grep -qi "consolidat" "$PROMPT_FILE"; then
    pass "Consolidation keyword found in replan.prompt.md"
else
    fail "'consolidat' not found in replan.prompt.md"
fi

# ============================================================
# Test 3: Rule 7 references 'Replan Delta' sections as the detection signal
# ============================================================
echo "=== replan prompt — rule 7 references 'Replan Delta' sections ==="

if grep -q "Replan Delta" "$PROMPT_FILE"; then
    pass "'Replan Delta' section marker referenced in replan.prompt.md"
else
    fail "'Replan Delta' not found in replan.prompt.md — expected as detection signal"
fi

# ============================================================
# Test 4: CONSOLIDATE action is defined as an output option
# ============================================================
echo "=== replan prompt — CONSOLIDATE action defined ==="

if grep -q "CONSOLIDATE" "$PROMPT_FILE"; then
    pass "CONSOLIDATE action keyword found in replan.prompt.md"
else
    fail "'CONSOLIDATE' not found in replan.prompt.md"
fi

# ============================================================
# Test 5: Existing rules 1–6 are still present (no accidental removal)
# ============================================================
echo "=== replan prompt — rules 1-6 still present ==="

all_present=true
for rule_num in 1 2 3 4 5 6; do
    if ! grep -q "^${rule_num}\." "$PROMPT_FILE"; then
        fail "Rule ${rule_num} missing from replan.prompt.md"
        all_present=false
    fi
done
if [[ "$all_present" == "true" ]]; then
    pass "Rules 1–6 all present in replan.prompt.md"
fi

# ============================================================
# Test 6: Rule 7 is in the ## Rules section (not in output format or elsewhere)
# ============================================================
echo "=== replan prompt — rule 7 is in the Rules section ==="

# Extract the ## Rules section and check rule 7 appears in it
rules_section=$(awk '/^## Rules/{found=1} found{print} /^## /{if(found && !/^## Rules/)exit}' "$PROMPT_FILE")

if echo "$rules_section" | grep -q "^7\."; then
    pass "Rule 7 is in the '## Rules' section"
else
    fail "Rule 7 not found in the '## Rules' section"
fi

# ============================================================
# Test 7: Rule 7 references repeated/accumulated deltas (not just single run)
# ============================================================
echo "=== replan prompt — rule 7 addresses repeated replan cycles ==="

# Rule 7 should address the problem of accumulating deltas from multiple replan runs.
# Extract full rule 7 block: from "7." line through the next blank line or rule 8+
rule7_text=$(awk '/^7\./{found=1} found{print; if(/^$/ && found && NR>1)exit}' "$PROMPT_FILE")

if echo "$rule7_text" | grep -qiE "accumulat|repeated|multiple|over time|grow"; then
    pass "Rule 7 addresses accumulation/repeated cycles"
else
    fail "Rule 7 should mention accumulation/repeated/multiple replan cycles"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
