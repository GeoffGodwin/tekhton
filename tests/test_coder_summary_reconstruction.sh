#!/usr/bin/env bash
# =============================================================================
# test_coder_summary_reconstruction.sh — Tests for _reconstruct_coder_summary function
#
# Tests the _reconstruct_coder_summary function which synthesizes a minimal
# CODER_SUMMARY.md from git state when the coder fails to produce or maintain it.
#
# Tests:
#   1. Function creates CODER_SUMMARY.md file
#   2. Default status is COMPLETE
#   3. Explicit status parameter is used
#   4. Tracked file modifications are listed
#   5. Untracked files are listed
#   6. Mixed tracked and untracked files are handled
#   7. Output includes git diff summary
#   8. Status INCOMPLETE works correctly
#   9. No changes scenario (empty repository)
#   10. Large number of files is truncated to 30
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Initialize test directory as a git repository
cd "$TMPDIR_TEST"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

# Source required libraries
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder.sh"

# Initialize with a base commit
echo "# Test project" > README.md
git add README.md
git commit -q -m "Initial commit"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Test 1: Function creates CODER_SUMMARY.md file
# =============================================================================
echo "=== Test 1: Creates CODER_SUMMARY.md file ==="

# Create a modification
echo "modified content" > README.md
git add README.md
git commit -q -m "Modify README"

_reconstruct_coder_summary > /dev/null 2>&1

if [[ -f "CODER_SUMMARY.md" ]]; then
    pass "1.1: CODER_SUMMARY.md file is created"
else
    fail "1.1: CODER_SUMMARY.md should be created"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 2: Default status is COMPLETE
# =============================================================================
echo "=== Test 2: Default status is COMPLETE ==="

_reconstruct_coder_summary > /dev/null 2>&1

if grep -q "## Status: COMPLETE" CODER_SUMMARY.md 2>/dev/null; then
    pass "2.1: Default status is COMPLETE"
else
    fail "2.1: Default status should be COMPLETE"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 3: Explicit status parameter is used
# =============================================================================
echo "=== Test 3: Explicit status parameter is used ==="

_reconstruct_coder_summary "FAILED" > /dev/null 2>&1

if grep -q "## Status: FAILED" CODER_SUMMARY.md 2>/dev/null; then
    pass "3.1: Explicit status FAILED is used"
else
    fail "3.1: Should use FAILED status from parameter"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 4: Tracked file modifications are listed
# =============================================================================
echo "=== Test 4: Tracked file modifications are listed ==="

# Make a fresh change to a tracked file (don't commit yet)
git reset --hard HEAD -q
echo "uncommitted change to README" >> README.md

_reconstruct_coder_summary > /dev/null 2>&1

if grep -q "README.md" CODER_SUMMARY.md 2>/dev/null; then
    pass "4.1: Modified tracked file is listed"
else
    fail "4.1: Should list modified tracked files"
fi

if grep -q "## Files Modified" CODER_SUMMARY.md 2>/dev/null; then
    pass "4.2: Files Modified section exists"
else
    fail "4.2: Should have Files Modified section"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 5: Untracked files are listed
# =============================================================================
echo "=== Test 5: Untracked files are listed ==="

# Create untracked files
echo "new file 1" > new_file.ts
echo "new file 2" > another_file.js

_reconstruct_coder_summary > /dev/null 2>&1

if grep -q "new_file.ts" CODER_SUMMARY.md 2>/dev/null; then
    pass "5.1: Untracked new file is listed"
else
    fail "5.1: Should list untracked new files"
fi

if grep -q "## New Files Created" CODER_SUMMARY.md 2>/dev/null; then
    pass "5.2: New Files Created section exists"
else
    fail "5.2: Should have New Files Created section"
fi

rm -f CODER_SUMMARY.md new_file.ts another_file.js

# =============================================================================
# Test 6: Mixed tracked and untracked files are handled
# =============================================================================
echo "=== Test 6: Mixed tracked and untracked files are handled ==="

# Create a new tracked file
echo "tracked content" > tracked.py
git add tracked.py
git commit -q -m "Add tracked.py"

# Modify it
echo "modified tracked content" > tracked.py

# Create an untracked file
echo "untracked content" > untracked.py

_reconstruct_coder_summary > /dev/null 2>&1

if grep -q "tracked.py" CODER_SUMMARY.md 2>/dev/null; then
    pass "6.1: Tracked file is in Files Modified section"
else
    fail "6.1: Should list tracked files"
fi

if grep -q "untracked.py" CODER_SUMMARY.md 2>/dev/null; then
    pass "6.2: Untracked file is in New Files Created section"
else
    fail "6.2: Should list untracked files"
fi

rm -f CODER_SUMMARY.md tracked.py untracked.py

# =============================================================================
# Test 7: Output includes git diff summary
# =============================================================================
echo "=== Test 7: Output includes git diff summary ==="

