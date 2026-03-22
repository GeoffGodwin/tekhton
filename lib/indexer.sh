#!/usr/bin/env bash
# =============================================================================
# indexer.sh — Repo map orchestration and Python tool invocation
#
# Sourced by tekhton.sh — do not run directly.
# Provides: check_indexer_available(), run_repo_map(), get_repo_map_slice(),
#           invalidate_repo_map_cache(), detect_repo_languages()
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
        # Milestone 4 will create this file
        log "[indexer] repo_map.py not yet implemented — skipping."
        return 1
    fi

    local cache_dir="${REPO_MAP_CACHE_DIR:-.claude/index}"
    if [[ "$cache_dir" != /* ]]; then
        cache_dir="${PROJECT_DIR}/${cache_dir}"
    fi
    mkdir -p "$cache_dir" 2>/dev/null || true

    local languages="${REPO_MAP_LANGUAGES:-auto}"

    # Invoke the Python tool
    REPO_MAP_CONTENT=$("$venv_python" "$repo_map_script" \
        --root "$PROJECT_DIR" \
        --task "$task" \
        --budget "$budget" \
        --cache-dir "$cache_dir" \
        --languages "$languages" \
        2>/dev/null) || {
        warn "[indexer] repo_map.py failed — falling back to no repo map."
        REPO_MAP_CONTENT=""
        return 1
    }

    export REPO_MAP_CONTENT
    return 0
}

# --- Repo map slicing (stub — Milestone 5 wires into stages) -----------------

# Extract repo map entries for specific files from the cached map.
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

    # Filter: keep only lines that start with "## " followed by a matching path,
    # plus all subsequent lines until the next "## " heading.
    local result=""
    local include=false
    local line

    # Convert space-separated file_list to array to avoid unquoted expansion
    local -a file_array=()
    read -ra file_array <<< "$file_list"

    while IFS= read -r line; do
        if [[ "$line" == "## "* ]]; then
            include=false
            local path="${line#\#\# }"
            local f
            for f in "${file_array[@]}"; do
                if [[ "$path" == *"$f"* ]]; then
                    include=true
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
    local cache_dir="${REPO_MAP_CACHE_DIR:-.claude/index}"
    if [[ "$cache_dir" != /* ]]; then
        cache_dir="${PROJECT_DIR}/${cache_dir}"
    fi

    if [ -d "$cache_dir" ]; then
        rm -rf "$cache_dir"
        log "[indexer] Cache invalidated: ${cache_dir}"
    fi
    return 0
}

# --- Language auto-detection --------------------------------------------------

# Detect programming languages in the project by scanning file extensions.
# Scans only the top level of the project directory (fast, not recursive).
# Output: space-separated list of detected language names
# Returns: 0 always
detect_repo_languages() {
    local project_dir="${1:-$PROJECT_DIR}"
    local languages=()

    # Map file extensions to tree-sitter language names
    # Only scan one level deep for speed
    local ext
    local -A seen=()

    while IFS= read -r -d '' file; do
        ext="${file##*.}"
        case "$ext" in
            py)   [[ -z "${seen[python]:-}" ]]     && languages+=("python")     && seen[python]=1 ;;
            js)   [[ -z "${seen[javascript]:-}" ]]  && languages+=("javascript") && seen[javascript]=1 ;;
            ts)   [[ -z "${seen[typescript]:-}" ]]  && languages+=("typescript") && seen[typescript]=1 ;;
            tsx)  [[ -z "${seen[typescript]:-}" ]]   && languages+=("typescript") && seen[typescript]=1 ;;
            go)   [[ -z "${seen[go]:-}" ]]          && languages+=("go")         && seen[go]=1 ;;
            rs)   [[ -z "${seen[rust]:-}" ]]        && languages+=("rust")       && seen[rust]=1 ;;
            java) [[ -z "${seen[java]:-}" ]]        && languages+=("java")       && seen[java]=1 ;;
            c)    [[ -z "${seen[c]:-}" ]]           && languages+=("c")          && seen[c]=1 ;;
            cpp|cc|cxx) [[ -z "${seen[cpp]:-}" ]]   && languages+=("cpp")        && seen[cpp]=1 ;;
            rb)   [[ -z "${seen[ruby]:-}" ]]        && languages+=("ruby")       && seen[ruby]=1 ;;
            sh|bash) [[ -z "${seen[bash]:-}" ]]     && languages+=("bash")       && seen[bash]=1 ;;
        esac
    done < <(find "$project_dir" -maxdepth 1 -type f -print0 2>/dev/null)

    echo "${languages[*]}"
    return 0
}

# --- Config validation --------------------------------------------------------

# Validate indexer-related config values.
# Called during startup when REPO_MAP_ENABLED=true.
# Returns: 0 if valid, 1 if invalid (with error messages on stderr)
validate_indexer_config() {
    local valid=true

    # Token budget must be a positive integer
    if [[ -n "${REPO_MAP_TOKEN_BUDGET:-}" ]]; then
        if ! [[ "$REPO_MAP_TOKEN_BUDGET" =~ ^[1-9][0-9]*$ ]]; then
            echo "[✗] REPO_MAP_TOKEN_BUDGET must be a positive integer (got: ${REPO_MAP_TOKEN_BUDGET})" >&2
            valid=false
        fi
    fi

    # History max records must be a positive integer
    if [[ -n "${REPO_MAP_HISTORY_MAX_RECORDS:-}" ]]; then
        if ! [[ "$REPO_MAP_HISTORY_MAX_RECORDS" =~ ^[1-9][0-9]*$ ]]; then
            echo "[✗] REPO_MAP_HISTORY_MAX_RECORDS must be a positive integer (got: ${REPO_MAP_HISTORY_MAX_RECORDS})" >&2
            valid=false
        fi
    fi

    # Languages must be "auto" or a comma-separated list of known language names
    if [[ -n "${REPO_MAP_LANGUAGES:-}" ]] && [[ "$REPO_MAP_LANGUAGES" != "auto" ]]; then
        local lang
        local known_langs="python javascript typescript go rust java c cpp ruby bash"
        IFS=',' read -ra lang_list <<< "$REPO_MAP_LANGUAGES"
        for lang in "${lang_list[@]}"; do
            lang="${lang// /}"  # strip whitespace
            if [[ " $known_langs " != *" $lang "* ]]; then
                warn "[indexer] Unknown language in REPO_MAP_LANGUAGES: ${lang}"
            fi
        done
    fi

    if [[ "$valid" == "true" ]]; then
        return 0
    fi
    return 1
}
