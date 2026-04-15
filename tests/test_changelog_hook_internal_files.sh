#!/usr/bin/env bash
# =============================================================================
# test_changelog_hook_internal_files.sh — M77 coverage gap
#
# Tests _hook_changelog_append behavior when only Tekhton's internal pipeline
# files (CODER_SUMMARY.md, REVIEWER_REPORT.md, etc.) are uncommitted but no
# project code was modified.
#
# The reviewer identified: the git status --porcelain zero-diff guard sees
# internal pipeline artifacts as "changes" and the hook fires even when no
# user-facing code changed.  This file documents that behavior and verifies
# all surrounding guards work correctly.
#
# Tests:
#   1. exit_code != 0  → skip (never writes changelog)
#   2. CHANGELOG_ENABLED=false  → skip
#   3. FINAL_CHECK_RESULT != 0  → skip
#   4. Clean git state (all files committed)  → skip (zero-diff guard)
#   5. Only internal pipeline files uncommitted  → hook FIRES (coverage gap)
#   6. docs/chore/test task type  → skip (no changelog for non-user-facing)
#   7. Empty version string  → skip
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# Save original working directory so cd/restore works safely
ORIG_DIR="$(pwd)"

# ---------------------------------------------------------------------------
# Stub logging functions
# ---------------------------------------------------------------------------
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# ---------------------------------------------------------------------------
# Inline _infer_commit_type (from hooks.sh) to avoid sourcing hooks.sh
# and pulling in its many optional dependencies.
# ---------------------------------------------------------------------------
_infer_commit_type() {
    local task="$1"
    local prefix="feat"
    if echo "$task" | grep -qi "^fix"; then prefix="fix"
    elif echo "$task" | grep -qi "^refactor"; then prefix="refactor"
    elif echo "$task" | grep -qi "^test"; then prefix="test"
    elif echo "$task" | grep -qi "^chore"; then prefix="chore"
    elif echo "$task" | grep -qi "^docs"; then prefix="docs"
    elif echo "$task" | grep -qi "^security"; then prefix="security"
    elif echo "$task" | grep -qi "^deprecat"; then prefix="deprecate"
    elif echo "$task" | grep -qi "^remov"; then prefix="remove"
    elif echo "$task" | grep -qi "^perf"; then prefix="perf"
    fi
    echo "$prefix"
}

# Stub parse_current_version — return a fixed version without needing
# .claude/project_version.cfg in the temp repo.
parse_current_version() { echo "1.2.3"; }

# ---------------------------------------------------------------------------
# Source the implementation under test
# ---------------------------------------------------------------------------
# shellcheck source=../lib/changelog.sh
source "${TEKHTON_HOME}/lib/changelog.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _make_repo DIR
#   Initialises a minimal git repo with one committed project file.
_make_repo() {
    local dir="$1"
    mkdir -p "$dir/${TEKHTON_DIR}"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    echo "# Project" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
}

# _write_changelog DIR
#   Creates a canonical CHANGELOG.md stub in DIR.
_write_changelog() {
    local dir="$1"
    cat > "$dir/CHANGELOG.md" <<'CLEOF'
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]
CLEOF
}

# _commit_changelog DIR
#   Adds and commits an existing CHANGELOG.md so git state is clean.
_commit_changelog() {
    local dir="$1"
    git -C "$dir" add CHANGELOG.md
    git -C "$dir" commit -q -m "add changelog"
}

# _write_summary DIR
#   Creates CODER_SUMMARY.md with a recognisable "What Was Implemented" line.
_write_summary() {
    local dir="$1"
    cat > "$dir/${TEKHTON_DIR}/CODER_SUMMARY.md" <<'CSEOF'
## Status: COMPLETE

## What Was Implemented
- Updated pipeline artifact processing
CSEOF
}

# _set_env DIR
#   Exports the pipeline globals _hook_changelog_append reads.
_set_env() {
    local dir="$1"
    PROJECT_DIR="$dir"
    CHANGELOG_FILE="CHANGELOG.md"
    CHANGELOG_ENABLED="true"
    FINAL_CHECK_RESULT=0
    TASK="feat: add pipeline features"
    _CURRENT_MILESTONE=""
    CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
}

# _call_hook DIR EXIT_CODE
#   cds into DIR, calls _hook_changelog_append EXIT_CODE, then returns here.
_call_hook() {
    local dir="$1"
    local code="$2"
    cd "$dir"
    _hook_changelog_append "$code"
    cd "$ORIG_DIR"
}

# ===========================================================================
# Test 1: exit_code != 0 → hook must skip regardless of changes present
# ===========================================================================
echo "=== 1: exit_code=1 → skip ==="
P="${TEST_ROOT}/t1"
_make_repo "$P"
_write_changelog "$P"
_write_summary "$P"   # untracked → git status non-empty
_set_env "$P"
_call_hook "$P" 1
grep -q '\[1\.2\.3\]' "$P/CHANGELOG.md" \
    && fail "exit_code=1: entry was written (should be skipped)" \
    || pass "exit_code=1: entry correctly not written"

# ===========================================================================
# Test 2: CHANGELOG_ENABLED=false → skip
# ===========================================================================
echo "=== 2: CHANGELOG_ENABLED=false → skip ==="
P="${TEST_ROOT}/t2"
_make_repo "$P"
_write_changelog "$P"
_write_summary "$P"
_set_env "$P"
CHANGELOG_ENABLED="false"
_call_hook "$P" 0
grep -q '\[1\.2\.3\]' "$P/CHANGELOG.md" \
    && fail "CHANGELOG_ENABLED=false: entry was written" \
    || pass "CHANGELOG_ENABLED=false: entry correctly not written"

