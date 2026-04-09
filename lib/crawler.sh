#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# crawler.sh — Project crawler & index generator (Milestone 18, M67/M69)
#
# Breadth-first project crawler that produces structured data files in
# .claude/index/ and generates PROJECT_INDEX.md from structured data.
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh (log, warn, error), detect.sh (_DETECT_EXCLUDE_DIRS)
# Also sources: crawler_inventory.sh, crawler_content.sh, crawler_emit.sh
# =============================================================================

# --- Shared JSON/index utilities (used by all crawler_*.sh emitters) ----------

# _json_escape — Escapes a string for safe embedding in JSON values.
# Handles: backslash, double-quote, tab, newline, carriage return.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# _ensure_index_dir — Creates the structured index directory and samples subdir.
_ensure_index_dir() {
    local index_dir="$1"
    mkdir -p "${index_dir}/samples"
}

# _emit_tree_txt — Writes complete directory tree to .claude/index/tree.txt.
# No truncation — full output preserved. M69 view generator handles display limits.
_emit_tree_txt() {
    local project_dir="$1" index_dir="$2"
    local tmp_file
    tmp_file=$(mktemp "${index_dir}/tree_XXXXXXXX")
    _crawl_directory_tree "$project_dir" 6 > "$tmp_file"
    printf '\n' >> "$tmp_file"
    mv "$tmp_file" "${index_dir}/tree.txt"
}

# Source companion files
_CRAWLER_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/crawler_inventory.sh
source "${_CRAWLER_DIR}/crawler_inventory.sh"
# shellcheck source=lib/crawler_content.sh
source "${_CRAWLER_DIR}/crawler_content.sh"
# shellcheck source=lib/crawler_emit.sh
source "${_CRAWLER_DIR}/crawler_emit.sh"

# --- Exclusion list (consistent with detect.sh and replan_brownfield.sh) ------

_CRAWL_EXCLUDE_DIRS="${_DETECT_EXCLUDE_DIRS:-node_modules|.git|__pycache__|.dart_tool|build|dist|.next|vendor|third_party|.bundle|.gradle|target|.build|Pods|.pub-cache|.cargo}"

# --- Main entry point ---------------------------------------------------------

# crawl_project — Writes structured data to .claude/index/ and generates
# PROJECT_INDEX.md view from structured data (M69).
# Args: $1 = project directory, $2 = budget in chars (default: PROJECT_INDEX_BUDGET)
# Returns: 0 on success
crawl_project() {
    local project_dir="${1:-.}"
    local budget_chars="${2:-${PROJECT_INDEX_BUDGET:-120000}}"
    local index_file="${project_dir}/PROJECT_INDEX.md"
    local index_dir="${project_dir}/.claude/index"

    log "Crawling project: ${project_dir} (budget: ${budget_chars} chars)"

    _ensure_index_dir "$index_dir"

    # Single file list call for all phases (M67 fix: was 4 separate calls)
    local file_list
    file_list=$(_list_tracked_files "$project_dir")

    # Doc quality (computed once, passed to meta emitter)
    local doc_quality_score=0
    if type -t assess_doc_quality &>/dev/null; then
        local dq_output
        dq_output=$(assess_doc_quality "$project_dir" 2>/dev/null || true)
        [[ -n "$dq_output" ]] && doc_quality_score=$(echo "$dq_output" | cut -d'|' -f1)
    fi

    # Phase 1: Emit structured data files to .claude/index/
    _emit_tree_txt "$project_dir" "$index_dir"
    _emit_inventory_jsonl "$project_dir" "$file_list" "$index_dir"
    _emit_dependencies_json "$project_dir" "$index_dir"
    _emit_configs_json "$project_dir" "$file_list" "$index_dir"
    _emit_tests_json "$project_dir" "$file_list" "$index_dir"
    _emit_sampled_files "$project_dir" "$file_list" "$index_dir" "$budget_chars"
    _emit_meta_json "$project_dir" "$index_dir" "$doc_quality_score"

    # Phase 2: Generate human-readable view from structured data (M69)
    generate_project_index_view "$project_dir" "$budget_chars"

    local final_size
    final_size=$(wc -c < "$index_file" | tr -d '[:space:]')
    success "PROJECT_INDEX.md written (${final_size} chars, budget: ${budget_chars})"
    return 0
}

# --- Budget allocator ---------------------------------------------------------

