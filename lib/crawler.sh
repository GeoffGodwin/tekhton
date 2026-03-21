#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# crawler.sh — Project crawler & index generator (Milestone 18)
#
# Breadth-first project crawler that produces PROJECT_INDEX.md — a structured,
# token-budgeted manifest of a project's architecture, file inventory,
# dependency structure, and sampled key files. No LLM calls.
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh (log, warn, error), detect.sh (_DETECT_EXCLUDE_DIRS)
# Also sources: crawler_inventory.sh, crawler_content.sh
# =============================================================================

# Source companion files
_CRAWLER_DIR="${BASH_SOURCE[0]%/*}"
source "${_CRAWLER_DIR}/crawler_inventory.sh"
source "${_CRAWLER_DIR}/crawler_content.sh"

# --- Exclusion list (consistent with detect.sh and replan_brownfield.sh) ------

_CRAWL_EXCLUDE_DIRS="${_DETECT_EXCLUDE_DIRS:-node_modules|.git|__pycache__|.dart_tool|build|dist|.next|vendor|third_party|.bundle|.gradle|target|.build|Pods|.pub-cache|.cargo}"

# --- Main entry point ---------------------------------------------------------

# crawl_project — Orchestrates crawl phases and writes PROJECT_INDEX.md.
# Args: $1 = project directory, $2 = budget in chars (default: 120000)
# Returns: 0 on success
crawl_project() {
    local project_dir="${1:-.}"
    local budget_chars="${2:-120000}"
    local index_file="${project_dir}/PROJECT_INDEX.md"

    log "Crawling project: ${project_dir} (budget: ${budget_chars} chars)"

    # Phase 1: Generate all sections
    local tree_section inventory_section dep_section
    local config_section test_section sample_section

    tree_section=$(_crawl_directory_tree "$project_dir" 6)
    inventory_section=$(_crawl_file_inventory "$project_dir")
    dep_section=$(_crawl_dependency_graph "$project_dir")
    config_section=$(_crawl_config_inventory "$project_dir")
    test_section=$(_crawl_test_structure "$project_dir")

    # Phase 2: Budget allocation
    local tree_size inventory_size dep_size config_size test_size
    tree_size=${#tree_section}
    inventory_size=${#inventory_section}
    dep_size=${#dep_section}
    config_size=${#config_section}
    test_size=${#test_section}

    local remaining_budget
    remaining_budget=$(_budget_allocator "$budget_chars" \
        "$tree_size" "$inventory_size" "$dep_size" "$config_size" "$test_size")

    # Phase 3: Sample files with remaining budget
    local file_list
    file_list=$(_list_tracked_files "$project_dir")
    sample_section=$(_crawl_sample_files "$project_dir" "$file_list" "$remaining_budget")

    # Phase 4: Truncate sections to budget allocations
    local budget_tree budget_inv budget_dep budget_cfg budget_test
    budget_tree=$(( budget_chars * 10 / 100 ))
    budget_inv=$(( budget_chars * 15 / 100 ))
    budget_dep=$(( budget_chars * 10 / 100 ))
    budget_cfg=$(( budget_chars * 5 / 100 ))
    budget_test=$(( budget_chars * 5 / 100 ))

    tree_section=$(_truncate_section "$tree_section" "$budget_tree")
    inventory_section=$(_truncate_section "$inventory_section" "$budget_inv")
    dep_section=$(_truncate_section "$dep_section" "$budget_dep")
    config_section=$(_truncate_section "$config_section" "$budget_cfg")
    test_section=$(_truncate_section "$test_section" "$budget_test")

    # Phase 5: Assemble and write index
    local header_section
    header_section=$(_build_index_header "$project_dir" "$file_list")

    {
        printf '%s\n\n' "$header_section"
        printf '## Directory Tree\n\n%s\n\n' "$tree_section"
        printf '## File Inventory\n\n%s\n\n' "$inventory_section"
        printf '## Key Dependencies\n\n%s\n\n' "$dep_section"
        printf '## Configuration Files\n\n%s\n\n' "$config_section"
        printf '## Test Infrastructure\n\n%s\n\n' "$test_section"
        printf '## Sampled File Content\n\n%s\n' "$sample_section"
    } > "$index_file"

    local final_size
    final_size=$(wc -c < "$index_file" | tr -d '[:space:]')
    success "PROJECT_INDEX.md written (${final_size} chars, budget: ${budget_chars})"
    return 0
}

# --- Budget allocator ---------------------------------------------------------

# _budget_allocator — Distributes token budget across sections.
# Fixed: tree 10%, inventory 15%, deps 10%, config 5%, tests 5%.
# Remaining 55% + surplus from thin sections → sampled file content.
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

    # Calculate surplus from sections that underflow their allocation
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
# Args: $1 = project directory, $2 = max depth (default: 6)
_crawl_directory_tree() {
    local project_dir="$1"
    local max_depth="${2:-6}"
    local output=""

    if command -v tree &>/dev/null; then
        local exclude_pattern
        exclude_pattern=$(echo "$_CRAWL_EXCLUDE_DIRS" | tr '|' '\n' | paste -sd'|')
        output=$(tree -L "$max_depth" --noreport --dirsfirst \
            -I "$exclude_pattern" "$project_dir" 2>/dev/null | head -500 || true)
    else
        # Fallback: find-based tree
        output=$(_find_based_tree "$project_dir" "$max_depth")
    fi

    # Add purpose annotations for well-known directories
    output=$(_annotate_directories "$output")
    printf '%s' "$output"
}

# _find_based_tree — Fallback directory listing when tree is unavailable.
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
        "${exclude_args[@]}" 2>/dev/null | sort | head -500 | \
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

# _truncate_section — Truncates text to fit within a character budget.
# Adds a marker if truncated.
_truncate_section() {
    local text="$1"
    local budget="$2"
    if [[ ${#text} -le "$budget" ]]; then
        printf '%s' "$text"
    else
        local truncated="${text:0:$budget}"
        # Cut at last newline to avoid mid-line truncation
        truncated="${truncated%$'\n'*}"
        printf '%s\n\n... (truncated to fit budget)' "$truncated"
    fi
}

# _build_index_header — Builds the PROJECT_INDEX.md header with metadata.
_build_index_header() {
    local project_dir="$1"
    local file_list="$2"
    local file_count total_lines scan_commit scan_date project_name

    file_count=$(echo "$file_list" | grep -c '.' || echo "0")
    total_lines=$(echo "$file_list" | while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ -f "${project_dir}/${f}" ]] && wc -l < "${project_dir}/${f}" 2>/dev/null || echo 0
    done | awk '{s+=$1} END {print s+0}')

    scan_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    project_name=$(basename "$project_dir")

    if git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
        scan_commit=$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    else
        scan_commit="non-git"
    fi

    cat <<EOF
# PROJECT_INDEX.md — ${project_name}

<!-- Last-Scan: ${scan_date} -->
<!-- Scan-Commit: ${scan_commit} -->
<!-- File-Count: ${file_count} -->
<!-- Total-Lines: ${total_lines} -->

**Project:** ${project_name}
**Scanned:** ${scan_date}
**Files:** ${file_count} | **Lines:** ${total_lines}
EOF
}
