#!/usr/bin/env bash
# =============================================================================
# test_hooks_diff_stat_portability.sh
#
# Tests that generate_commit_message() correctly separates git diff --stat
# file lines from the summary line using the portable awk replacement for
# the GNU-only `head -n -1`.
#
# Verifies:
#   1. File lines appear in "Files changed:" section
#   2. Summary line appears after file lines (not duplicated in file list)
#   3. With a single-file diff, the one file line appears and summary is separate
#   4. With 16+ files, output is capped at 15 file lines (head -15)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Set up a git repo in TMPDIR
cd "$TMPDIR"
git init -q
git config user.email "test@tekhton.test"
git config user.name "Tekhton Test"

# Source dependencies
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

assert_count() {
    local name="$1" pattern="$2" expected="$3" actual="$4"
    local count
    count=$(echo "$actual" | grep -cF "$pattern" || true)
    if [ "$count" -ne "$expected" ]; then
        echo "FAIL: $name — expected $expected occurrences of '$pattern', got $count"
        echo "  output: $(echo "$actual" | head -20)"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: Two-file diff — file lines appear, summary not duplicated
# =============================================================================
# Create and commit two files, then modify them
echo "line1" > file_a.txt
echo "line1" > file_b.txt
git add file_a.txt file_b.txt
git commit -q -m "initial"

# Modify both files
echo "line1 modified" > file_a.txt
echo "line1 modified" > file_b.txt
git add file_a.txt file_b.txt

MSG=$(generate_commit_message "feat: update files")

# "Files changed:" header must appear
assert_contains "two-file: header present" "Files changed:" "$MSG"
# Both file names must appear
assert_contains "two-file: file_a.txt listed" "file_a.txt" "$MSG"
assert_contains "two-file: file_b.txt listed" "file_b.txt" "$MSG"
# Summary line (N files changed) must appear
assert_contains "two-file: summary line present" "files changed" "$MSG"
# Summary must appear exactly once — not duplicated in file list
assert_count "two-file: summary not duplicated" "files changed" 1 "$MSG"

echo "✓ Test 1: two-file diff — file lines and summary correct"

# =============================================================================
# Test 2: Single-file diff — one file line, summary separate
# =============================================================================
git reset -q HEAD file_b.txt
git checkout -q -- file_b.txt

MSG=$(generate_commit_message "feat: update file_a only")

assert_contains "single-file: header present" "Files changed:" "$MSG"
assert_contains "single-file: file_a.txt listed" "file_a.txt" "$MSG"
assert_contains "single-file: summary line present" "file changed" "$MSG"
# Summary must appear exactly once
assert_count "single-file: summary not duplicated" "file changed" 1 "$MSG"
# file_b.txt was not staged, must not appear
assert_not_contains "single-file: unstaged file absent" "file_b.txt" "$MSG"

echo "✓ Test 2: single-file diff — file line and summary correct"

# =============================================================================
# Test 3: Summary line is NOT listed as a file line
#
# The awk 'NR>1{print prev} {prev=$0}' pattern gives all lines except the last.
# Verify the summary (which contains "file changed" or "files changed,") does
# NOT appear in the portion before the final summary line.
# =============================================================================
# Still have file_a.txt staged from test 2
MSG=$(generate_commit_message "feat: portability check")

# Extract lines between "Files changed:" and the summary (exclusive)
# The summary is always the last line of the files-changed block
file_lines_section=$(echo "$MSG" | awk '/^Files changed:/{found=1; next} found && /file[s]? changed/{exit} found{print}')

# The summary text must NOT appear in the file lines section
if echo "$file_lines_section" | grep -qF "file changed"; then
    echo "FAIL: Test 3 — summary line leaked into file lines section"
    echo "  file_lines_section: $file_lines_section"
    FAIL=1
else
    echo "✓ Test 3: summary line is not duplicated in file list"
fi

# =============================================================================
# Test 4: More than 15 files — output capped at 15 file lines
# =============================================================================
git reset -q HEAD  # unstage everything

# Create 16 new files and stage them
for i in $(seq 1 16); do
    echo "content $i" > "bulk_file_${i}.txt"
done
git add bulk_file_*.txt

MSG=$(generate_commit_message "feat: add many files")

assert_contains "bulk: header present" "Files changed:" "$MSG"
assert_contains "bulk: summary present" "files changed" "$MSG"

# Count file_N lines — should be capped at 15
file_line_count=$(echo "$MSG" | grep -cE "bulk_file_[0-9]+\.txt" || true)
if [ "$file_line_count" -le 15 ]; then
    echo "✓ Test 4: file lines capped at 15 (got $file_line_count)"
else
    echo "FAIL: Test 4 — expected ≤15 file lines, got $file_line_count"
    FAIL=1
fi

# =============================================================================
# Summary
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "PASS"
else
    exit 1
fi
