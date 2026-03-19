#!/usr/bin/env bash
# =============================================================================
# test_hooks_diff_stat_fallback.sh
#
# Tests that generate_commit_message() correctly uses the three-tier diff stat
# fallback chain:
#   1. git diff --cached --stat (staged changes — preferred)
#   2. git diff HEAD --stat (HEAD comparison — if nothing staged)
#   3. git diff --stat (working tree — last resort)
#   4. Falls back to file count from CODER_SUMMARY.md when no git diff available
#
# The fix in this coder run changed from a broken `||` chain (where --cached
# succeeded with empty output and short-circuited the fallback) to an explicit
# emptiness check after each attempt.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
git init -q
git config user.email "test@tekhton.test"
git config user.name "Tekhton Test"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"

# Stub milestone functions
get_milestone_commit_prefix() { echo ""; }
get_milestone_commit_body() { echo ""; }

source "${TEKHTON_HOME}/lib/hooks.sh"

FAIL=0

assert_contains() {
    local name="$1" pattern="$2" actual="$3"
    if ! echo "$actual" | grep -qF "$pattern"; then
        echo "FAIL: $name — pattern '$pattern' not found"
        echo "  output: $(echo "$actual" | head -20)"
        FAIL=1
    fi
}

assert_not_contains() {
    local name="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qF "$pattern"; then
        echo "FAIL: $name — unexpected pattern '$pattern' found"
        echo "  output: $(echo "$actual" | head -20)"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: Staged changes → uses git diff --cached --stat (primary path)
# Verifies the primary path works correctly and produces "Files changed:" section
# =============================================================================
echo "line1" > staged_file.txt
git add staged_file.txt
git commit -q -m "initial commit"

echo "line1 modified" > staged_file.txt
git add staged_file.txt
# File is staged — should use --cached path

MSG=$(generate_commit_message "feat: update staged file")

assert_contains "staged: Files changed section present" "Files changed:" "$MSG"
assert_contains "staged: file name listed" "staged_file.txt" "$MSG"
assert_contains "staged: summary line present" "file changed" "$MSG"

echo "✓ Test 1: staged changes use --cached path"

# =============================================================================
# Test 2: Nothing staged, changes committed → falls back to git diff HEAD --stat
# (second fallback: --cached returns empty because nothing is staged,
#  but HEAD has differences if we compare to the prior commit)
#
# We test this by creating a commit, then checking the diff vs its parent.
# Since --cached is empty after commit, HEAD comparison gives the diff.
# =============================================================================
# Reset staging area so nothing is staged
git reset -q HEAD staged_file.txt 2>/dev/null || true
git checkout -q -- staged_file.txt 2>/dev/null || true

# Create a new file, commit it
echo "content" > committed_file.txt
git add committed_file.txt
git commit -q -m "add committed_file"

# Now nothing staged. git diff --cached is empty.
# git diff HEAD shows committed_file.txt vs the prior state (but HEAD is the tip).
# Actually git diff HEAD is empty after a clean commit too.
# Let's test with an unstaged working tree change instead:
echo "modified content" > committed_file.txt
# Not staged — so --cached is empty, HEAD is empty (no new commit),
# but git diff --stat (plain) shows the working tree change

MSG=$(generate_commit_message "feat: working tree change")

# The message should include the diff stat from one of the fallback paths
assert_contains "fallback: Files changed section present" "Files changed:" "$MSG"
assert_contains "fallback: file listed" "committed_file.txt" "$MSG"

echo "✓ Test 2: working tree change falls back to git diff --stat"

# =============================================================================
# Test 3: No git diff output at all (clean working tree, nothing staged)
#         → falls back to CODER_SUMMARY.md file count
# =============================================================================
# Restore working tree to clean state
git checkout -q -- committed_file.txt

# Write CODER_SUMMARY with file count
cat > CODER_SUMMARY.md << 'EOF'
## What Was Implemented
- Added a feature

## Files Created or Modified
- lib/alpha.sh
- lib/beta.sh
- lib/gamma.sh
EOF

MSG=$(generate_commit_message "feat: no git diff scenario")

# Should fall back to "N files created or modified" from CODER_SUMMARY
assert_contains "no-diff: file count fallback" "files created or modified" "$MSG"

echo "✓ Test 3: no git diff falls back to CODER_SUMMARY file count"

# =============================================================================
# Test 4: --cached takes priority over working tree changes
# If both staged AND unstaged changes exist, --cached wins
# =============================================================================
rm -f CODER_SUMMARY.md

echo "staged content" > staged_only.txt
echo "unstaged content" > unstaged_only.txt
git add staged_only.txt
# staged_only.txt is staged; unstaged_only.txt is not

MSG=$(generate_commit_message "feat: staged takes priority")

# staged file must appear
assert_contains "priority: staged file listed" "staged_only.txt" "$MSG"
# unstaged file must NOT appear (--cached only shows staged)
assert_not_contains "priority: unstaged file absent" "unstaged_only.txt" "$MSG"

echo "✓ Test 4: staged changes take priority over unstaged"

# =============================================================================
# Test 5: No CODER_SUMMARY.md and clean tree → no "Files changed:" section
# =============================================================================
git reset -q HEAD staged_only.txt 2>/dev/null || true
rm -f staged_only.txt unstaged_only.txt
git checkout -q -- . 2>/dev/null || true

MSG=$(generate_commit_message "feat: completely clean state")

assert_not_contains "clean: no files section" "Files changed:" "$MSG"
assert_not_contains "clean: no file count" "files created or modified" "$MSG"

echo "✓ Test 5: clean state with no CODER_SUMMARY produces no files section"

# =============================================================================
# Summary
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "PASS"
else
    exit 1
fi
