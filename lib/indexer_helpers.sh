#!/usr/bin/env bash
# =============================================================================
# indexer_helpers.sh — Indexer support functions (language detection, config)
#
# Sourced by tekhton.sh — do not run directly.
# Provides: detect_repo_languages(), validate_indexer_config(),
#           extract_files_from_coder_summary()
#
# Extracted from indexer.sh to stay under the 300-line ceiling.
#
# Dependencies: common.sh (log, warn)
# =============================================================================
set -euo pipefail

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

# --- File list extraction helpers --------------------------------------------

# extract_files_from_coder_summary — Parse file paths from CODER_SUMMARY.md.
# Looks for the "## Files Modified" or "## Files Created or Modified" section
# and extracts file paths from bullet items.
# Output: space-separated file paths on stdout
# Returns: 0 always (empty output if no files found)
extract_files_from_coder_summary() {
    local summary_file="${1:-CODER_SUMMARY.md}"

    if [[ ! -f "$summary_file" ]]; then
        return 0
    fi

    # Extract lines from Files Modified/Created section until next ## heading
    local section_content
    section_content=$(awk '/^## Files (Modified|Created)/{found=1; next} found && /^##/{exit} found{print}' \
        "$summary_file" 2>/dev/null || true)

    if [[ -z "$section_content" ]]; then
        return 0
    fi

    # Extract file paths from bullet lines: "- path/to/file" or "- `path/to/file`"
    local files=""
    local line
    while IFS= read -r line; do
        # Strip leading "- " and backticks, take first whitespace-delimited token
        local cleaned="${line#*- }"
        cleaned="${cleaned#\`}"
        cleaned="${cleaned%%\`*}"
        cleaned="${cleaned%% —*}"
        cleaned="${cleaned%% *}"
        cleaned="${cleaned## }"
        if [[ -n "$cleaned" ]] && [[ "$cleaned" != "None" ]] && [[ "$cleaned" != "(fill"* ]]; then
            files="${files} ${cleaned}"
        fi
    done <<< "$section_content"

    echo "${files## }"
    return 0
}
