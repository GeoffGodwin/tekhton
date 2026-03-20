#!/usr/bin/env bash
# Test: _find_source_files git path depth limit (NF<=2 awk filter)
#
# Verifies the fix to _find_source_files in detect.sh:
# git ls-files now filters to top 2 directory levels (NF<=2 in awk),
# matching the non-git fallback's -maxdepth 2 behavior.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source detection library
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

# =============================================================================
# Helper: set up a git repo with files at various depths
# =============================================================================
setup_git_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"

    # Depth 1: file at root
    touch "$repo/root.py"

    # Depth 2: file in one subdirectory (path: src/app.py — 1 slash → NF=2)
    mkdir -p "$repo/src"
    touch "$repo/src/app.py"

    # Depth 3: file nested two levels deep (path: src/utils/helpers.py — NF=3)
    mkdir -p "$repo/src/utils"
    touch "$repo/src/utils/helpers.py"

    # Depth 4: file nested three levels deep (path: src/core/db/models.py — NF=4)
    mkdir -p "$repo/src/core/db"
    touch "$repo/src/core/db/models.py"

    git -C "$repo" add .
    git -C "$repo" commit -q -m "init"
}

# =============================================================================
# Phase 1: _find_source_files in a git repo respects depth-2 limit
# =============================================================================
echo "=== _find_source_files: git path depth filter ==="

GIT_REPO="${TEST_TMPDIR}/git_repo"
setup_git_repo "$GIT_REPO"

result=$(_find_source_files "$GIT_REPO")

# root.py (NF=1) — should appear
if echo "$result" | grep -q "root.py"; then
    pass "depth-1 file (root.py) is included"
else
    fail "depth-1 file (root.py) missing from result: $result"
fi

# src/app.py (NF=2) — should appear
if echo "$result" | grep -q "src/app.py"; then
    pass "depth-2 file (src/app.py) is included"
else
    fail "depth-2 file (src/app.py) missing from result: $result"
fi

# src/utils/helpers.py (NF=3) — must NOT appear
if echo "$result" | grep -q "src/utils/helpers.py"; then
    fail "depth-3 file (src/utils/helpers.py) should be excluded by awk NF<=2 filter"
else
    pass "depth-3 file (src/utils/helpers.py) correctly excluded"
fi

# src/core/db/models.py (NF=4) — must NOT appear
if echo "$result" | grep -q "src/core/db/models.py"; then
    fail "depth-4 file (src/core/db/models.py) should be excluded by awk NF<=2 filter"
else
    pass "depth-4 file (src/core/db/models.py) correctly excluded"
fi

# =============================================================================
# Phase 2: non-git path (find -maxdepth 2) has consistent behavior
# =============================================================================
echo "=== _find_source_files: non-git path depth consistency ==="

NONGIT_DIR="${TEST_TMPDIR}/nongit_dir"
mkdir -p "$NONGIT_DIR/src/utils"
mkdir -p "$NONGIT_DIR/src/core/db"
touch "$NONGIT_DIR/root.py"
touch "$NONGIT_DIR/src/app.py"
touch "$NONGIT_DIR/src/utils/helpers.py"
touch "$NONGIT_DIR/src/core/db/models.py"

nongit_result=$(_find_source_files "$NONGIT_DIR")

# root.py — should appear
if echo "$nongit_result" | grep -q "root.py"; then
    pass "non-git depth-1 file included"
else
    fail "non-git depth-1 file missing: $nongit_result"
fi

# src/app.py — should appear (maxdepth 2 includes it)
if echo "$nongit_result" | grep -q "src/app.py"; then
    pass "non-git depth-2 file included"
else
    fail "non-git depth-2 file missing: $nongit_result"
fi

# src/utils/helpers.py — must NOT appear (beyond maxdepth 2)
if echo "$nongit_result" | grep -q "src/utils/helpers.py"; then
    fail "non-git depth-3 file should be excluded by -maxdepth 2"
else
    pass "non-git depth-3 file correctly excluded"
fi

