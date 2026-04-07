#!/usr/bin/env bash
# Test: lib/indexer.sh — validate_indexer_config() and detect_repo_languages()
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Minimal stubs so indexer.sh can be sourced without tekhton.sh
warn() { echo "[WARN] $*" >&2; }
log()  { echo "[LOG] $*" >&2; }

PROJECT_DIR="/tmp"
export PROJECT_DIR

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer.sh"

# =============================================================================
# validate_indexer_config — token budget validation
# =============================================================================

echo "=== validate_indexer_config: REPO_MAP_TOKEN_BUDGET ==="

result=$(
    REPO_MAP_TOKEN_BUDGET="2048"
    REPO_MAP_HISTORY_MAX_RECORDS="200"
    REPO_MAP_LANGUAGES="auto"
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:0"; then
    pass "valid token budget (2048) returns 0"
else
    fail "valid token budget (2048) should return 0, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET="abc"
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:1"; then
    pass "non-integer token budget 'abc' returns 1"
else
    fail "non-integer token budget 'abc' should return 1, got: ${result}"
fi

if echo "$result" | grep -q "REPO_MAP_TOKEN_BUDGET"; then
    pass "non-integer token budget produces error message mentioning REPO_MAP_TOKEN_BUDGET"
else
    fail "error message should mention REPO_MAP_TOKEN_BUDGET, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET="0"
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:1"; then
    pass "zero token budget returns 1"
else
    fail "zero token budget should return 1, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET="-5"
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:1"; then
    pass "negative token budget returns 1"
else
    fail "negative token budget should return 1, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:0"; then
    pass "empty REPO_MAP_TOKEN_BUDGET (unset) returns 0"
else
    fail "empty REPO_MAP_TOKEN_BUDGET should return 0, got: ${result}"
fi

# =============================================================================
# validate_indexer_config — history max records validation
# =============================================================================

echo "=== validate_indexer_config: REPO_MAP_HISTORY_MAX_RECORDS ==="

result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS="200"
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:0"; then
    pass "valid history max records (200) returns 0"
else
    fail "valid history max records (200) should return 0, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS="not_a_number"
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:1"; then
    pass "non-integer REPO_MAP_HISTORY_MAX_RECORDS returns 1"
else
    fail "non-integer REPO_MAP_HISTORY_MAX_RECORDS should return 1, got: ${result}"
fi

if echo "$result" | grep -q "REPO_MAP_HISTORY_MAX_RECORDS"; then
    pass "error message mentions REPO_MAP_HISTORY_MAX_RECORDS"
else
    fail "error message should mention REPO_MAP_HISTORY_MAX_RECORDS, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS="0"
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:1"; then
    pass "zero REPO_MAP_HISTORY_MAX_RECORDS returns 1"
else
    fail "zero REPO_MAP_HISTORY_MAX_RECORDS should return 1, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:0"; then
    pass "empty REPO_MAP_HISTORY_MAX_RECORDS (unset) returns 0"
else
    fail "empty REPO_MAP_HISTORY_MAX_RECORDS should return 0, got: ${result}"
fi

# =============================================================================
# validate_indexer_config — both invalid → still returns 1
# =============================================================================

echo "=== validate_indexer_config: multiple invalid fields ==="

result=$(
    REPO_MAP_TOKEN_BUDGET="bad"
    REPO_MAP_HISTORY_MAX_RECORDS="also_bad"
    REPO_MAP_LANGUAGES=""
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:1"; then
    pass "both invalid fields returns 1"
else
    fail "both invalid fields should return 1, got: ${result}"
fi

# =============================================================================
# validate_indexer_config — REPO_MAP_LANGUAGES validation
# =============================================================================

echo "=== validate_indexer_config: REPO_MAP_LANGUAGES ==="

result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES="auto"
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:0"; then
    pass "'auto' REPO_MAP_LANGUAGES returns 0"
else
    fail "'auto' REPO_MAP_LANGUAGES should return 0, got: ${result}"
fi

result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES="python,javascript,go"
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:0"; then
    pass "valid comma-separated languages returns 0"
else
    fail "valid comma-separated languages should return 0, got: ${result}"
fi

# Unknown language should warn but still return 0 (not a hard error)
result=$(
    REPO_MAP_TOKEN_BUDGET=""
    REPO_MAP_HISTORY_MAX_RECORDS=""
    REPO_MAP_LANGUAGES="cobol"
    validate_indexer_config 2>&1
    echo "exit:$?"
)
if echo "$result" | grep -q "exit:0"; then
    pass "unknown language 'cobol' returns 0 (warn only, not hard error)"
else
    fail "unknown language should warn but return 0, got: ${result}"
fi

# =============================================================================
# detect_repo_languages — basic detection
# =============================================================================

echo "=== detect_repo_languages: extension detection ==="

TMPDIR_LANG="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LANG"' EXIT

# Create files with various extensions
touch "${TMPDIR_LANG}/main.py"
touch "${TMPDIR_LANG}/app.js"
touch "${TMPDIR_LANG}/server.go"

result=$(detect_repo_languages "$TMPDIR_LANG")

if echo "$result" | grep -q "python"; then
    pass "detects python from .py files"
else
    fail "should detect python from .py files, got: '${result}'"
fi

if echo "$result" | grep -q "javascript"; then
    pass "detects javascript from .js files"
else
    fail "should detect javascript from .js files, got: '${result}'"
fi

if echo "$result" | grep -q "go"; then
    pass "detects go from .go files"
else
    fail "should detect go from .go files, got: '${result}'"
fi

# =============================================================================
# detect_repo_languages — deduplication (only one entry per language)
# =============================================================================

echo "=== detect_repo_languages: deduplication ==="

TMPDIR_DEDUP="$(mktemp -d)"

touch "${TMPDIR_DEDUP}/file1.py"
touch "${TMPDIR_DEDUP}/file2.py"
touch "${TMPDIR_DEDUP}/file3.py"

result=$(detect_repo_languages "$TMPDIR_DEDUP")
py_count=$(echo "$result" | tr ' ' '\n' | grep -c "^python$" || true)

if [ "$py_count" -eq 1 ]; then
    pass "python appears only once even with multiple .py files"
else
    fail "python should appear once, counted ${py_count} times in '${result}'"
fi

rm -rf "$TMPDIR_DEDUP"

# =============================================================================
# detect_repo_languages — TypeScript from .tsx files
# =============================================================================

echo "=== detect_repo_languages: .tsx → typescript ==="

TMPDIR_TSX="$(mktemp -d)"
touch "${TMPDIR_TSX}/component.tsx"

result=$(detect_repo_languages "$TMPDIR_TSX")
if echo "$result" | grep -q "typescript"; then
    pass "detects typescript from .tsx files"
else
    fail "should detect typescript from .tsx files, got: '${result}'"
fi

rm -rf "$TMPDIR_TSX"

# =============================================================================
# detect_repo_languages — no false positives (dirs not files)
# =============================================================================

echo "=== detect_repo_languages: directory entries excluded ==="

TMPDIR_DIRS="$(mktemp -d)"
mkdir -p "${TMPDIR_DIRS}/subdir.py"   # directory named *.py should not match

result=$(detect_repo_languages "$TMPDIR_DIRS")
if ! echo "$result" | grep -q "python"; then
    pass "directories named .py are not detected as Python files"
else
    fail "directories should not be detected as source files, got: '${result}'"
fi

rm -rf "${TMPDIR_DIRS}"

# =============================================================================
# detect_repo_languages — empty directory returns empty string
# =============================================================================

echo "=== detect_repo_languages: empty directory ==="

TMPDIR_EMPTY="$(mktemp -d)"
result=$(detect_repo_languages "$TMPDIR_EMPTY")

if [ -z "$result" ]; then
    pass "empty directory returns empty string"
else
    fail "empty directory should return empty string, got: '${result}'"
fi

rm -rf "$TMPDIR_EMPTY"

# =============================================================================
# detect_repo_languages — non-recursive (only top level)
# =============================================================================

echo "=== detect_repo_languages: non-recursive scan ==="

TMPDIR_DEEP="$(mktemp -d)"
mkdir -p "${TMPDIR_DEEP}/subdir"
touch "${TMPDIR_DEEP}/subdir/deep.py"  # Should NOT be detected (too deep)

result=$(detect_repo_languages "$TMPDIR_DEEP")
if ! echo "$result" | grep -q "python"; then
    pass "does not detect files in subdirectories (non-recursive)"
else
    fail "should not detect .py in subdirectory, got: '${result}'"
fi

rm -rf "$TMPDIR_DEEP"

# =============================================================================
# detect_repo_languages — shell/bash detection
# =============================================================================

echo "=== detect_repo_languages: shell detection ==="

TMPDIR_SH="$(mktemp -d)"
touch "${TMPDIR_SH}/script.sh"

result=$(detect_repo_languages "$TMPDIR_SH")
if echo "$result" | grep -q "bash"; then
    pass "detects bash from .sh files"
else
    fail "should detect bash from .sh files, got: '${result}'"
fi

rm -rf "$TMPDIR_SH"

# =============================================================================
# detect_repo_languages — C++ extensions
# =============================================================================

echo "=== detect_repo_languages: C++ extensions ==="

TMPDIR_CPP="$(mktemp -d)"
touch "${TMPDIR_CPP}/main.cpp"
touch "${TMPDIR_CPP}/util.cc"

result=$(detect_repo_languages "$TMPDIR_CPP")
cpp_count=$(echo "$result" | tr ' ' '\n' | grep -c "^cpp$" || true)

if [ "$cpp_count" -eq 1 ]; then
    pass "cpp/.cc both map to 'cpp', deduplicated to one entry"
else
    fail "cpp should appear once for .cpp and .cc files, counted ${cpp_count} in '${result}'"
fi

rm -rf "$TMPDIR_CPP"

# =============================================================================
# get_repo_map_slice — empty REPO_MAP_CONTENT returns 1
# =============================================================================

echo "=== get_repo_map_slice: empty content ==="

REPO_MAP_CONTENT=""
if get_repo_map_slice "src/any.py" >/dev/null 2>&1; then
    fail "get_repo_map_slice should return 1 when REPO_MAP_CONTENT is empty"
else
    pass "get_repo_map_slice returns 1 when REPO_MAP_CONTENT is empty"
fi

# =============================================================================
# get_repo_map_slice — empty file_list returns all content
# =============================================================================

echo "=== get_repo_map_slice: empty file_list returns all ==="

REPO_MAP_CONTENT="## src/main.py
  def hello()"

slice=$(get_repo_map_slice "")
if echo "$slice" | grep -q "## src/main.py"; then
    pass "get_repo_map_slice with empty file_list returns full content"
else
    fail "get_repo_map_slice with empty file_list should return full content, got: '${slice}'"
fi

# =============================================================================
# get_repo_map_slice — full match returns the matching section
# =============================================================================

echo "=== get_repo_map_slice: full match ==="

REPO_MAP_CONTENT="## src/main.py
  def hello()
  def world()

## src/utils.py
  def helper()"

slice=$(get_repo_map_slice "src/main.py")
if echo "$slice" | grep -q "## src/main.py"; then
    pass "get_repo_map_slice includes matched section header"
else
    fail "get_repo_map_slice should include matched section, got: '${slice}'"
fi

if ! echo "$slice" | grep -q "## src/utils.py"; then
    pass "get_repo_map_slice excludes non-matched section"
else
    fail "get_repo_map_slice should exclude non-matched section, got: '${slice}'"
fi

# =============================================================================
# get_repo_map_slice — partial match (one of two requested files matches)
# =============================================================================

echo "=== get_repo_map_slice: partial match ==="

REPO_MAP_CONTENT="## src/main.py
  def hello()

## src/utils.py
  def helper()"

slice=$(get_repo_map_slice "src/main.py src/missing.py")
if echo "$slice" | grep -q "## src/main.py"; then
    pass "get_repo_map_slice partial match includes the file that exists"
else
    fail "get_repo_map_slice partial match should include existing file, got: '${slice}'"
fi

if ! echo "$slice" | grep -q "## src/utils.py"; then
    pass "get_repo_map_slice partial match excludes non-requested section"
else
    fail "get_repo_map_slice partial match should exclude non-requested section, got: '${slice}'"
fi

# =============================================================================
# get_repo_map_slice — no match branch returns 1
# =============================================================================

echo "=== get_repo_map_slice: no match ==="

REPO_MAP_CONTENT="## src/main.py
  def hello()

## src/utils.py
  def helper()"

if get_repo_map_slice "src/nonexistent.py" >/dev/null 2>&1; then
    fail "get_repo_map_slice should return 1 when no files match (no match branch)"
else
    pass "get_repo_map_slice returns 1 when no files match (no match branch)"
fi

# =============================================================================
# get_repo_map_slice — multiple files requested, both match
# =============================================================================

echo "=== get_repo_map_slice: multiple files both match ==="

REPO_MAP_CONTENT="## src/a.py
  def func_a()

## src/b.py
  def func_b()

## src/c.py
  def func_c()"

slice=$(get_repo_map_slice "src/a.py src/c.py")
if echo "$slice" | grep -q "## src/a.py" && echo "$slice" | grep -q "## src/c.py"; then
    pass "get_repo_map_slice returns both matched sections"
else
    fail "get_repo_map_slice should return both matched sections, got: '${slice}'"
fi

if ! echo "$slice" | grep -q "## src/b.py"; then
    pass "get_repo_map_slice excludes the unmatched middle section"
else
    fail "get_repo_map_slice should exclude unmatched section, got: '${slice}'"
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
