#!/usr/bin/env bash
# =============================================================================
# test_continuation_context.sh — Tests for build_continuation_context()
#
# Tests:
#   1. Unknown stage returns empty string
#   2. Coder stage: output contains attempt/max/turns header
#   3. Coder stage: includes prior CODER_SUMMARY.md content
#   4. Coder stage: includes coder-specific instructions
#   5. Tester stage: includes TESTER_REPORT.md content
#   6. Tester stage: includes tester-specific instructions
#   7. No summary file present: summary section is empty
#   8. Context includes "do NOT redo completed work" instruction
#   9. Different attempt numbers render correctly
#  10. Placeholder-only CODER_SUMMARY.md triggers "placeholder" state
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Change to the temp directory so relative file reads (CODER_SUMMARY.md etc.) work
cd "$TMPDIR_TEST"
mkdir -p "${TEKHTON_DIR:-.tekhton}"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
TESTER_REPORT_FILE="${TEKHTON_DIR}/TESTER_REPORT.md"
export CODER_SUMMARY_FILE TESTER_REPORT_FILE

# agent_helpers.sh expects these globals
LAST_AGENT_NULL_RUN=false
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/agent_helpers.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Test 1: Unknown stage returns empty string
# =============================================================================
echo "=== Test 1: Unknown stage returns empty ==="

result=$(build_continuation_context "invalid_stage" "1" "3" "50" "30")

if [[ -z "$result" ]]; then
    pass "1.1: Unknown stage returns empty string"
else
    fail "1.1: Unknown stage should return empty string, got: '$result'"
fi

# =============================================================================
# Test 2: Coder stage output contains attempt/max/turns header
# =============================================================================
echo "=== Test 2: Coder stage header ==="

result=$(build_continuation_context "coder" "2" "3" "75" "50")

if echo "$result" | grep -q "Continuation Context (attempt 2/3)"; then
    pass "2.1: Header contains attempt 2/3"
else
    fail "2.1: Missing 'Continuation Context (attempt 2/3)'"
fi

if echo "$result" | grep -q "75 turns total"; then
    pass "2.2: Cumulative turns (75) in header"
else
    fail "2.2: Missing cumulative turns '75 turns total'"
fi

if echo "$result" | grep -q "50 turns"; then
    pass "2.3: Next budget (50) in header"
else
    fail "2.3: Missing next budget '50 turns'"
fi

if echo "$result" | grep -q "Coder run that hit the turn limit"; then
    pass "2.4: Mentions Coder and turn limit"
else
    fail "2.4: Should mention 'Coder run that hit the turn limit'"
fi

# =============================================================================
# Test 3: Coder stage includes prior CODER_SUMMARY.md content
# =============================================================================
echo "=== Test 3: Coder stage includes summary file content ==="

cat > "${CODER_SUMMARY_FILE}" << 'EOF'
## Status: IN PROGRESS

## What Was Implemented
- Implemented feature A
- Implemented feature B

## Remaining
- Feature C still needs work
EOF

result=$(build_continuation_context "coder" "1" "3" "40" "50")

if echo "$result" | grep -q "Implemented feature A"; then
    pass "3.1: CODER_SUMMARY.md content included"
else
    fail "3.1: CODER_SUMMARY.md content should be included"
fi

if echo "$result" | grep -q "Feature C still needs work"; then
    pass "3.2: Remaining items from summary included"
else
    fail "3.2: Remaining items should be included"
fi

rm -f "${CODER_SUMMARY_FILE}"

# =============================================================================
# Test 4: Coder stage includes coder-specific instructions
# =============================================================================
echo "=== Test 4: Coder stage has coder-specific instructions ==="

result=$(build_continuation_context "coder" "1" "3" "50" "50")

if echo "$result" | grep -q "CODER_SUMMARY.md is missing"; then
    pass "4.1: Coder instruction to recreate missing CODER_SUMMARY.md"
else
    fail "4.1: Should instruct to recreate missing CODER_SUMMARY.md"
fi

if echo "$result" | grep -q "REMAINING items"; then
    pass "4.2: Coder instruction about remaining items"
else
    fail "4.2: Should instruct to continue REMAINING items"
fi

if echo "$result" | grep -q "Update.*CODER_SUMMARY.md"; then
    pass "4.3: Coder instruction to update CODER_SUMMARY.md"
else
    fail "4.3: Should instruct to update CODER_SUMMARY.md"
fi

if echo "$result" | grep -q "Status to COMPLETE"; then
    pass "4.4: Coder instruction about setting Status to COMPLETE"
else
    fail "4.4: Should instruct to set Status to COMPLETE"
fi

# =============================================================================
# Test 5: Tester stage includes TESTER_REPORT.md content
# =============================================================================
echo "=== Test 5: Tester stage includes report file content ==="

cat > "${TESTER_REPORT_FILE}" << 'EOF'
## Planned Tests
- [x] `tests/test_foo.sh` — test foo
- [ ] `tests/test_bar.sh` — test bar still needed

## Test Run Results
Passed: 1  Failed: 0
EOF

result=$(build_continuation_context "tester" "1" "3" "30" "30")

if echo "$result" | grep -q "test_bar.sh"; then
    pass "5.1: TESTER_REPORT.md content included"
else
    fail "5.1: TESTER_REPORT.md content should be included"
fi

if echo "$result" | grep -q "test_foo.sh"; then
    pass "5.2: Already-completed test shown in context"
else
    fail "5.2: Already-completed test should be visible in context"
fi

rm -f "${TESTER_REPORT_FILE}"

