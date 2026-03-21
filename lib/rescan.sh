#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# rescan.sh — Incremental rescan & index maintenance (Milestone 20)
#
# Updates PROJECT_INDEX.md incrementally using git diff since the last scan.
# Falls back to full crawl when incremental is not possible.
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh (log, warn, error, success, header),
#             crawler.sh (crawl_project, _list_tracked_files, _crawl_*),
#             detect.sh (detect_languages, detect_frameworks),
#             detect_commands.sh (detect_commands),
#             detect_report.sh (format_detection_report)
# Also sources: rescan_helpers.sh
# =============================================================================

# Source companion file
_RESCAN_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/rescan_helpers.sh
source "${_RESCAN_DIR}/rescan_helpers.sh"

# --- Main entry point ---------------------------------------------------------

# rescan_project — Incrementally update PROJECT_INDEX.md or fall back to full crawl.
# Args: $1 = project directory, $2 = budget in chars (default: 120000),
#       $3 = "full" to force full crawl (optional)
rescan_project() {
    local project_dir="${1:-.}"
    local budget_chars="${2:-120000}"
    local force_full="${3:-}"
    local index_file="${project_dir}/PROJECT_INDEX.md"

    header "Tekhton — Project Rescan"

    # Force full crawl if requested
    if [[ "$force_full" == "full" ]]; then
        log "Full rescan requested — running complete crawl..."
        crawl_project "$project_dir" "$budget_chars"
        return $?
    fi

    # Fall back to full crawl if no existing index
    if [[ ! -f "$index_file" ]]; then
        log "No existing PROJECT_INDEX.md — running full crawl..."
        crawl_project "$project_dir" "$budget_chars"
        return $?
    fi

    # Check if this is a git repo
    if ! git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
        warn "Not a git repository — falling back to full crawl."
        crawl_project "$project_dir" "$budget_chars"
        return $?
    fi

    # Extract last scan commit from index
    local last_scan_commit
    last_scan_commit=$(_extract_scan_metadata "$index_file" "Scan-Commit")

    if [[ -z "$last_scan_commit" ]] || [[ "$last_scan_commit" == "non-git" ]]; then
        log "No scan commit recorded — running full crawl..."
        crawl_project "$project_dir" "$budget_chars"
        return $?
    fi

    # Validate that the recorded commit still exists (may have been rebased away)
    if ! git -C "$project_dir" rev-parse --verify "${last_scan_commit}^{commit}" &>/dev/null; then
        warn "Recorded scan commit ${last_scan_commit} no longer exists (rebased?)."
        log "Falling back to full crawl..."
        crawl_project "$project_dir" "$budget_chars"
        return $?
    fi

    # Get changed files since last scan
    local changed_files
    changed_files=$(_get_changed_files_since_scan "$project_dir" "$last_scan_commit")

    if [[ -z "$changed_files" ]]; then
        success "No changes since last scan (${last_scan_commit}). Index is up to date."
        return 0
    fi

    local change_count
    change_count=$(echo "$changed_files" | wc -l | tr -d '[:space:]')
    log "Found ${change_count} changed files since commit ${last_scan_commit}"

    # Detect change significance
    local significance
    significance=$(_detect_significant_changes "$changed_files")
    log "Change significance: ${significance}"

    # For major changes, a full crawl produces better results
    if [[ "$significance" == "major" ]]; then
        log "Major structural changes detected — running full crawl for accuracy..."
        crawl_project "$project_dir" "$budget_chars"
        return $?
    fi

    # Perform incremental update
    log "Performing incremental index update..."
    _update_index_sections "$index_file" "$project_dir" "$changed_files" "$budget_chars"

    # Record new scan metadata
    _record_scan_metadata "$index_file" "$project_dir"

    local final_size
    final_size=$(wc -c < "$index_file" | tr -d '[:space:]')
    success "PROJECT_INDEX.md updated incrementally (${final_size} chars)"
    return 0
}

# --- Index section updates ----------------------------------------------------

