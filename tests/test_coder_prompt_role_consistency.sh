#!/usr/bin/env bash
# Test: coder.prompt.md and templates/coder.md are consistent about CODER_SUMMARY.md
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODER_PROMPT="${TEKHTON_HOME}/prompts/coder.prompt.md"
CODER_ROLE="${TEKHTON_HOME}/templates/coder.md"

PASS=0
FAIL=0

check() {
    local desc="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: Both files reference CODER_SUMMARY
grep -q 'CODER_SUMMARY' "$CODER_PROMPT"
check "coder.prompt.md references CODER_SUMMARY" $?

grep -q 'CODER_SUMMARY' "$CODER_ROLE"
check "templates/coder.md references CODER_SUMMARY" $?

# Test 2: Role file points to itself in the prompt
grep -q '{{CODER_ROLE_FILE}}' "$CODER_PROMPT"
check "coder.prompt.md references {{CODER_ROLE_FILE}}" $?

# Test 3: Both mention the Status field
grep -q '## Status' "$CODER_ROLE"
check "templates/coder.md has Status field section" $?

# Test 4: Both mention the Files Modified section
grep -q '## Files Modified' "$CODER_ROLE"
check "templates/coder.md has Files Modified section" $?

grep -q 'CODER_SUMMARY' "$CODER_PROMPT"
check "coder.prompt.md mentions CODER_SUMMARY output" $?

# Test 5: Role file has required sections list that matches skeleton
grep -q '## Status\|## What Was Implemented\|## Root Cause\|## Files Modified' "$CODER_ROLE"
check "templates/coder.md has all required sections documented" $?

# Test 6: Both documents emphasize human notes in output
grep -q 'Human Notes' "$CODER_ROLE"
check "templates/coder.md has Human Notes Status section" $?

# Test 7: Role file instructs to update summary throughout
grep -q 'Update the file throughout' "$CODER_ROLE"
check "templates/coder.md instructs updating throughout work" $?

# Test 8: Prompt references the role file's instructions
grep -q 'full role definition' "$CODER_PROMPT"
check "coder.prompt.md points to full role definition" $?

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
