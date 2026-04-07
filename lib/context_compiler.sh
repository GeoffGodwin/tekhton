#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# context_compiler.sh — Task-scoped context assembly (Milestone 2)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn(), count_lines() from common.sh
#          check_context_budget() from context.sh
# Provides: extract_relevant_sections(), build_context_packet(),
#           compress_context()
# Sources: lib/context_budget.sh for budget enforcement functions
# =============================================================================

# Source budget enforcement functions
# shellcheck disable=SC1091
source "$TEKHTON_HOME/lib/context_budget.sh"

# --- _extract_keywords — Extracts keywords from task string and file paths ---
# Parses the task string for significant words and extracts file paths from
# a scout report or coder summary.
# Usage: _extract_keywords "$task" "$scout_or_summary_file"
# Output: newline-separated list of keywords (lowercase)

_extract_keywords() {
    local task="$1"
    local ref_file="${2:-}"

    local keywords=""

    # Extract significant words from task (4+ chars, skip common stop words)
    local task_words
    task_words=$(echo "$task" | tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alnum:]_-' '\n' | \
        awk 'length >= 4 && !/^(this|that|with|from|into|have|been|will|would|should|could|must|also|when|then|each|only|just|does|done|make|like|some|more|most|very|than|what|which|where|after|before|implement|milestone)$/' | \
        sort -u)
    keywords="${task_words}"

    # Extract file paths from reference file (scout report or coder summary)
    if [[ -n "$ref_file" ]] && [[ -f "$ref_file" ]]; then
        local file_words
        # Match paths like lib/foo.sh, stages/bar.sh, src/component.ts
        file_words=$(grep -oE '[a-zA-Z0-9_/.-]+\.[a-z]{1,4}' "$ref_file" 2>/dev/null | \
            sed 's|.*/||' | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | \
            sort -u || true)
        if [[ -n "$file_words" ]]; then
            keywords="${keywords}
${file_words}"
        fi
    fi

    # Deduplicate and output
    echo "$keywords" | sort -u | grep -v '^$' || true
}

# =============================================================================
# extract_relevant_sections — Filters a markdown file to sections matching keywords
#
# Splits the file on ## headings, keeps sections whose heading or body contains
# at least one keyword. Returns the filtered content.
#
# Usage: extract_relevant_sections "$file_content" "$keywords_newline_separated"
# Output: filtered markdown content (stdout)
#
# If no sections match, returns empty string (caller must handle fallback).
# =============================================================================

extract_relevant_sections() {
    local content="$1"
    local keywords="$2"

    if [[ -z "$content" ]] || [[ -z "$keywords" ]]; then
        echo "$content"
        return
    fi

    # Build a grep -i pattern from keywords (pipe-separated)
    local pattern
    pattern=$(echo "$keywords" | tr '\n' '|' | sed 's/|$//')
    if [[ -z "$pattern" ]]; then
        echo "$content"
        return
    fi

    # Use awk to split on ## headings and filter sections
    local filtered
    # Convert pattern to lowercase for case-insensitive matching (portable —
    # avoids gawk-only IGNORECASE extension).
    local lc_pattern
    lc_pattern=$(echo "$pattern" | tr '[:upper:]' '[:lower:]')

    filtered=$(echo "$content" | LC_ALL=C awk -v pat="$lc_pattern" '
    BEGIN {
        section = ""
        header = ""
        in_section = 0
        result = ""
        # Keep everything before the first ## heading (preamble)
        preamble = ""
        seen_heading = 0
    }
    /^## / {
        # Process previous section
        if (in_section && (tolower(header) ~ pat || tolower(section) ~ pat)) {
            result = result header section
        }
        header = $0 "\n"
        section = ""
        in_section = 1
        seen_heading = 1
        next
    }
    {
        if (!seen_heading) {
            preamble = preamble $0 "\n"
        } else {
            section = section $0 "\n"
        }
    }
    END {
        # Process last section
        if (in_section && (tolower(header) ~ pat || tolower(section) ~ pat)) {
            result = result header section
        }
        # Always include preamble (title, intro text)
        printf "%s%s", preamble, result
    }')

    echo "$filtered"
}

