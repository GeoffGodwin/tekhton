#!/usr/bin/env bash
# =============================================================================
# test_build_continuation_context.sh — Tests for build_continuation_context placeholder handling
#
# Tests that build_continuation_context correctly detects missing or
# placeholder-only CODER_SUMMARY.md and generates appropriate instructions
# for the continuation prompt.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Initialize test directory as a git repository
cd "$TMPDIR_TEST"
mkdir -p "${TEKHTON_DIR:-.tekhton}"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export CODER_SUMMARY_FILE
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

# Source required libraries
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/agent_helpers.sh"

# Initialize with a base commit and a code file
echo "# Test project" > README.md
git add README.md
git commit -q -m "Initial commit"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Test 1: Missing CODER_SUMMARY.md — should instruct recreation
# =============================================================================
echo "=== Test 1: Missing CODER_SUMMARY.md triggers recreation instruction ==="

# Ensure file doesn't exist
rm -f "${CODER_SUMMARY_FILE}"

# Make a code change
echo "code change" >> README.md
git add README.md
git commit -q -m "Change README"

# Call build_continuation_context for coder stage
# Args: stage (coder) turn_num max_turns prior_cumulative next_budget
context=$(build_continuation_context "coder" "1" "3" "20" "15")

# Check for recreation instruction
if echo "$context" | grep -q 'recreate it NOW'; then
    pass "1.1: Missing summary triggers 'recreate it NOW' instruction"
else
    fail "1.1: Should instruct to recreate missing CODER_SUMMARY.md"
fi

# Verify Step 1 instruction is present
if echo "$context" | grep -q 'CODER_SUMMARY.md is missing'; then
    pass "1.2: Identifies summary as missing"
else
    fail "1.2: Should identify summary as missing"
fi

# =============================================================================
# Test 2: Placeholder text in CODER_SUMMARY.md — should instruct recreation
# =============================================================================
echo "=== Test 2: Placeholder CODER_SUMMARY.md triggers recreation instruction ==="

# Create summary with placeholder
cat > "${CODER_SUMMARY_FILE}" << 'EOF'
## Status: IN PROGRESS
## What Was Implemented
(fill in as you go)
## Files Modified
(fill in as you go)
## Remaining Work
(fill in as you go)
## Notes
(fill in as you go)
EOF

# Make code changes
mkdir -p src
echo "function test() { return 1; }" > src/index.ts
git add src/index.ts
git commit -q -m "Add index"

# Call build_continuation_context
context=$(build_continuation_context "coder" "1" "3" "20" "15")

# Check for recreation instruction
if echo "$context" | grep -q 'recreate it NOW'; then
    pass "2.1: Placeholder summary triggers 'recreate it NOW' instruction"
else
    fail "2.1: Should instruct to recreate placeholder CODER_SUMMARY.md"
fi

# Verify placeholder detection
if echo "$context" | grep -q 'CODER_SUMMARY.md is placeholder'; then
    pass "2.2: Identifies summary as placeholder"
else
    fail "2.2: Should identify summary as placeholder"
fi

rm -f "${CODER_SUMMARY_FILE}" src/index.ts

# =============================================================================
# Test 3: Proper CODER_SUMMARY.md — should instruct to read first
# =============================================================================
echo "=== Test 3: Proper CODER_SUMMARY.md instructs reading ==="

# Create a properly filled summary
cat > "${CODER_SUMMARY_FILE}" << 'EOF'
## Status: IN PROGRESS
## What Was Implemented
- Added authentication module
- Fixed bug in session handling
- Created database migration scripts
## Files Modified
- src/auth/login.ts
- src/session/manager.ts
- migrations/001_init.sql
## Remaining Work
- Add unit tests for auth module
- Update documentation
EOF

# Make more code changes
echo "more code" >> src/index.ts
git add src/index.ts
git commit -q -m "Update index"

# Call build_continuation_context
context=$(build_continuation_context "coder" "1" "3" "20" "15")

# Check for read-first instruction (path may include .tekhton/ prefix)
if echo "$context" | grep -q 'CODER_SUMMARY.md first'; then
    pass "3.1: Proper summary instructs reading first"
else
    fail "3.1: Should instruct to read proper CODER_SUMMARY.md first"
fi

# Verify it does NOT instruct recreation
if echo "$context" | grep -q 'recreate it NOW'; then
    fail "3.2: Should not instruct recreation for proper summary"
else
    pass "3.2: Does not instruct recreation for proper summary"
fi

rm -f "${CODER_SUMMARY_FILE}"

# =============================================================================
# Test 4: Instructions include turn budget context
# =============================================================================
echo "=== Test 4: Continuation context includes turn budget ==="

echo "test" > test.txt
git add test.txt
git commit -q -m "Add test"

# Call with specific turn numbers
context=$(build_continuation_context "coder" "2" "3" "40" "20")

# Should mention previous attempts and turn budget
if echo "$context" | grep -q 'previous'; then
    pass "4.1: Context mentions previous attempts"
else
    fail "4.1: Should mention previous attempts"
fi

# Should include instruction about continuing efficiently
if echo "$context" | grep -q 'Continue implementing'; then
    pass "4.2: Context instructs continuing with remaining items"
else
    fail "4.2: Should instruct continuing with remaining work"
fi

rm -f test.txt

# =============================================================================
# Test 5: "update as you go" variant also detected as placeholder
# =============================================================================
echo "=== Test 5: 'update as you go' variant detected as placeholder ==="

cat > "${CODER_SUMMARY_FILE}" << 'EOF'
## Status: IN PROGRESS
## What Was Implemented
(update as you go)
## Files Modified
(update as you go)
EOF

echo "x" > file.txt
git add file.txt
git commit -q -m "Add file"

context=$(build_continuation_context "coder" "1" "3" "20" "15")

# Should detect as placeholder
if echo "$context" | grep -q 'recreate it NOW'; then
    pass "5.1: 'update as you go' variant detected as placeholder"
else
    fail "5.1: Should detect 'update as you go' as placeholder"
fi

rm -f "${CODER_SUMMARY_FILE}" file.txt

# =============================================================================
# Summary
# =============================================================================
echo
echo "══════════════════════════════════════"
echo "Passed: $PASS  Failed: $FAIL"
echo "══════════════════════════════════════"

if [[ $FAIL -eq 0 ]]; then
    exit 0
else
    exit 1
fi
