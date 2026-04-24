#!/usr/bin/env bash
# =============================================================================
# indexer_helpers.sh — Indexer support functions (language detection, config)
#
# Sourced by tekhton.sh — do not run directly.
# Provides: _indexer_resolve_cache_dir(), detect_repo_languages(),
#           validate_indexer_config(), extract_files_from_coder_summary(),
#           infer_test_counterparts(), _indexer_emit_stderr_tail()
#
# Extracted from indexer.sh to stay under the 300-line ceiling.
#
# Dependencies: common.sh (log, warn)
# =============================================================================
set -euo pipefail

# --- Cache directory resolution -----------------------------------------------

# _indexer_resolve_cache_dir — Resolve REPO_MAP_CACHE_DIR to an absolute path.
# Creates the directory if it doesn't exist.
# Output: absolute path to cache directory on stdout
# Returns: 0 always
_indexer_resolve_cache_dir() {
    local cache_dir="${REPO_MAP_CACHE_DIR:-.claude/index}"
    local project_dir="${1:-$PROJECT_DIR}"
    if [[ "$cache_dir" != /* ]]; then
        cache_dir="${project_dir}/${cache_dir}"
    fi
    mkdir -p "$cache_dir" 2>/dev/null || true
    echo "$cache_dir"
}

# --- Fatal-exit diagnostic surfacing ------------------------------------------

# Emit the last few lines of repo_map.py stderr as warnings so users can
# self-diagnose fatal failures (missing grammars, parse errors, etc.).
# Args: $1 — path to stderr capture file
_indexer_emit_stderr_tail() {
    local stderr_output="$1"
    [[ -s "$stderr_output" ]] || return 0
    local stderr_tail
    stderr_tail=$(tail -n 5 "$stderr_output" 2>/dev/null | \
        sed 's/^/[indexer]   /')
    [[ -n "$stderr_tail" ]] || return 0
    warn "[indexer] Last lines of repo_map.py stderr:"
    local _line
    while IFS= read -r _line; do
        warn "$_line"
    done <<< "$stderr_tail"
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
            py)
                if [[ -z "${seen[python]:-}" ]]; then languages+=("python"); seen[python]=1; fi ;;
            js)
                if [[ -z "${seen[javascript]:-}" ]]; then languages+=("javascript"); seen[javascript]=1; fi ;;
            ts)
                if [[ -z "${seen[typescript]:-}" ]]; then languages+=("typescript"); seen[typescript]=1; fi ;;
            tsx)
                if [[ -z "${seen[typescript]:-}" ]]; then languages+=("typescript"); seen[typescript]=1; fi ;;
            go)
                if [[ -z "${seen[go]:-}" ]]; then languages+=("go"); seen[go]=1; fi ;;
            rs)
                if [[ -z "${seen[rust]:-}" ]]; then languages+=("rust"); seen[rust]=1; fi ;;
            java)
                if [[ -z "${seen[java]:-}" ]]; then languages+=("java"); seen[java]=1; fi ;;
            c)
                if [[ -z "${seen[c]:-}" ]]; then languages+=("c"); seen[c]=1; fi ;;
            cpp|cc|cxx)
                if [[ -z "${seen[cpp]:-}" ]]; then languages+=("cpp"); seen[cpp]=1; fi ;;
            rb)
                if [[ -z "${seen[ruby]:-}" ]]; then languages+=("ruby"); seen[ruby]=1; fi ;;
            sh|bash)
                if [[ -z "${seen[bash]:-}" ]]; then languages+=("bash"); seen[bash]=1; fi ;;
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

# extract_files_from_coder_summary — Parse file paths from ${CODER_SUMMARY_FILE}.
# Looks for the "## Files Modified" or "## Files Created or Modified" section
# and extracts file paths from bullet items.
# Output: space-separated file paths on stdout
# Returns: 0 always (empty output if no files found)
extract_files_from_coder_summary() {
    local summary_file="${1:-${CODER_SUMMARY_FILE}}"

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

# --- Test counterpart inference -----------------------------------------------

# infer_test_counterparts — Given a space-separated list of source files,
# return the list augmented with likely test file counterparts.
# Heuristic: foo.py → test_foo.py, foo.ts → foo.test.ts, foo.sh → test_foo.sh
# Output: space-separated file paths (originals + inferred test paths)
# Returns: 0 always
infer_test_counterparts() {
    local file_list="${1:-}"
    local result="$file_list"

    local f
    local -a files=()
    read -ra files <<< "$file_list"

    for f in "${files[@]}"; do
        local base="${f##*/}"
        local name="${base%.*}"
        local ext="${base##*.}"

        # Skip files that are already test files
        if [[ "$name" == test_* ]] || [[ "$name" == *_test ]] || \
           [[ "$name" == *.test ]] || [[ "$name" == *.spec ]]; then
            continue
        fi

        # Generate counterparts based on language conventions
        case "$ext" in
            py)
                result="${result} test_${name}.${ext}"
                result="${result} ${name}_test.${ext}"
                ;;
            ts|tsx|js|jsx)
                result="${result} ${name}.test.${ext}"
                result="${result} ${name}.spec.${ext}"
                ;;
            sh|bash)
                result="${result} test_${name}.${ext}"
                ;;
            go)
                result="${result} ${name}_test.${ext}"
                ;;
            rs)
                # Rust tests are usually inline, but integration tests live in tests/
                result="${result} tests/${name}.${ext}"
                ;;
            java)
                result="${result} ${name}Test.${ext}"
                ;;
            rb)
                result="${result} ${name}_spec.${ext}"
                result="${result} test_${name}.${ext}"
                ;;
        esac
    done

    echo "$result"
    return 0
}
