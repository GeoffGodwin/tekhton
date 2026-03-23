#!/usr/bin/env bash
# =============================================================================
# indexer.sh — Repo map orchestration and Python tool invocation
#
# Sourced by tekhton.sh — do not run directly.
# Provides: check_indexer_available(), run_repo_map(), get_repo_map_slice(),
#           invalidate_repo_map_cache(), infer_test_counterparts(),
#           warm_index_cache(), record_task_file_association(),
#           get_indexer_stats()
# See also: indexer_helpers.sh (detect_repo_languages, validate_indexer_config,
#           extract_files_from_coder_summary)
#
# All functions gracefully degrade when Python/tree-sitter is unavailable.
# When REPO_MAP_ENABLED=true but indexer is not available, a warning is logged
# and the pipeline falls back to 2.0 behavior (no repo map injection).
#
# Dependencies: common.sh (log, warn)
# =============================================================================
set -euo pipefail

# --- Module state -------------------------------------------------------------

INDEXER_AVAILABLE=false
export INDEXER_AVAILABLE

# Cached repo map output (populated by run_repo_map, consumed by stages)
REPO_MAP_CONTENT=""
export REPO_MAP_CONTENT

# Indexer stats (populated by get_indexer_stats, consumed by metrics)
INDEXER_CACHE_HIT_RATE=""
INDEXER_GENERATION_TIME_MS=""
export INDEXER_CACHE_HIT_RATE INDEXER_GENERATION_TIME_MS

# --- Python detection ---------------------------------------------------------

# Find the venv Python binary for the indexer virtualenv.
# Returns the path on stdout, or returns 1 if not found.
_indexer_find_venv_python() {
    # shellcheck disable=SC2153  # PROJECT_DIR set by tekhton.sh
    local venv_dir="${PROJECT_DIR}/${REPO_MAP_VENV_DIR:-.claude/indexer-venv}"

    if [ -f "${venv_dir}/bin/python" ]; then
        echo "${venv_dir}/bin/python"
        return 0
    elif [ -f "${venv_dir}/Scripts/python.exe" ]; then
        echo "${venv_dir}/Scripts/python.exe"
        return 0
    fi
    return 1
}

# --- Serena availability state ------------------------------------------------

SERENA_INSTALL_AVAILABLE=false
export SERENA_INSTALL_AVAILABLE

# --- Availability check -------------------------------------------------------

# Check if the indexer infrastructure is available and functional.
# Sets INDEXER_AVAILABLE=true/false as a side effect.
# Returns: 0 if available, 1 if not.
check_indexer_available() {
    INDEXER_AVAILABLE=false

    # Quick bail: if repo map is disabled, don't bother checking
    if [[ "${REPO_MAP_ENABLED:-false}" != "true" ]]; then
        return 1
    fi

    local venv_python
    if ! venv_python=$(_indexer_find_venv_python); then
        warn "[indexer] Virtualenv not found. Run 'tekhton --setup-indexer' to set up."
        return 1
    fi

    # Verify tree-sitter is importable
    if ! "$venv_python" -c "import tree_sitter" 2>/dev/null; then
        warn "[indexer] tree-sitter not found in virtualenv. Run 'tekhton --setup-indexer'."
        return 1
    fi

    # Verify networkx is importable
    if ! "$venv_python" -c "import networkx" 2>/dev/null; then
        warn "[indexer] networkx not found in virtualenv. Run 'tekhton --setup-indexer'."
        return 1
    fi

    INDEXER_AVAILABLE=true

    # Also check Serena availability (informational — does not affect return)
    if command -v check_serena_available &>/dev/null; then
        if check_serena_available 2>/dev/null; then
            SERENA_INSTALL_AVAILABLE=true
            log "[indexer] Serena LSP: installed"
        else
            log "[indexer] Serena LSP: not installed (optional — run --setup-indexer --with-lsp)"
        fi
    fi

    return 0
}

# --- Repo map generation (stub — Milestone 4 implements the Python tool) ------

