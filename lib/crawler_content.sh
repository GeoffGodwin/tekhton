#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# crawler_content.sh — File sampling for PROJECT_INDEX.md
#
# Sourced by crawler.sh — do not run directly.
# Depends on: common.sh (log, warn), crawler.sh (_list_tracked_files)
# Also sources: crawler_deps.sh (dependency graph extraction)
#
# Note: Uses `local -n` (nameref) which requires Bash 4.3+.
# =============================================================================

# Source dependency parser
_CRAWLER_CONTENT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/crawler_deps.sh
source "${_CRAWLER_CONTENT_DIR}/crawler_deps.sh"

# --- File sampling ------------------------------------------------------------

# _crawl_sample_files — Reads and includes high-value file content.
# Priority: README > entry points > config > architecture docs > tests > source
# Args: $1 = project dir, $2 = file list, $3 = budget in chars
_crawl_sample_files() {
    local project_dir="$1"
    local file_list="$2"
    local budget="$3"
    local output=""
    local used=0

    # Build priority-ordered candidate list
    local -a candidates=()

    # Priority 1: README
    _add_candidate candidates "$file_list" "README.md" "README.rst" "README" "README.txt"
    # Priority 2: Entry points
    _add_candidate candidates "$file_list" "main.py" "app.py" "index.ts" "index.js" \
        "main.ts" "main.go" "main.rs" "lib.rs" "src/main.rs" "src/lib.rs" \
        "src/index.ts" "src/index.js" "src/app.ts" "src/app.js" "src/main.py" "cmd/main.go"
    # Priority 3: Primary config
    _add_candidate candidates "$file_list" "package.json" "Cargo.toml" "pyproject.toml" \
        "go.mod" "Gemfile" "pubspec.yaml" "composer.json"
    # Priority 4: Architecture docs
    _add_candidate candidates "$file_list" "ARCHITECTURE.md" "CONTRIBUTING.md" \
        "DESIGN.md" "docs/ARCHITECTURE.md" "docs/design.md"
    # Priority 5: Representative test (first match)
    local test_file
    test_file=$(echo "$file_list" | grep -E '\.(test|spec)\.[^.]+$|_test\.[^.]+$' | head -1 || true)
    [[ -n "$test_file" ]] && candidates+=("$test_file")
    # Priority 6: Representative source (first .py/.ts/.go/.rs in src/)
    local src_file
    src_file=$(echo "$file_list" | grep -E '^src/.*\.(py|ts|js|go|rs|java|rb)$' | head -1 || true)
    [[ -n "$src_file" ]] && candidates+=("$src_file")

    # Sample files within budget
    local f
    for f in "${candidates[@]+"${candidates[@]}"}"; do
        [[ "$used" -ge "$budget" ]] && break
        local full_path="${project_dir}/${f}"
        [[ ! -f "$full_path" ]] && continue

        # Skip binary files
        if _is_binary_file "$full_path"; then
            continue
        fi

        local remaining=$(( budget - used ))
        local content
        content=$(_read_sampled_file "$full_path" "$remaining")
        local content_size=${#content}
        [[ "$content_size" -eq 0 ]] && continue

        output+="### ${f}"$'\n\n'
        output+='```'"${f##*.}"$'\n'
        output+="${content}"$'\n'
        output+='```'$'\n\n'
        used=$(( used + content_size + ${#f} + 20 ))  # Account for markdown wrapper
    done

    [[ -z "$output" ]] && output="(no files sampled)"
    printf '%s' "$output"
}

# _add_candidate — Adds files to candidate list if they exist in the file list.
_add_candidate() {
    local -n _arr="$1"
    local flist="$2"
    shift 2
    local name
    for name in "$@"; do
        if echo "$flist" | grep -qx "$name" 2>/dev/null; then
            _arr+=("$name")
        fi
    done
}

# _is_binary_file — Checks if a file is binary.
# Uses null-byte check in first 512 bytes for portability.
_is_binary_file() {
    local file="$1"
    # Check first 512 bytes for null bytes via PCRE.
    # 2>/dev/null handles systems without PCRE (e.g., macOS BSD grep);
    # the extension-check fallback below catches binary files on those systems.
    if head -c 512 "$file" 2>/dev/null | grep -qP '\x00' 2>/dev/null; then
        return 0
    fi
    # Fallback: check file extension
    case "${file##*.}" in
        png|jpg|jpeg|gif|bmp|ico|svg|woff|woff2|ttf|eot|otf|\
        mp3|mp4|avi|mov|webm|ogg|wav|flac|\
        zip|gz|tar|bz2|7z|rar|xz|\
        pdf|doc|docx|xls|xlsx|ppt|pptx|\
        exe|dll|so|dylib|o|a|class|pyc|pyo|\
        db|sqlite|sqlite3)
            return 0 ;;
    esac
    return 1
}

# _read_sampled_file — Reads a file with line-budget awareness.
# Very large files (>1000 lines): first 50 + last 20 lines with omission marker.
# Normal files: full content, truncated to remaining char budget.
_read_sampled_file() {
    local file="$1"
    local char_budget="$2"
    local line_count
    line_count=$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]')

    local content
    if [[ "$line_count" -gt 1000 ]]; then
        local omitted=$(( line_count - 70 ))
        content=$(head -50 "$file" 2>/dev/null)
        content+=$'\n'"... (${omitted} lines omitted)"$'\n'
        content+=$(tail -20 "$file" 2>/dev/null)
    else
        content=$(cat "$file" 2>/dev/null || true)
    fi

    # Truncate to char budget
    if [[ ${#content} -gt "$char_budget" ]]; then
        content="${content:0:$char_budget}"
        # Cut at last newline
        content="${content%$'\n'*}"
        content+=$'\n'"... (truncated to fit budget)"
    fi

    printf '%s' "$content"
}
