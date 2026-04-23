#!/usr/bin/env bash
# Test: `.claude/worktrees/` gitignore coverage
# Verifies that the worktree directory pattern in .gitignore prevents
# accidental git tracking of local worktrees as gitlinks.
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

cd "$TEST_TMPDIR"

# =============================================================================
# Section 1: Basic gitignore setup
# =============================================================================

# Create a test git repository
mkdir -p test_repo
cd test_repo
git init -q .
git config user.email "test@example.com"
git config user.name "Test User"

# Create .gitignore with the worktree pattern
cat > .gitignore << 'EOF'
# Tekhton runtime artifacts
.claude/PIPELINE.lock
.claude/PIPELINE_STATE.md
.claude/worktrees/
EOF

if [[ -f .gitignore ]]; then
    pass "creates .gitignore with worktree pattern"
else
    fail ".gitignore not created"
    exit 1
fi

# Verify the pattern is in the file
if grep -qF ".claude/worktrees/" .gitignore; then
    pass "worktree pattern present in .gitignore"
else
    fail "worktree pattern missing from .gitignore"
    exit 1
fi

# =============================================================================
# Section 2: git check-ignore validates the pattern
# =============================================================================

# Create a fake worktree structure
mkdir -p .claude/worktrees/test-worktree-1
echo "content" > .claude/worktrees/test-worktree-1/file.txt

# check-ignore should report this path as ignored
if git check-ignore .claude/worktrees/test-worktree-1 >/dev/null 2>&1; then
    pass "git check-ignore reports .claude/worktrees/test-worktree-1 as ignored"
else
    fail "git check-ignore: .claude/worktrees/test-worktree-1 not recognized as ignored"
fi

# Verify the exact path is ignored
if git check-ignore .claude/worktrees/test-worktree-1/file.txt >/dev/null 2>&1; then
    pass "git check-ignore reports files within worktree as ignored"
else
    fail "git check-ignore: files within worktree not recognized as ignored"
fi

# =============================================================================
# Section 3: git ls-files does not list ignored worktrees
# =============================================================================

# Add .gitignore to the index
git add .gitignore
git commit -q -m "Add gitignore"

# Verify worktree directory is not in git ls-files
if git ls-files | grep -qF ".claude/worktrees"; then
    fail "git ls-files: worktree directory appears in tracked files"
else
    pass "git ls-files: worktree directory not in tracked files"
fi

# Verify worktree files are not in git ls-files
if git ls-files | grep -qF ".claude/worktrees/test-worktree-1"; then
    fail "git ls-files: worktree files appear in tracked files"
else
    pass "git ls-files: worktree files not in tracked files"
fi

# =============================================================================
# Section 4: Confirm no mode 160000 entries for ignored worktrees
# =============================================================================

# Even if we manually try to add the worktree directory, it should be ignored
git add .claude/worktrees/ 2>/dev/null || true

# Check for mode 160000 entries (gitlinks)
if git ls-files --stage | awk '$1 == "160000"' | grep -qF ".claude/worktrees"; then
    fail "git ls-files --stage: worktree appears as mode 160000 (gitlink)"
else
    pass "git ls-files --stage: no mode 160000 entry for worktrees"
fi

# =============================================================================
# Section 5: Wildcard pattern coverage (nested paths)
# =============================================================================

# Create multiple nested worktree paths
mkdir -p .claude/worktrees/branch-a/refs/heads
mkdir -p .claude/worktrees/branch-b/refs/heads
echo "ref content" > .claude/worktrees/branch-a/refs/heads/main

# All should be ignored
if git check-ignore .claude/worktrees/branch-a >/dev/null 2>&1 && \
   git check-ignore .claude/worktrees/branch-b >/dev/null 2>&1 && \
   git check-ignore .claude/worktrees/branch-a/refs/heads/main >/dev/null 2>&1; then
    pass "gitignore pattern covers nested worktree paths"
else
    fail "gitignore pattern doesn't cover all nested worktree paths"
fi

# =============================================================================
# Section 6: Verify standard patterns still work (sanity check)
# =============================================================================

# Add other test patterns to gitignore
mkdir -p .claude
echo "lock content" > .claude/PIPELINE.lock

# Verify other patterns also work
if git check-ignore .claude/PIPELINE.lock >/dev/null 2>&1; then
    pass "other gitignore patterns still work (.claude/PIPELINE.lock)"
else
    fail "regression: other gitignore patterns broken"
fi

# =============================================================================
# Section 7: Pattern specificity (worktrees only, not entire .claude)
# =============================================================================

# Create a .claude file that should NOT be ignored
mkdir -p .claude
echo "config" > .claude/config.txt

# This should NOT be ignored (only .claude/worktrees/ is)
if ! git check-ignore .claude/config.txt >/dev/null 2>&1; then
    pass "pattern is specific: .claude/config.txt is not ignored"
else
    fail "pattern too broad: .claude/config.txt incorrectly ignored"
fi

# But if we manually try to commit it, it should work
if git add .claude/config.txt 2>/dev/null; then
    pass "can add other .claude files when worktrees pattern is in place"
    git reset .claude/config.txt >/dev/null 2>&1
else
    fail "regression: can't add other files in .claude/"
fi

# =============================================================================
# Section 8: Comment doesn't prevent pattern matching
# =============================================================================

# Verify that the pattern line isn't treated as a comment
if git check-ignore .claude/worktrees/test >/dev/null 2>&1; then
    pass "worktree pattern active (not treated as comment)"
else
    fail "worktree pattern treated as comment or missing"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