# =============================================================================
# compress_context — Applies compression to a context component
#
# Strategies:
#   truncate          — Keep first N lines (default: 50)
#   summarize_headings — Keep only ## and ### headings
#   omit              — Remove entirely
#
# Usage: compress_context "$content" "strategy" [max_lines]
# Output: compressed content (stdout)
# =============================================================================

compress_context() {
    local content="$1"
    local strategy="$2"
    local max_lines="${3:-50}"

    case "$strategy" in
        truncate)
            local line_count
            line_count=$(echo "$content" | wc -l)
            line_count=$(echo "$line_count" | tr -d '[:space:]')
            if [[ "$line_count" -gt "$max_lines" ]]; then
                echo "$content" | head -n "$max_lines"
                echo "[... truncated from ${line_count} to ${max_lines} lines]"
            else
                echo "$content"
            fi
            ;;
        summarize_headings)
            echo "$content" | grep -E '^#{1,3} ' || true
            ;;
        omit)
            # Return empty — caller handles the note
            ;;
        *)
            # Unknown strategy — return as-is
            echo "$content"
            ;;
    esac
}

# =============================================================================
# build_context_packet — Assembles task-scoped context for an agent stage
#
# When CONTEXT_COMPILER_ENABLED=true, filters large artifacts to relevant
# sections based on task keywords. Falls back to full content when keyword
# extraction yields zero matches or when sections are marked as always-full.
#
# Usage: build_context_packet "stage" "$task" "$model"
#
# Reads from exported context block variables (ARCHITECTURE_BLOCK, etc.)
# and writes filtered versions back to those variables.
# Also handles compression when context exceeds budget.
#
# Stage-specific behavior:
#   coder   — Architecture always full; other blocks filtered
#   review  — Architecture filtered to files from CODER_SUMMARY.md
#   tester  — Architecture filtered to files from CODER_SUMMARY.md
# =============================================================================

build_context_packet() {
    local stage="$1"
    local task="$2"
    local model="$3"

    if [[ "${CONTEXT_COMPILER_ENABLED:-false}" != "true" ]]; then
        return
    fi

    # Extract keywords from task and available reference files (M47: cache per ref_file)
    local ref_file=""
    if [[ -f "SCOUT_REPORT.md" ]]; then
        ref_file="SCOUT_REPORT.md"
    elif [[ -f "CODER_SUMMARY.md" ]]; then
        ref_file="CODER_SUMMARY.md"
    fi

    local keywords
    local _cache_key="${task}::${ref_file}"
    if [[ "${_CACHED_KEYWORDS_KEY:-}" == "$_cache_key" ]] && [[ -n "${_CACHED_KEYWORDS:-}" ]]; then
        keywords="$_CACHED_KEYWORDS"
    else
        keywords=$(_extract_keywords "$task" "$ref_file")
        _CACHED_KEYWORDS_KEY="$_cache_key"
        _CACHED_KEYWORDS="$keywords"
        export _CACHED_KEYWORDS_KEY _CACHED_KEYWORDS
    fi

    if [[ -z "$keywords" ]]; then
        log "[context-compiler] No keywords extracted — using full context (1.0 fallback)"
        return
    fi

    log "[context-compiler] Extracted keywords: $(echo "$keywords" | tr '\n' ', ' | sed 's/,$//')"

    # --- Stage-specific filtering ---

    case "$stage" in
        coder)
            # Architecture stays FULL for coder — it needs the complete map
            # Filter other blocks if they are large
            _filter_block "PRIOR_REVIEWER_CONTEXT" "$keywords"
            _filter_block "PRIOR_TESTER_CONTEXT" "$keywords"
            _filter_block "NON_BLOCKING_CONTEXT" "$keywords"
            _filter_block "PRIOR_PROGRESS_CONTEXT" "$keywords"
            ;;
        review)
            # Filter architecture to sections referencing modified files
            _filter_block "ARCHITECTURE_CONTENT" "$keywords"
            ;;
        tester)
            # Filter architecture to sections referencing modified files
            _filter_block "ARCHITECTURE_CONTENT" "$keywords"
            ;;
    esac

    # --- Budget-based compression ---
    # Estimate total context and compress if over budget
    _compress_if_over_budget "$stage" "$model"
}