# =============================================================================
# Phase 3: git and non-git produce consistent results for same tree
# =============================================================================
echo "=== _find_source_files: git vs non-git consistency ==="

GIT_REPO2="${TEST_TMPDIR}/git_repo2"
mkdir -p "$GIT_REPO2"
git -C "$GIT_REPO2" init -q
git -C "$GIT_REPO2" config user.email "test@test.com"
git -C "$GIT_REPO2" config user.name "Test"

mkdir -p "$GIT_REPO2/lib"
mkdir -p "$GIT_REPO2/lib/internal"
touch "$GIT_REPO2/main.sh"
touch "$GIT_REPO2/lib/utils.sh"
touch "$GIT_REPO2/lib/internal/helpers.sh"

git -C "$GIT_REPO2" add .
git -C "$GIT_REPO2" commit -q -m "init"

NONGIT_DIR2="${TEST_TMPDIR}/nongit_dir2"
mkdir -p "$NONGIT_DIR2/lib/internal"
touch "$NONGIT_DIR2/main.sh"
touch "$NONGIT_DIR2/lib/utils.sh"
touch "$NONGIT_DIR2/lib/internal/helpers.sh"

git_result2=$(_find_source_files "$GIT_REPO2")
nongit_result2=$(_find_source_files "$NONGIT_DIR2")

# Both should include main.sh and lib/utils.sh
git_has_main=$(echo "$git_result2" | grep -c "main.sh" || true)
nongit_has_main=$(echo "$nongit_result2" | grep -c "main.sh" || true)

if [[ "$git_has_main" -ge 1 ]] && [[ "$nongit_has_main" -ge 1 ]]; then
    pass "both git and non-git include depth-1 file (main.sh)"
else
    fail "depth-1 file missing — git: $git_has_main, nongit: $nongit_has_main"
fi

# Both should exclude lib/internal/helpers.sh (depth 3)
git_no_deep=$(echo "$git_result2" | grep -c "lib/internal/helpers.sh" || true)
nongit_no_deep=$(echo "$nongit_result2" | grep -c "lib/internal/helpers.sh" || true)

if [[ "$git_no_deep" -eq 0 ]] && [[ "$nongit_no_deep" -eq 0 ]]; then
    pass "both git and non-git exclude depth-3 file (lib/internal/helpers.sh)"
else
    fail "depth-3 file not consistently excluded — git count: $git_no_deep, nongit count: $nongit_no_deep"
fi

# =============================================================================
# Phase 4: _count_source_files respects the depth limit via _find_source_files
# =============================================================================
echo "=== _count_source_files: git repo only counts shallow files ==="

GIT_REPO3="${TEST_TMPDIR}/git_repo3"
mkdir -p "$GIT_REPO3"
git -C "$GIT_REPO3" init -q
git -C "$GIT_REPO3" config user.email "test@test.com"
git -C "$GIT_REPO3" config user.name "Test"

# 2 Python files at depth 1 and 2
touch "$GIT_REPO3/app.py"
mkdir -p "$GIT_REPO3/src"
touch "$GIT_REPO3/src/main.py"
# 3 Python files at depth 3+ (should be excluded)
mkdir -p "$GIT_REPO3/src/deep/nested"
touch "$GIT_REPO3/src/deep/hidden.py"
touch "$GIT_REPO3/src/deep/nested/a.py"
touch "$GIT_REPO3/src/deep/nested/b.py"

git -C "$GIT_REPO3" add .
git -C "$GIT_REPO3" commit -q -m "init"

declare -A counts=()
_count_source_files "$GIT_REPO3" counts

python_count="${counts[python]:-0}"
if [[ "$python_count" -eq 2 ]]; then
    pass "_count_source_files counts exactly 2 Python files (depth ≤ 2 only)"
elif [[ "$python_count" -lt 2 ]]; then
    fail "_count_source_files under-counts Python files: got $python_count, expected 2"
else
    fail "_count_source_files over-counts Python files: got $python_count (expected 2, depth filter not applied)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