# Generate a ranked repo map for the given task.
# Args:
#   $1 — task description (used for keyword-based ranking)
#   $2 — token budget (optional, defaults to REPO_MAP_TOKEN_BUDGET)
# Output: markdown repo map on stdout
# Returns: 0 on success, 1 on failure or unavailable
run_repo_map() {
    local task="${1:-}"
    local budget="${2:-${REPO_MAP_TOKEN_BUDGET:-2048}}"

    if [[ "$INDEXER_AVAILABLE" != "true" ]]; then
        return 1
    fi

    local venv_python
    if ! venv_python=$(_indexer_find_venv_python); then
        return 1
    fi

    local repo_map_script="${TEKHTON_HOME}/tools/repo_map.py"
    if [ ! -f "$repo_map_script" ]; then
        warn "[indexer] repo_map.py not found at ${repo_map_script}."
        return 1
    fi

    local cache_dir
    cache_dir=$(_indexer_resolve_cache_dir)

    local languages="${REPO_MAP_LANGUAGES:-auto}"

    # Build history file path for personalized ranking (M7)
    local history_args=()
    if [[ "${REPO_MAP_HISTORY_ENABLED:-true}" == "true" ]]; then
        local history_file="${cache_dir}/task_history.jsonl"
        if [[ -f "$history_file" ]]; then
            history_args=(--history-file "$history_file")
        fi
    fi

    # Invoke the Python tool with timing
    # Exit codes: 0 = success, 1 = partial (best-effort), 2 = fatal
    local exit_code=0
    local start_time
    start_time=$(date +%s%N 2>/dev/null || date +%s)

    local stderr_output=""
    stderr_output=$(mktemp 2>/dev/null || echo "/tmp/tekhton_indexer_$$")

    REPO_MAP_CONTENT=$("$venv_python" "$repo_map_script" \
        --root "$PROJECT_DIR" \
        --task "$task" \
        --budget "$budget" \
        --cache-dir "$cache_dir" \
        --languages "$languages" \
        --stats \
        "${history_args[@]}" \
        2>"$stderr_output") || exit_code=$?

    local end_time
    end_time=$(date +%s%N 2>/dev/null || date +%s)

    # Calculate generation time (nanoseconds → milliseconds)
    if [[ "$start_time" =~ ^[0-9]+$ ]] && [[ "$end_time" =~ ^[0-9]+$ ]]; then
        if [[ ${#start_time} -gt 10 ]]; then
            INDEXER_GENERATION_TIME_MS=$(( (end_time - start_time) / 1000000 ))
        else
            INDEXER_GENERATION_TIME_MS=$(( (end_time - start_time) * 1000 ))
        fi
    fi

    # Parse cache stats from stderr (last line is JSON if --stats was passed)
    if [[ -f "$stderr_output" ]]; then
        local stats_line
        stats_line=$(grep -E '^\{' "$stderr_output" | tail -1 2>/dev/null || true)
        if [[ -n "$stats_line" ]]; then
            INDEXER_CACHE_HIT_RATE=$(echo "$stats_line" | \
                grep -oE '"hit_rate":[0-9.]+' | grep -oE '[0-9.]+$' || true)
        fi
        rm -f "$stderr_output" 2>/dev/null || true
    fi

    if [[ "$exit_code" -eq 2 ]] || [[ -z "$REPO_MAP_CONTENT" ]]; then
        warn "[indexer] repo_map.py failed — falling back to no repo map."
        REPO_MAP_CONTENT=""
        return 1
    fi

    if [[ "$exit_code" -eq 1 ]]; then
        log "[indexer] Partial repo map generated (some files could not be parsed)."
    fi

    return 0
}

# --- Repo map slicing ---------------------------------------------------------

# Extract repo map entries for specific files from the cached map.
# Uses basename + suffix matching to avoid false positives from substring match.
# Args:
#   $1 — space-separated list of file paths to extract
# Output: filtered markdown repo map on stdout
# Returns: 0 on success, 1 if no map cached
get_repo_map_slice() {
    local file_list="${1:-}"

    if [[ -z "$REPO_MAP_CONTENT" ]]; then
        return 1
    fi

    if [[ -z "$file_list" ]]; then
        echo "$REPO_MAP_CONTENT"
        return 0
    fi

    # Filter: keep only "## path" headings that match a requested file,
    # plus all subsequent lines until the next "## " heading.
    local result=""
    local include=false
    local line
    local match_count=0

    local -a file_array=()
    read -ra file_array <<< "$file_list"

    while IFS= read -r line; do
        if [[ "$line" == "## "* ]]; then
            include=false
            local path="${line#\#\# }"
            local f
            for f in "${file_array[@]}"; do
                # Exact match or suffix match (path ends with /file)
                if [[ "$path" == "$f" ]] || [[ "$path" == */"$f" ]]; then
                    include=true
                    match_count=$((match_count + 1))
                    break
                fi
                # Also match if the requested path is a suffix of the map path
                local f_basename="${f##*/}"
                local p_basename="${path##*/}"
                if [[ -n "$f_basename" ]] && [[ "$p_basename" == "$f_basename" ]]; then
                    include=true
                    match_count=$((match_count + 1))
                    break
                fi
            done
        fi
        if [[ "$include" == "true" ]]; then
            result+="${line}"$'\n'
        fi
    done <<< "$REPO_MAP_CONTENT"

    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi
    return 1
}

# --- Cache invalidation -------------------------------------------------------

# Remove the indexer cache directory to force a full re-index on next run.
# Returns: 0 always
invalidate_repo_map_cache() {
    local cache_dir
    cache_dir=$(_indexer_resolve_cache_dir)

    if [ -d "$cache_dir" ]; then
        rm -rf "$cache_dir"
        log "[indexer] Cache invalidated: ${cache_dir}"
    fi
    return 0
}
