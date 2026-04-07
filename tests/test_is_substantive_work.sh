#!/usr/bin/env bash
# =============================================================================
# test_is_substantive_work.sh — Tests for is_substantive_work()
#
# Tests:
#   1. No git changes → returns false
#   2. Modified file + summary >= 20 lines → returns true
#   3. Modified file + diff >= 50 lines → returns true (even with short summary)
#   4. Modified file + short summary + small diff → returns false
#   5. Untracked files with substantial content → returns true
#   5b. Untracked files with tiny content → returns false
#   5c. Large untracked code files (no summary) → returns true
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# agent_helpers.sh globals
LAST_AGENT_NULL_RUN=false
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""

# Helper: initialize a fresh git repo in a temp dir, returning the path
_make_git_repo() {
    local repo
    repo=$(mktemp -d "${TMPDIR_TEST}/gitrepo.XXXXXX")
    (
        cd "$repo"
        git init -q .
        git config user.email "test@tekhton"
        git config user.name "Tekhton Test"
        # Initial commit so HEAD exists
        echo "initial" > initial.txt
        git add .
        git commit -q -m "init"
    )
    echo "$repo"
}

# Helper: run is_substantive_work in a subshell with the given working directory
# Returns 0 if substantive, 1 if not
_check_substantive() {
    local workdir="$1"
    (
        cd "$workdir"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/common.sh"
        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/agent_helpers.sh"
        is_substantive_work
    )
}

# =============================================================================
# Test 1: Clean git repo (no uncommitted changes) → returns false
# =============================================================================
echo "=== Test 1: No git changes → false ==="

REPO=$(_make_git_repo)

if ! _check_substantive "$REPO" 2>/dev/null; then
    pass "1.1: Clean repo → is_substantive_work returns false"
else
    fail "1.1: Clean repo should return false (no changes)"
fi

# =============================================================================
# Test 2: Modified file + summary >= 20 lines → returns true
# =============================================================================
echo "=== Test 2: Modified file + long summary → true ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    # Modify a tracked file
    echo "change line" >> initial.txt

    # Create CODER_SUMMARY.md with >= 20 lines
    {
        echo "## Status: IN PROGRESS"
        for i in $(seq 1 20); do
            echo "- Implemented item $i"
        done
    } > CODER_SUMMARY.md
)

if _check_substantive "$REPO" 2>/dev/null; then
    pass "2.1: Modified file + 21-line summary → is_substantive_work returns true"
else
    fail "2.1: Should return true: 1 modified file + summary >= 20 lines"
fi

# =============================================================================
# Test 3: Modified file + large diff (>= 50 lines) but short summary → true
# =============================================================================
echo "=== Test 3: Modified file + large diff + short summary → true ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    # Create a file with many lines, commit it, then modify it heavily
    for i in $(seq 1 60); do
        echo "original line $i"
    done > bigfile.txt
    git add bigfile.txt
    git commit -q -m "add bigfile"

    # Replace content — this creates a large diff (60 deletions + 60 additions = 120 diff lines)
    for i in $(seq 1 60); do
        echo "modified line $i"
    done > bigfile.txt

    # Short CODER_SUMMARY.md (< 20 lines)
    printf "## Status: IN PROGRESS\n- item 1\n- item 2\n" > CODER_SUMMARY.md
)

if _check_substantive "$REPO" 2>/dev/null; then
    pass "3.1: Modified file + large diff → is_substantive_work returns true"
else
    fail "3.1: Should return true: 1 modified file + diff >= 50 lines"
fi

# =============================================================================
# Test 4: Modified file + short summary + small diff → false
# =============================================================================
echo "=== Test 4: Modified file + short summary + small diff → false ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    # Small change (< 50 diff lines)
    echo "one line change" >> initial.txt

    # Short CODER_SUMMARY.md (< 20 lines)
    printf "## Status: IN PROGRESS\n- item 1\n- item 2\n" > CODER_SUMMARY.md
)

if ! _check_substantive "$REPO" 2>/dev/null; then
    pass "4.1: Modified file + short summary + small diff → returns false"
else
    fail "4.1: Should return false: summary < 20 lines AND diff < 50 lines"
fi

# =============================================================================
# Test 5: Untracked files with large summary → returns true (new code written)
# =============================================================================
echo "=== Test 5: Untracked files + large summary → true ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    # Create CODER_SUMMARY.md with many lines — untracked new file counts now
    {
        echo "## Status: IN PROGRESS"
        for i in $(seq 1 30); do
            echo "- item $i"
        done
    } > CODER_SUMMARY.md
    # Do NOT modify any tracked file — only untracked files exist
)

if _check_substantive "$REPO" 2>/dev/null; then
    pass "5.1: Untracked summary (31 lines) → returns true (untracked files count)"
else
    fail "5.1: Should return true when untracked files have substantial content"
fi

# =============================================================================
# Test 5b: Untracked files with tiny content → returns false
# =============================================================================
echo "=== Test 5b: Untracked files + tiny content → false ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    # Small untracked file — below threshold (< 50 lines, no summary >= 20)
    printf "## Status: IN PROGRESS\n- item 1\n" > CODER_SUMMARY.md
)

if ! _check_substantive "$REPO" 2>/dev/null; then
    pass "5b.1: Tiny untracked file → returns false (below thresholds)"
else
    fail "5b.1: Should return false when untracked files are too small"
fi

# =============================================================================
# Test 5c: Large untracked new files (no summary) → returns true
# =============================================================================
echo "=== Test 5c: Large untracked code files → true ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    # Create new source file with significant content (60 lines)
    for i in $(seq 1 60); do
        echo "function impl_$i() { return $i; }"
    done > new_module.sh
)

if _check_substantive "$REPO" 2>/dev/null; then
    pass "5c.1: Large untracked file (60 lines) → returns true"
else
    fail "5c.1: Should return true when untracked file has >= 50 lines"
fi

# =============================================================================
# Test 6: Exactly 1 file modified + summary exactly 20 lines → boundary case
# =============================================================================
echo "=== Test 6: Boundary: exactly 20 lines summary → true ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    echo "change" >> initial.txt

    # Exactly 20 lines
    for i in $(seq 1 20); do
        echo "- item $i"
    done > CODER_SUMMARY.md
)

if _check_substantive "$REPO" 2>/dev/null; then
    pass "6.1: Exactly 20-line summary (>= 20) → returns true"
else
    fail "6.1: 20-line summary should meet threshold (>= 20)"
fi

# =============================================================================
# Test 7: Exactly 19 lines summary + small diff → false (just below threshold)
# =============================================================================
echo "=== Test 7: Boundary: 19-line summary + small diff → false ==="

REPO=$(_make_git_repo)

(
    cd "$REPO"
    echo "small change" >> initial.txt

    # 19 lines — below threshold
    for i in $(seq 1 19); do
        echo "- item $i"
    done > CODER_SUMMARY.md
)

if ! _check_substantive "$REPO" 2>/dev/null; then
    pass "7.1: 19-line summary + small diff → returns false"
else
    fail "7.1: 19-line summary should NOT meet threshold (< 20)"
fi

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
