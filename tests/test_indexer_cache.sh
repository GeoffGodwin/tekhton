#!/usr/bin/env bash
# Test: lib/indexer_cache.sh — Intra-run repo map cache (Milestone 61)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Minimal stubs
warn() { echo "[WARN] $*" >&2; }
log()  { echo "[LOG] $*" >&2; }

PROJECT_DIR="/tmp"
export PROJECT_DIR

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_cache.sh"

TMPDIR_CACHE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CACHE"' EXIT

# =============================================================================
# Test 1: Cache file written after first save
# =============================================================================
echo "=== Cache file written after _save_repo_map_run_cache ==="

LOG_DIR="${TMPDIR_CACHE}/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP="20260406_120000"
export LOG_DIR TIMESTAMP

REPO_MAP_CONTENT="## lib/indexer.sh
  run_repo_map()
  get_repo_map_slice()

## lib/common.sh
  log()
  warn()"

_save_repo_map_run_cache

cache_file="${LOG_DIR}/REPO_MAP_CACHE.md"
if [[ -f "$cache_file" ]]; then
    pass "Cache file created at ${cache_file}"
else
    fail "Cache file not created at ${cache_file}"
fi

# Verify timestamp header
header=$(head -1 "$cache_file")
if [[ "$header" == "<!-- run:20260406_120000 -->" ]]; then
    pass "Cache file has correct timestamp header"
else
    fail "Expected timestamp header, got: ${header}"
fi

# Verify content after header
body=$(tail -n +2 "$cache_file")
if echo "$body" | grep -q "## lib/indexer.sh"; then
    pass "Cache file contains repo map content"
else
    fail "Cache file missing repo map content"
fi

# =============================================================================
# Test 2: _load_repo_map_run_cache reads from in-memory cache
# =============================================================================
echo "=== In-memory cache hit ==="

# _CACHED_REPO_MAP_CONTENT is already populated from save
_REPO_MAP_CACHE_HITS=0
if _load_repo_map_run_cache; then
    pass "In-memory cache hit returns 0"
else
    fail "In-memory cache hit should return 0"
fi

# =============================================================================
# Test 3: _load_repo_map_run_cache reads from disk when in-memory empty
# =============================================================================
echo "=== Disk cache hit ==="

_CACHED_REPO_MAP_CONTENT=""
_REPO_MAP_CACHE_FILE=""

if _load_repo_map_run_cache; then
    pass "Disk cache hit returns 0"
else
    fail "Disk cache hit should return 0"
fi

if [[ -n "$_CACHED_REPO_MAP_CONTENT" ]]; then
    pass "Disk cache loaded content into _CACHED_REPO_MAP_CONTENT"
else
    fail "Disk cache should populate _CACHED_REPO_MAP_CONTENT"
fi

if echo "$_CACHED_REPO_MAP_CONTENT" | grep -q "## lib/indexer.sh"; then
    pass "Disk cache content matches saved content"
else
    fail "Disk cache content does not match saved content"
fi

# =============================================================================
# Test 4: Different TIMESTAMP does not match stale cache
# =============================================================================
echo "=== Stale cache rejected (wrong TIMESTAMP) ==="

_CACHED_REPO_MAP_CONTENT=""
_REPO_MAP_CACHE_FILE=""
TIMESTAMP="20260406_130000"  # Different from what was written

if _load_repo_map_run_cache; then
    fail "Stale cache should not load (wrong TIMESTAMP)"
else
    pass "Stale cache correctly rejected"
fi

# Restore correct timestamp
TIMESTAMP="20260406_120000"

# =============================================================================
# Test 5: invalidate_repo_map_run_cache clears cache
# =============================================================================
echo "=== invalidate_repo_map_run_cache ==="

# Reload cache first
_CACHED_REPO_MAP_CONTENT=""
_load_repo_map_run_cache

# Verify it's loaded
if [[ -n "$_CACHED_REPO_MAP_CONTENT" ]]; then
    pass "Pre-invalidation: cache is loaded"
else
    fail "Pre-invalidation: cache should be loaded"
fi

invalidate_repo_map_run_cache

if [[ -z "$_CACHED_REPO_MAP_CONTENT" ]]; then
    pass "Post-invalidation: _CACHED_REPO_MAP_CONTENT is empty"
else
    fail "Post-invalidation: _CACHED_REPO_MAP_CONTENT should be empty"
fi

if [[ ! -f "$cache_file" ]]; then
    pass "Post-invalidation: cache file removed from disk"