# =============================================================================
# Test 6: Tester stage includes tester-specific instructions
# =============================================================================
echo "=== Test 6: Tester stage has tester-specific instructions ==="

result=$(build_continuation_context "tester" "1" "3" "30" "30")

if echo "$result" | grep -q "Read.*TESTER_REPORT.md first"; then
    pass "6.1: Tester instruction to read TESTER_REPORT.md"
else
    fail "6.1: Should instruct to read TESTER_REPORT.md"
fi

if echo "$result" | grep -q "remaining unchecked test items"; then
    pass "6.2: Tester instruction about unchecked items"
else
    fail "6.2: Should mention 'remaining unchecked test items'"
fi

if echo "$result" | grep -q "Update.*TESTER_REPORT.md"; then
    pass "6.3: Tester instruction to update TESTER_REPORT.md"
else
    fail "6.3: Should instruct to update TESTER_REPORT.md"
fi

# =============================================================================
# Test 7: No summary file present — section has empty summary
# =============================================================================
echo "=== Test 7: No summary file present ==="

rm -f "${CODER_SUMMARY_FILE}"

result=$(build_continuation_context "coder" "1" "3" "50" "50")

# Should still produce output with the header and instructions
if echo "$result" | grep -q "Continuation Context"; then
    pass "7.1: Context block still generated when no summary file"
else
    fail "7.1: Context block should still be generated without summary file"
fi

if echo "$result" | grep -q "Prior Coder Summary"; then
    pass "7.2: Prior summary section present (empty content)"
else
    fail "7.2: Prior summary section header should always be present"
fi

# =============================================================================
# Test 8: Context contains "do NOT redo completed work"
# =============================================================================
echo "=== Test 8: Context warns against redoing work ==="

result=$(build_continuation_context "coder" "1" "3" "50" "50")

if echo "$result" | grep -q "Do NOT redo completed work"; then
    pass "8.1: Coder context warns against redoing work"
else
    fail "8.1: Should warn 'Do NOT redo completed work'"
fi

result=$(build_continuation_context "tester" "1" "3" "30" "30")

# The tester context should also mention "read" before continuing
if echo "$result" | grep -q "Read.*TESTER_REPORT.md first"; then
    pass "8.2: Tester context starts with read-first instruction"
else
    fail "8.2: Tester context should start with read-first instruction"
fi

# =============================================================================
# Test 9: Different attempt numbers render correctly
# =============================================================================
echo "=== Test 9: Attempt numbers render correctly ==="

result1=$(build_continuation_context "coder" "1" "3" "50" "50")
result2=$(build_continuation_context "coder" "3" "3" "150" "50")

if echo "$result1" | grep -q "attempt 1/3"; then
    pass "9.1: Attempt 1/3 renders correctly"
else
    fail "9.1: Should show 'attempt 1/3'"
fi

if echo "$result2" | grep -q "attempt 3/3"; then
    pass "9.2: Attempt 3/3 renders correctly"
else
    fail "9.2: Should show 'attempt 3/3'"
fi

if echo "$result2" | grep -q "150 turns total"; then
    pass "9.3: Cumulative turns (150) renders correctly"
else
    fail "9.3: Should show '150 turns total'"
fi

# =============================================================================
# Test 10: Placeholder-only CODER_SUMMARY.md triggers "placeholder" state
# =============================================================================
echo "=== Test 10: Placeholder CODER_SUMMARY.md ==="

# Write a skeleton with unfilled placeholders
cat > "${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: IN PROGRESS
## What Was Implemented
(fill in as you go)
## Root Cause (bugs only)
(fill in after diagnosis)
## Files Modified
(fill in as you go)
EOF

result=$(build_continuation_context "coder" "1" "3" "50" "50")

if echo "$result" | grep -q "CODER_SUMMARY.md is placeholder"; then
    pass "10.1: Placeholder skeleton detected as 'placeholder' state"
else
    fail "10.1: Should detect placeholder skeleton — expected 'CODER_SUMMARY.md is placeholder'"
fi

if echo "$result" | grep -q "recreate it NOW"; then
    pass "10.2: Placeholder state instructs to recreate NOW"
else
    fail "10.2: Placeholder state should instruct to recreate NOW"
fi

# Also verify the "update as you go" variant triggers placeholder detection
cat > "${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: IN PROGRESS
## What Was Implemented
(update as you go)
EOF

result=$(build_continuation_context "coder" "1" "3" "50" "50")

if echo "$result" | grep -q "CODER_SUMMARY.md is placeholder"; then
    pass "10.3: 'update as you go' variant also detected as placeholder"
else
    fail "10.3: 'update as you go' variant should also be detected as placeholder"
fi

# Verify that a properly filled CODER_SUMMARY.md does NOT trigger placeholder
cat > "${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: IN PROGRESS
## What Was Implemented
- Added input validation to the login form
- Fixed edge case in date parsing
## Files Modified
- src/auth/login.ts
- src/utils/date.ts
EOF

result=$(build_continuation_context "coder" "1" "3" "50" "50")

if echo "$result" | grep -q "Read.*CODER_SUMMARY.md first"; then
    pass "10.4: Properly filled summary uses normal 'exists' instructions"
else
    fail "10.4: Properly filled summary should use normal 'exists' instructions"
fi

# Ensure it does NOT say "is placeholder" or "is missing" for filled summary
if echo "$result" | grep -q "CODER_SUMMARY.md is"; then
    fail "10.5: Filled summary should NOT trigger placeholder/missing state"
else
    pass "10.5: Filled summary correctly avoids placeholder/missing path"
fi

rm -f "${CODER_SUMMARY_FILE}"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "Test Results: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
    exit 1
fi

echo "PASS"
