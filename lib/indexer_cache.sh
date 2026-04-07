#!/usr/bin/env bash
# =============================================================================
# indexer_cache.sh — Intra-run repo map cache (Milestone 61)
#
# Sourced by tekhton.sh — do not run directly.
# Provides: _repo_map_cache_path(), _save_repo_map_run_cache(),
#           _load_repo_map_run_cache(), invalidate_repo_map_run_cache(),
#           _get_cached_repo_map(), get_repo_map_cache_stats()
#
# The run-scoped cache stores the full repo map after the first Python tool
# invocation. Subsequent stages load from cache, only re-slicing per stage.
# Distinct from the persistent tree-sitter disk cache in .claude/index/.
#
# Dependencies: common.sh (log), indexer.sh (module state variables)
# =============================================================================
set -euo pipefail

# _repo_map_cache_path — Resolve the run-scoped cache file path.
# Uses LOG_DIR to scope to the current run's log directory.
# Output: absolute path on stdout
_repo_map_cache_path() {
    local log_dir="${LOG_DIR:-.claude/logs}"
    echo "${log_dir}/REPO_MAP_CACHE.md"
}

# _save_repo_map_run_cache — Write current REPO_MAP_CONTENT to run-scoped cache.
# Called after successful Python tool invocation.
_save_repo_map_run_cache() {
    if [[ -z "$REPO_MAP_CONTENT" ]]; then
        return 0
    fi

    _CACHED_REPO_MAP_CONTENT="$REPO_MAP_CONTENT"

    local cache_file
    cache_file=$(_repo_map_cache_path)
    local cache_dir
    cache_dir=$(dirname "$cache_file")
    mkdir -p "$cache_dir" 2>/dev/null || true

    # Write with timestamp header for staleness detection
    {
        echo "<!-- run:${TIMESTAMP:-unknown} -->"
        echo "$REPO_MAP_CONTENT"
    } > "$cache_file"
    _REPO_MAP_CACHE_FILE="$cache_file"
    log "[indexer] Run cache saved: ${cache_file}"
}

# _load_repo_map_run_cache — Load repo map from run-scoped cache if valid.
# Checks: in-memory cache first, then disk file with TIMESTAMP match.
# Returns: 0 if cache loaded, 1 if cache miss
_load_repo_map_run_cache() {
    # Check in-memory cache first
    if [[ -n "$_CACHED_REPO_MAP_CONTENT" ]]; then
        return 0
    fi

    # Check disk cache
    local cache_file
    cache_file=$(_repo_map_cache_path)
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    # Verify TIMESTAMP matches current run (prevents stale cross-run reads)
    local ts="${TIMESTAMP:-}"
    if [[ -z "$ts" ]]; then
        return 1
    fi

    local header
    header=$(head -1 "$cache_file" 2>/dev/null || true)
    if [[ "$header" != "<!-- run:${ts} -->" ]]; then
        return 1
    fi

    # Load content (skip the timestamp header line)
    _CACHED_REPO_MAP_CONTENT=$(tail -n +2 "$cache_file")
    if [[ -z "$_CACHED_REPO_MAP_CONTENT" ]]; then
        return 1
    fi

    _REPO_MAP_CACHE_FILE="$cache_file"
    return 0
}

# invalidate_repo_map_run_cache — Clear the intra-run repo map cache.
# Distinct from invalidate_repo_map_cache() which invalidates the persistent
# tree-sitter disk cache in .claude/index/.
# Returns: 0 always
invalidate_repo_map_run_cache() {
    _CACHED_REPO_MAP_CONTENT=""
    if [[ -n "$_REPO_MAP_CACHE_FILE" ]] && [[ -f "$_REPO_MAP_CACHE_FILE" ]]; then
        rm -f "$_REPO_MAP_CACHE_FILE" 2>/dev/null || true
        log "[indexer] Run cache invalidated: ${_REPO_MAP_CACHE_FILE}"
    fi
    _REPO_MAP_CACHE_FILE=""
    return 0
}

# _get_cached_repo_map — Accessor for cached repo map content.
# Returns cached content or empty string if not cached.
_get_cached_repo_map() {
    echo "$_CACHED_REPO_MAP_CONTENT"
}

# get_repo_map_cache_stats — Return cache hit statistics for timing report.
# Output: "hits:N gen_time_ms:N" on stdout
get_repo_map_cache_stats() {
    echo "hits:${_REPO_MAP_CACHE_HITS:-0} gen_time_ms:${INDEXER_GENERATION_TIME_MS:-0}"
}