# _budget_allocator — Distributes token budget across sections.
# Fixed: tree 10%, inventory 15%, deps 10%, config 5%, tests 5%.
# Remaining 55% + surplus from thin sections -> sampled file content.
# Args: $1=total, $2=tree_size, $3=inv_size, $4=dep_size, $5=cfg_size, $6=test_size
# Prints: remaining budget for file sampling
_budget_allocator() {
    local total="$1"
    local tree_actual="$2" inv_actual="$3" dep_actual="$4"
    local cfg_actual="$5" test_actual="$6"

    local budget_tree=$(( total * 10 / 100 ))
    local budget_inv=$(( total * 15 / 100 ))
    local budget_dep=$(( total * 10 / 100 ))
    local budget_cfg=$(( total * 5 / 100 ))
    local budget_test=$(( total * 5 / 100 ))

    local surplus=0
    [[ "$tree_actual" -lt "$budget_tree" ]] && surplus=$(( surplus + budget_tree - tree_actual ))
    [[ "$inv_actual" -lt "$budget_inv" ]]   && surplus=$(( surplus + budget_inv - inv_actual ))
    [[ "$dep_actual" -lt "$budget_dep" ]]   && surplus=$(( surplus + budget_dep - dep_actual ))
    [[ "$cfg_actual" -lt "$budget_cfg" ]]   && surplus=$(( surplus + budget_cfg - cfg_actual ))
    [[ "$test_actual" -lt "$budget_test" ]] && surplus=$(( surplus + budget_test - test_actual ))

    local base_sample=$(( total * 55 / 100 ))
    echo $(( base_sample + surplus ))
}

# --- Directory tree -----------------------------------------------------------

# _crawl_directory_tree — Breadth-first traversal with purpose annotations.
# M67: no head -500 truncation; the view generator (index_view.sh) handles display limits.
# Args: $1 = project directory, $2 = max depth (default: 6)
_crawl_directory_tree() {
    local project_dir="$1"
    local max_depth="${2:-6}"
    local output=""

    if command -v tree &>/dev/null; then
        local exclude_pattern
        exclude_pattern=$(echo "$_CRAWL_EXCLUDE_DIRS" | tr '|' '\n' | paste -sd'|')
        output=$(tree -L "$max_depth" --noreport --dirsfirst \
            -I "$exclude_pattern" "$project_dir" 2>/dev/null || true)
    else
        output=$(_find_based_tree "$project_dir" "$max_depth")
    fi

    output=$(_annotate_directories "$output")
    printf '%s' "$output"
}

# _find_based_tree — Fallback directory listing when tree is unavailable.
# M67: no head -500 truncation.
_find_based_tree() {
    local project_dir="$1"
    local max_depth="$2"
    local exclude_args=()

    local IFS='|'
    local dir
    for dir in $_CRAWL_EXCLUDE_DIRS; do
        exclude_args+=(-not -path "*/${dir}/*" -not -name "$dir")
    done
    unset IFS

    find "$project_dir" -maxdepth "$max_depth" -type d \
        "${exclude_args[@]}" 2>/dev/null | sort | \
        sed "s|^${project_dir}|.|" || true
}

# _annotate_directories — Adds purpose hints for well-known directory names.
_annotate_directories() {
    local tree_text="$1"
    echo "$tree_text" | sed \
        -e 's|\(src\)\($\| \)|\1 [source]\2|' \
        -e 's|\(test\|tests\|__tests__\|spec\)\($\| \)|\1 [tests]\2|' \
        -e 's|\(docs\|documentation\)\($\| \)|\1 [documentation]\2|' \
        -e 's|\(config\|\.config\)\($\| \)|\1 [configuration]\2|' \
        -e 's|\(scripts\)\($\| \)|\1 [build/scripts]\2|' \
        -e 's|\(\.github\)\($\| \)|\1 [CI/CD]\2|' \
        -e 's|\(\.circleci\)\($\| \)|\1 [CI/CD]\2|'
}

# --- Helpers ------------------------------------------------------------------

# _list_tracked_files — Lists all project files respecting gitignore.
# Args: $1 = project directory
_list_tracked_files() {
    local project_dir="$1"
    if git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
        git -C "$project_dir" ls-files 2>/dev/null || true
    else
        local exclude_args=()
        local IFS='|'
        local dir
        for dir in $_CRAWL_EXCLUDE_DIRS; do
            exclude_args+=(-not -path "*/${dir}/*" -not -name "$dir")
        done
        unset IFS
        find "$project_dir" -type f "${exclude_args[@]}" 2>/dev/null | \
            sed "s|^${project_dir}/||" | sort || true
    fi
}