# _update_index_sections — Surgically updates affected sections of PROJECT_INDEX.md.
# Args: $1 = index file, $2 = project dir, $3 = changed files, $4 = budget
_update_index_sections() {
    local index_file="$1"
    local project_dir="$2"
    local changed_files="$3"
    local budget_chars="$4"

    # Determine which sections need regeneration
    local regen_inventory=false
    local regen_tree=false
    local regen_deps=false
    local regen_samples=false
    local regen_config=false

    local has_new_dirs=false
    local has_manifest_change=false
    local has_config_change=false

    while IFS=$'\t' read -r status filepath _rest; do
        [[ -z "$status" ]] && continue

        # Any file change means inventory needs updating
        regen_inventory=true

        case "$status" in
            A*|D*)
                local dir
                dir=$(dirname "$filepath")
                if [[ "$dir" != "." ]]; then
                    has_new_dirs=true
                fi
                ;;
            R*)
                has_new_dirs=true
                ;;
        esac

        if _is_manifest_file "$filepath"; then
            has_manifest_change=true
        fi

        if _is_config_file "$filepath"; then
            has_config_change=true
        fi
    done <<< "$changed_files"

    [[ "$has_new_dirs" == true ]] && regen_tree=true
    [[ "$has_manifest_change" == true ]] && regen_deps=true
    [[ "$has_config_change" == true ]] && regen_config=true

    # Check if any currently-sampled files were modified or deleted
    local current_samples
    current_samples=$(_extract_sampled_files "$index_file")
    if [[ -n "$current_samples" ]]; then
        while IFS= read -r sample; do
            if echo "$changed_files" | grep -qF "$sample" 2>/dev/null; then
                regen_samples=true
                break
            fi
        done <<< "$current_samples"
    fi

    # Also resample if new high-priority files were added
    if echo "$changed_files" | grep -qE '^A.*\.(md|json|toml|yaml|yml)$' 2>/dev/null; then
        regen_samples=true
    fi

    # Read current index content
    local current_content
    current_content=$(cat "$index_file")

    if [[ "$regen_tree" == true ]]; then
        log "  Regenerating directory tree..."
        local new_tree
        new_tree=$(_crawl_directory_tree "$project_dir" 6)
        new_tree=$(_truncate_section "$new_tree" $(( budget_chars * 10 / 100 )))
        current_content=$(_replace_section "$current_content" "Directory Tree" "$new_tree")
    fi

    if [[ "$regen_inventory" == true ]]; then
        log "  Regenerating file inventory..."
        local new_inventory
        new_inventory=$(_crawl_file_inventory "$project_dir")
        new_inventory=$(_truncate_section "$new_inventory" $(( budget_chars * 15 / 100 )))
        current_content=$(_replace_section "$current_content" "File Inventory" "$new_inventory")
    fi

    if [[ "$regen_deps" == true ]]; then
        log "  Regenerating dependencies..."
        local new_deps
        new_deps=$(_crawl_dependency_graph "$project_dir")
        new_deps=$(_truncate_section "$new_deps" $(( budget_chars * 10 / 100 )))
        current_content=$(_replace_section "$current_content" "Key Dependencies" "$new_deps")
    fi

    if [[ "$regen_config" == true ]]; then
        log "  Regenerating config inventory..."
        local new_config
        new_config=$(_crawl_config_inventory "$project_dir")
        new_config=$(_truncate_section "$new_config" $(( budget_chars * 5 / 100 )))
        current_content=$(_replace_section "$current_content" "Configuration Files" "$new_config")
    fi

    if [[ "$regen_samples" == true ]]; then
        log "  Re-sampling modified key files..."
        local file_list remaining_budget new_samples
        file_list=$(_list_tracked_files "$project_dir")
        remaining_budget=$(( budget_chars * 55 / 100 ))
        new_samples=$(_crawl_sample_files "$project_dir" "$file_list" "$remaining_budget")
        current_content=$(_replace_section "$current_content" "Sampled File Content" "$new_samples")
    fi

    local temp_file
    temp_file=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/rescan_XXXXXXXX")
    printf '%s\n' "$current_content" > "$temp_file"
    mv "$temp_file" "$index_file"
}
