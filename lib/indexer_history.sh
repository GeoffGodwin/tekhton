#!/usr/bin/env bash
# =============================================================================
# indexer_history.sh — Cross-run cache warming, task history, and indexer stats
#
# Sourced by tekhton.sh — do not run directly.
# Provides: warm_index_cache(), record_task_file_association(),
#           get_indexer_stats(), _prune_task_history()
#
# Extracted from indexer.sh to stay under the 300-line ceiling.
#
# Dependencies: common.sh (log, warn), indexer.sh (INDEXER_AVAILABLE,
#   _indexer_find_venv_python), indexer_helpers.sh (extract_files_from_coder_summary)
# =============================================================================
set -euo pipefail

# --- Task history file location ----------------------------------------------

_TASK_HISTORY_FILE=""

_ensure_task_history_file() {
    if [[ -n "$_TASK_HISTORY_FILE" ]]; then
        return
    fi
    local cache_dir
    cache_dir=$(_indexer_resolve_cache_dir)
    _TASK_HISTORY_FILE="${cache_dir}/task_history.jsonl"
}

# =============================================================================
# warm_index_cache — Pre-populate the tag cache for the entire project.
#
# Called during --init or --setup-indexer when REPO_MAP_ENABLED=true.
# Uses --warm-cache flag on repo_map.py to parse all files without output.
# Displays progress for large projects.
#
# Returns: 0 on success, 1 on failure or indexer unavailable
# =============================================================================

warm_index_cache() {
    if [[ "$INDEXER_AVAILABLE" != "true" ]]; then
        warn "[indexer] Cannot warm cache — indexer not available."
        return 1
    fi

    local venv_python
    if ! venv_python=$(_indexer_find_venv_python); then
        return 1
    fi

    local repo_map_script="${TEKHTON_HOME}/tools/repo_map.py"
    if [[ ! -f "$repo_map_script" ]]; then
        warn "[indexer] repo_map.py not found at ${repo_map_script}."
        return 1
    fi

    local cache_dir
    cache_dir=$(_indexer_resolve_cache_dir)

    local languages="${REPO_MAP_LANGUAGES:-auto}"

    log "[indexer] Warming tag cache for project..."
    log "[indexer] Note: task history in .claude/index/ may contain task descriptions."

    local exit_code=0
    "$venv_python" "$repo_map_script" \
        --root "$PROJECT_DIR" \
        --cache-dir "$cache_dir" \
        --languages "$languages" \
        --warm-cache 2>&1 | while IFS= read -r line; do
            # Forward progress lines to log
            if [[ "$line" == "[indexer]"* ]]; then
                log "$line"
            fi
        done || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        warn "[indexer] Cache warming encountered errors (exit ${exit_code})."
        return 1
    fi

    emit_test_symbol_map
    return 0
}

# =============================================================================
# record_task_file_association — Log task→file mapping to JSONL history.
#
# Called after a successful coder stage. Records which files were modified
# for a given task, enabling personalized ranking on future runs.
#
# Args:
#   $1 — task description
#   $2 — space-separated list of modified file paths
#
# JSONL is append-only. Pruning handled separately by _prune_task_history.
# Returns: 0 always (non-critical — failures are logged, not fatal)
# =============================================================================