# ===========================================================================
# Test 3: FINAL_CHECK_RESULT != 0 → skip
# ===========================================================================
echo "=== 3: FINAL_CHECK_RESULT=1 → skip ==="
P="${TEST_ROOT}/t3"
_make_repo "$P"
_write_changelog "$P"
_write_summary "$P"
_set_env "$P"
FINAL_CHECK_RESULT=1
_call_hook "$P" 0
grep -q '\[1\.2\.3\]' "$P/CHANGELOG.md" \
    && fail "FINAL_CHECK_RESULT=1: entry was written" \
    || pass "FINAL_CHECK_RESULT=1: entry correctly not written"

# ===========================================================================
# Test 4: Clean git state (all files committed) → zero-diff guard skips hook
# ===========================================================================
echo "=== 4: clean git state → zero-diff guard skips ==="
P="${TEST_ROOT}/t4"
_make_repo "$P"
_write_changelog "$P"
_commit_changelog "$P"
# No untracked/modified files now
_set_env "$P"
_call_hook "$P" 0
grep -q '\[1\.2\.3\]' "$P/CHANGELOG.md" \
    && fail "zero-diff: entry written on clean git state" \
    || pass "zero-diff: entry correctly skipped on clean git state"

# ===========================================================================
# Test 5: Only internal pipeline files uncommitted → hook FIRES
#
# This is the coverage gap identified by the reviewer:
# Tekhton's own artifacts (CODER_SUMMARY.md, REVIEWER_REPORT.md, etc.) are
# untracked at hook-execution time.  git status --porcelain is non-empty even
# when no project code changed, so the zero-diff guard does NOT prevent the
# hook from writing a changelog entry.
# ===========================================================================
echo "=== 5: internal pipeline files only → hook fires (coverage gap) ==="
P="${TEST_ROOT}/t5"
_make_repo "$P"
_write_changelog "$P"
_commit_changelog "$P"   # commit changelog → project code is fully clean

# Simulate internal pipeline artifacts written by the run (not committed)
_write_summary "$P"                                                   # .tekhton/CODER_SUMMARY.md
printf '## Verdict: APPROVED\n' > "$P/${TEKHTON_DIR}/REVIEWER_REPORT.md"  # untracked
printf '## Verdict: APPROVED\n' > "$P/${TEKHTON_DIR}/TESTER_REPORT.md"    # untracked

# Verify setup: git sees the internal files but not the project code
status_output=$(git -C "$P" status --porcelain 2>/dev/null)

# git status --porcelain groups untracked files by directory, so look for
# the .tekhton/ directory rather than individual files inside it.
echo "$status_output" | grep -q "${TEKHTON_DIR}" \
    && pass "setup: ${TEKHTON_DIR}/ appears in git status (contains CODER_SUMMARY.md)" \
    || fail "setup: ${TEKHTON_DIR}/ missing from git status (test setup error)"

echo "$status_output" | grep -q "README.md" \
    && fail "setup: README.md unexpectedly appears in git status" \
    || pass "setup: README.md not in git status (project code is clean)"

_set_env "$P"
_call_hook "$P" 0

# The hook must have fired and written an entry (documented current behavior)
grep -q '\[1\.2\.3\]' "$P/CHANGELOG.md" \
    && pass "internal-files-only: hook fired and wrote changelog entry (documented behavior)" \
    || fail "internal-files-only: expected changelog entry but none was written"

# The entry bullet should come from the CODER_SUMMARY.md implemented section
grep -q 'pipeline artifact' "$P/CHANGELOG.md" \
    && pass "internal-files-only: bullet from CODER_SUMMARY.md present in entry" \
    || fail "internal-files-only: expected bullet 'pipeline artifact' in entry"

# The entry must appear AFTER [Unreleased], preserving document order
unreleased_line=$(grep -n '## \[Unreleased\]' "$P/CHANGELOG.md" | cut -d: -f1)
version_line=$(grep -n '## \[1\.2\.3\]' "$P/CHANGELOG.md" | cut -d: -f1)
[[ -n "$unreleased_line" && -n "$version_line" && "$version_line" -gt "$unreleased_line" ]] \
    && pass "internal-files-only: version entry is positioned after [Unreleased]" \
    || fail "internal-files-only: version entry position incorrect (unreleased=$unreleased_line version=$version_line)"

# ===========================================================================
# Test 6: docs/chore/test task types → hook skips (no changelog for non-user-facing)
# ===========================================================================
echo "=== 6: non-user-facing task types → skip ==="
for skip_task in "docs: update README" "chore: bump deps" "test: add unit tests"; do
    P="${TEST_ROOT}/skip_${skip_task%% *}"
    _make_repo "$P"
    _write_changelog "$P"
    _write_summary "$P"   # untracked → git status non-empty
    _set_env "$P"
    TASK="$skip_task"
    _call_hook "$P" 0
    grep -q '\[1\.2\.3\]' "$P/CHANGELOG.md" \
        && fail "task='$skip_task': entry was written (should be skipped)" \
        || pass "task='$skip_task': entry correctly not written"
done

# ===========================================================================
# Test 7: parse_current_version returns empty → skip (no version to write)
# ===========================================================================
echo "=== 7: empty version → skip ==="
P="${TEST_ROOT}/t7"
_make_repo "$P"
_write_changelog "$P"
_write_summary "$P"

# Override to return empty version for this test only
parse_current_version() { echo ""; }

_set_env "$P"
_call_hook "$P" 0

grep -qE '## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$P/CHANGELOG.md" \
    && fail "empty version: entry was written without a version" \
    || pass "empty version: no entry written when version is empty"

# Restore stub for completeness (no further tests, but good practice)
parse_current_version() { echo "1.2.3"; }

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