else
    fail "Post-invalidation: cache file should be removed"
fi

# =============================================================================
# Test 6: _load_repo_map_run_cache fails after invalidation (no file)
# =============================================================================
echo "=== Cache miss after invalidation ==="

if _load_repo_map_run_cache; then
    fail "Should not load cache after invalidation"
else
    pass "Cache miss after invalidation"
fi

# =============================================================================
# Test 7: get_repo_map_cache_stats reports correctly
# =============================================================================
echo "=== get_repo_map_cache_stats ==="

_REPO_MAP_CACHE_HITS=3
INDEXER_GENERATION_TIME_MS="1500"
export _REPO_MAP_CACHE_HITS INDEXER_GENERATION_TIME_MS

stats=$(get_repo_map_cache_stats)
if echo "$stats" | grep -q "hits:3"; then
    pass "Cache stats reports correct hit count"
else
    fail "Expected hits:3, got: ${stats}"
fi

if echo "$stats" | grep -q "gen_time_ms:1500"; then
    pass "Cache stats reports correct generation time"
else
    fail "Expected gen_time_ms:1500, got: ${stats}"
fi

# =============================================================================
# Test 8: Slice from cached content identical to slice from fresh content
# =============================================================================
echo "=== Slice identity: cached vs fresh ==="

REPO_MAP_CONTENT="## src/main.py
  def hello()
  def world()

## src/utils.py
  def helper()

## tests/test_main.py
  def test_hello()"

# Slice fresh content
fresh_slice=$(get_repo_map_slice "src/main.py")

# Save to cache and clear REPO_MAP_CONTENT
_save_repo_map_run_cache
REPO_MAP_CONTENT=""

# Load from cache
_CACHED_REPO_MAP_CONTENT=""
_load_repo_map_run_cache
REPO_MAP_CONTENT="$_CACHED_REPO_MAP_CONTENT"
export REPO_MAP_CONTENT

# Slice cached content
cached_slice=$(get_repo_map_slice "src/main.py")

if [[ "$fresh_slice" == "$cached_slice" ]]; then
    pass "Slice from cached map is identical to slice from fresh map"
else
    fail "Slice mismatch: fresh='${fresh_slice}' vs cached='${cached_slice}'"
fi

# =============================================================================
# Test 9: Empty TIMESTAMP prevents disk cache load
# =============================================================================
echo "=== Empty TIMESTAMP rejects disk cache ==="

_CACHED_REPO_MAP_CONTENT=""
_REPO_MAP_CACHE_FILE=""
TIMESTAMP=""

if _load_repo_map_run_cache; then
    fail "Empty TIMESTAMP should prevent cache load"
else
    pass "Empty TIMESTAMP correctly prevents cache load"
fi

# =============================================================================
# Test 10: _get_cached_repo_map accessor
# =============================================================================
echo "=== _get_cached_repo_map accessor ==="

_CACHED_REPO_MAP_CONTENT="test content"
result=$(_get_cached_repo_map)
if [[ "$result" == "test content" ]]; then
    pass "_get_cached_repo_map returns cached content"
else
    fail "_get_cached_repo_map should return 'test content', got: '${result}'"
fi

_CACHED_REPO_MAP_CONTENT=""
result=$(_get_cached_repo_map)
if [[ -z "$result" ]]; then
    pass "_get_cached_repo_map returns empty when no cache"
else
    fail "_get_cached_repo_map should return empty, got: '${result}'"
fi

# =============================================================================
# Test 11: Cache hit counter increments
# =============================================================================
echo "=== Cache hit counter ==="

_REPO_MAP_CACHE_HITS=0
_CACHED_REPO_MAP_CONTENT="some content"
INDEXER_AVAILABLE=true  # exported by indexer.sh
REPO_MAP_ENABLED=true   # exported by config
TIMESTAMP="20260406_140000"

# Simulate run_repo_map hitting cache (by checking _load succeeds)
if _load_repo_map_run_cache; then
    _REPO_MAP_CACHE_HITS=$(( _REPO_MAP_CACHE_HITS + 1 ))
fi
if _load_repo_map_run_cache; then
    _REPO_MAP_CACHE_HITS=$(( _REPO_MAP_CACHE_HITS + 1 ))
fi

if [[ "$_REPO_MAP_CACHE_HITS" -eq 2 ]]; then
    pass "Cache hit counter incremented to 2 after 2 hits"
else
    fail "Expected 2 cache hits, got: ${_REPO_MAP_CACHE_HITS}"
fi

# =============================================================================
# Cleanup & Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