record_task_file_association() {
    local task="${1:-}"
    local file_list="${2:-}"

    if [[ "${REPO_MAP_HISTORY_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    if [[ -z "$task" ]] || [[ -z "$file_list" ]]; then
        return 0
    fi

    if [[ "$INDEXER_AVAILABLE" != "true" ]]; then
        return 0
    fi

    _ensure_task_history_file

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Classify task type (reuse metrics pattern)
    local task_type="feature"
    local lower
    lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')
    if echo "$lower" | grep -qE '(^fix|bug|bugfix|hotfix|patch|regression|broken|crash)'; then
        task_type="bug"
    elif echo "$lower" | grep -qE '(^milestone|milestone [0-9])'; then
        task_type="milestone"
    fi

    # Build JSON files array from space-separated list
    local files_json="["
    local first=true
    local f
    local -a files_array=()
    read -ra files_array <<< "$file_list"
    for f in "${files_array[@]}"; do
        [[ -z "$f" ]] && continue
        # Escape special chars in filenames for JSON safety
        local safe_f
        safe_f=$(printf '%s' "$f" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [[ "$first" == "true" ]]; then
            files_json="${files_json}\"${safe_f}\""
            first=false
        else
            files_json="${files_json},\"${safe_f}\""
        fi
    done
    files_json="${files_json}]"

    # Escape task for JSON
    local safe_task
    safe_task=$(printf '%s' "$task" | tr '\n\r' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')

    local record
    record=$(printf '{"ts":"%s","task":"%s","files":%s,"task_type":"%s"}' \
        "$timestamp" "$safe_task" "$files_json" "$task_type")

    # Append atomically
    echo "$record" >> "$_TASK_HISTORY_FILE" 2>/dev/null || {
        warn "[indexer] Failed to write task history record."
        return 0
    }

    # Prune if over limit
    _prune_task_history

    log "[indexer] Recorded task→file association (${#files_array[@]} files)."
    return 0
}

# =============================================================================
# _prune_task_history — Trim history to REPO_MAP_HISTORY_MAX_RECORDS entries.
#
# Creates a new file and atomically replaces the old one (never read-modify-write
# the same file). Only prunes when line count exceeds the configured limit.
# =============================================================================

_prune_task_history() {
    _ensure_task_history_file

    local max_records="${REPO_MAP_HISTORY_MAX_RECORDS:-200}"
    if [[ ! -f "$_TASK_HISTORY_FILE" ]]; then
        return
    fi

    local line_count
    line_count=$(wc -l < "$_TASK_HISTORY_FILE" 2>/dev/null | tr -d '[:space:]')
    if [[ "$line_count" -le "$max_records" ]]; then
        return
    fi

    # Keep only the last max_records lines
    local tmp_file="${_TASK_HISTORY_FILE}.tmp"
    if tail -n "$max_records" "$_TASK_HISTORY_FILE" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$_TASK_HISTORY_FILE" 2>/dev/null || {
            rm -f "$tmp_file" 2>/dev/null || true
            warn "[indexer] Failed to prune task history."
        }
    else
        rm -f "$tmp_file" 2>/dev/null || true
        warn "[indexer] Failed to prune task history."
    fi
}

# =============================================================================
# get_indexer_stats — Return indexer statistics for metrics integration.
#
# Invokes repo_map.py with --stats to get cache hit/miss data.
# Output: JSON string on stdout with keys: hits, misses, hit_rate,
#   parse_time_saved_ms, cache_size
# Returns: 0 on success, 1 if unavailable
# =============================================================================

get_indexer_stats() {
    # Return stats from the most recent run_repo_map() invocation.
    # These globals are populated as side effects in indexer.sh.
    local hit_rate="${INDEXER_CACHE_HIT_RATE:-}"
    local gen_time="${INDEXER_GENERATION_TIME_MS:-}"

    if [[ -n "$hit_rate" ]] || [[ -n "$gen_time" ]]; then
        printf '{"hit_rate":%s,"generation_time_ms":%s}' \
            "${hit_rate:-0}" "${gen_time:-0}"
        return 0
    fi

    echo "{}"
    return 1
}

# =============================================================================
# Test symbol map emission (Milestone 88)
# =============================================================================

TEST_SYMBOL_MAP_FILE=""
export TEST_SYMBOL_MAP_FILE

emit_test_symbol_map() {
    if [[ "${TEST_AUDIT_SYMBOL_MAP_ENABLED:-true}" != "true" ]]; then
        return 0
    fi
    if [[ "${REPO_MAP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi
    if [[ "$INDEXER_AVAILABLE" != "true" ]]; then
        return 0
    fi

    local venv_python cache_dir test_map_file
    venv_python=$(_indexer_find_venv_python) || return 0
    cache_dir=$(_indexer_resolve_cache_dir)
    test_map_file="${cache_dir}/test_map.json"

    "$venv_python" "${TEKHTON_HOME}/tools/repo_map.py" \
        --root "$PROJECT_DIR" \
        --cache-dir "$cache_dir" \
        --languages "${REPO_MAP_LANGUAGES:-auto}" \
        --emit-test-map "$test_map_file" \
        > /dev/null 2>&1 || {
        warn "[indexer] Failed to emit test symbol map (non-fatal)."
        return 0
    }

    TEST_SYMBOL_MAP_FILE="$test_map_file"
    export TEST_SYMBOL_MAP_FILE
    log_verbose "[indexer] Test symbol map written to ${test_map_file}."
}