# Make a change
echo "additional changes" > README.md

_reconstruct_coder_summary > /dev/null 2>&1

if grep -q "## Git Diff Summary" CODER_SUMMARY.md 2>/dev/null; then
    pass "7.1: Git Diff Summary section exists"
else
    fail "7.1: Should have Git Diff Summary section"
fi

# The diff summary should have a code block
if grep -q '```' CODER_SUMMARY.md 2>/dev/null; then
    pass "7.2: Diff summary is wrapped in code block"
else
    fail "7.2: Diff summary should be in code block"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 8: Status INCOMPLETE works correctly
# =============================================================================
echo "=== Test 8: Status INCOMPLETE works correctly ==="

_reconstruct_coder_summary "INCOMPLETE" > /dev/null 2>&1

if grep -q "## Status: INCOMPLETE" CODER_SUMMARY.md 2>/dev/null; then
    pass "8.1: Status INCOMPLETE is set correctly"
else
    fail "8.1: Should use INCOMPLETE status from parameter"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 9: No changes scenario (empty working directory)
# =============================================================================
echo "=== Test 9: No changes scenario ==="

# Reset to clean state
git reset --hard HEAD -q
git clean -fd -q

_reconstruct_coder_summary > /dev/null 2>&1

if [[ -f "CODER_SUMMARY.md" ]]; then
    pass "9.1: File is created even with no changes"
else
    fail "9.1: File should be created even with no changes"
fi

if grep -q "## Status: COMPLETE" CODER_SUMMARY.md 2>/dev/null; then
    pass "9.2: Status is set in no-changes scenario"
else
    fail "9.2: Status should be set"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 10: Reconstructed summary includes documentation
# =============================================================================
echo "=== Test 10: Reconstructed summary includes documentation ==="

echo "test change" > README.md

_reconstruct_coder_summary > /dev/null 2>&1

if grep -q "CODER_SUMMARY.md was reconstructed by the pipeline" CODER_SUMMARY.md 2>/dev/null; then
    pass "10.1: Reconstructed summary includes explanation"
else
    fail "10.1: Should explain that summary was reconstructed"
fi

if grep -q "## Remaining Work" CODER_SUMMARY.md 2>/dev/null; then
    pass "10.2: Remaining Work section exists"
else
    fail "10.2: Should have Remaining Work section"
fi

rm -f CODER_SUMMARY.md

# =============================================================================
# Test 11: Multiple file modifications are all listed
# =============================================================================
echo "=== Test 11: Multiple file modifications are tracked ==="

# Create multiple files and modify them
echo "file 1" > src_file1.ts
echo "file 2" > src_file2.ts
echo "file 3" > src_file3.ts
mkdir -p src
echo "source 1" > src/index.ts

_reconstruct_coder_summary > /dev/null 2>&1

# At least some of the files should be listed (up to 30)
file_count=0
for file in src_file1.ts src_file2.ts src_file3.ts src/index.ts; do
    if grep -q "$file" CODER_SUMMARY.md 2>/dev/null; then
        file_count=$((file_count + 1))
    fi
done

if [[ $file_count -ge 2 ]]; then
    pass "11.1: Multiple files are tracked in summary"
else
    fail "11.1: Should track multiple files"
fi

rm -f CODER_SUMMARY.md src_file1.ts src_file2.ts src_file3.ts src/index.ts

# =============================================================================
# Test 12: File list is capped at 30 items
# =============================================================================
echo "=== Test 12: File list is capped at 30 items ==="

# Create 50 new files
for i in {1..50}; do
    echo "content $i" > "file_$i.txt"
done

_reconstruct_coder_summary > /dev/null 2>&1

# Count how many files are listed (use -- to prevent dash in pattern from being treated as option)
listed_files=$(grep -c -- '- file_' CODER_SUMMARY.md 2>/dev/null || echo 0)

if [[ $listed_files -eq 30 ]]; then
    pass "12.1: Files listed is capped at exactly 30 (found $listed_files)"
else
    fail "12.1: Files should be capped at exactly 30 (found $listed_files)"
fi

# Cleanup
for i in {1..50}; do
    rm -f "file_$i.txt"
done
rm -f CODER_SUMMARY.md

# =============================================================================
# Test 13: Excluded files are not listed
# =============================================================================
echo "=== Test 13: Excluded files like .claude/logs are not listed ==="

# Create excluded directories
mkdir -p .claude/logs
echo "log content" > .claude/logs/test.log

_reconstruct_coder_summary > /dev/null 2>&1

if ! grep -q ".claude/logs" CODER_SUMMARY.md 2>/dev/null; then
    pass "13.1: .claude/logs files are excluded"
else
    fail "13.1: .claude/logs files should be excluded"
fi

rm -f CODER_SUMMARY.md
rm -rf .claude/logs

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
