#!/usr/bin/env bash
# Test: lib/indexer.sh — get_repo_map_slice() tighter basename+suffix matching
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

warn() { echo "[WARN] $*" >&2; }
log()  { echo "[LOG] $*" >&2; }

PROJECT_DIR="/tmp"
export PROJECT_DIR

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer.sh"

# Shared map for suffix/basename tests
REPO_MAP_CONTENT="## src/lib/indexer.sh
  indexer_available()
  run_repo_map()

## lib/indexer.sh
  check_indexer_available()

## lib/common.sh
  log()
  warn()

## src/models/user.py
  class User

## src/bar_foo.py
  def bar_func()"
export REPO_MAP_CONTENT

# =============================================================================
# Exact match
# =============================================================================

echo "=== get_repo_map_slice: exact match ==="

slice=$(get_repo_map_slice "lib/common.sh")

if echo "$slice" | grep -q "## lib/common.sh"; then
    pass "exact match returns the exact section"
else
    fail "exact match should return 'lib/common.sh' section, got: '${slice}'"
fi

if ! echo "$slice" | grep -q "## src/lib/indexer.sh"; then
    pass "exact match does not return similar-path section"
else
    fail "exact match should not return src/lib/indexer.sh, got: '${slice}'"
fi

# =============================================================================
# Suffix match: map path ends with /requested
# =============================================================================

echo "=== get_repo_map_slice: path suffix match ==="

# Request "lib/indexer.sh" — should match "## lib/indexer.sh" (exact)
# but NOT "## src/lib/indexer.sh" unless suffix also matches
slice=$(get_repo_map_slice "lib/indexer.sh")

if echo "$slice" | grep -q "## lib/indexer.sh"; then
    pass "suffix match: includes lib/indexer.sh"
else
    fail "suffix match should include lib/indexer.sh, got: '${slice}'"
fi

# =============================================================================
# Basename match: requesting just a filename matches any path with that name
# =============================================================================

echo "=== get_repo_map_slice: basename match ==="

# Requesting "indexer.sh" should match both "## src/lib/indexer.sh" and "## lib/indexer.sh"
slice=$(get_repo_map_slice "indexer.sh")

if echo "$slice" | grep -q "## src/lib/indexer.sh"; then
    pass "basename match includes src/lib/indexer.sh"
else
    fail "basename match should include src/lib/indexer.sh, got: '${slice}'"
fi

if echo "$slice" | grep -q "## lib/indexer.sh"; then
    pass "basename match includes lib/indexer.sh"
else
    fail "basename match should include lib/indexer.sh, got: '${slice}'"
fi

if ! echo "$slice" | grep -q "## lib/common.sh"; then
    pass "basename match does not include unrelated common.sh"
else
    fail "basename match should not include common.sh, got: '${slice}'"
fi

# =============================================================================
# No false positive from substring: foo.py should NOT match bar_foo.py
# =============================================================================

echo "=== get_repo_map_slice: no substring false positive ==="

# foo.py should NOT match bar_foo.py (different basename)
slice=$(get_repo_map_slice "foo.py" 2>/dev/null || true)

if ! echo "$slice" | grep -q "## src/bar_foo.py"; then
    pass "foo.py does not falsely match bar_foo.py (no substring match)"
else
    fail "foo.py should not match bar_foo.py via substring, got: '${slice}'"
fi

# =============================================================================
# No false positive: user.py should NOT match bar_user.py
# =============================================================================

echo "=== get_repo_map_slice: exact basename match, not suffix of basename ==="

REPO_MAP_CONTENT="## src/user.py
  class User

## src/superuser.py
  class SuperUser"
export REPO_MAP_CONTENT

slice=$(get_repo_map_slice "user.py" 2>/dev/null || true)

if echo "$slice" | grep -q "## src/user.py"; then
    pass "user.py matches src/user.py (basename match)"
else
    fail "user.py should match src/user.py, got: '${slice}'"
fi

if ! echo "$slice" | grep -q "## src/superuser.py"; then
    pass "user.py does not falsely match superuser.py (basename must be exact)"
else
    fail "user.py should not match superuser.py, got: '${slice}'"
fi

# Restore shared map
REPO_MAP_CONTENT="## src/lib/indexer.sh
  indexer_available()
  run_repo_map()

## lib/indexer.sh
  check_indexer_available()

## lib/common.sh
  log()
  warn()

## src/models/user.py
  class User

## src/bar_foo.py
  def bar_func()"
export REPO_MAP_CONTENT

# =============================================================================
# Full path requested matches via suffix: request "models/user.py"
# =============================================================================

echo "=== get_repo_map_slice: full path suffix match ==="

slice=$(get_repo_map_slice "models/user.py")

if echo "$slice" | grep -q "## src/models/user.py"; then
    pass "full path suffix match: models/user.py matches src/models/user.py"
else
    fail "models/user.py should match src/models/user.py via suffix, got: '${slice}'"
fi

if ! echo "$slice" | grep -q "## lib/common.sh"; then
    pass "full path suffix match: does not include unrelated sections"
else
    fail "full path suffix match should not include common.sh, got: '${slice}'"
fi

# =============================================================================
# No match returns 1
# =============================================================================

echo "=== get_repo_map_slice: no match returns 1 ==="

if get_repo_map_slice "completely_absent.py" >/dev/null 2>&1; then
    fail "nonexistent file should return exit 1"
else
    pass "nonexistent file returns exit 1"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
