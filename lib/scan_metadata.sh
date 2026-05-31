#!/usr/bin/env bash
# =============================================================================
# scan_metadata.sh — Read scan metadata from .claude/index/meta.json (or the
# legacy markdown header) for callers that still need it.
#
# Extracted from the deleted lib/rescan_helpers.sh during the m30.1 cutover.
# The function was a private helper for the incremental rescan path and for
# brownfield replan (lib/replan_brownfield.sh). Rescan now degrades to a
# full crawl via the Go binary; brownfield replan still needs to read the
# last scan commit out of meta.json, so the function survives here as a
# standalone helper.
#
# Sourced by lib/replan_brownfield.sh (and tekhton-legacy.sh for the
# `--rescan` / `--replan` paths) — do not run directly.
# =============================================================================

# _extract_scan_metadata — Read a metadata field from the structured
# .claude/index/meta.json (preferred) or the legacy markdown header
# `<!-- Field: value -->` (fallback for projects pre-M68).
# Args: $1 = index file path (e.g. PROJECT_INDEX_FILE), $2 = field name
#       (one of: Scan-Commit, Last-Scan, File-Count, Total-Lines).
# Output: field value on stdout, empty string when absent.
_extract_scan_metadata() {
    local index_file="$1"
    local field="$2"
    local project_dir
    project_dir=$(dirname "$index_file")
    local meta_file="${project_dir}/.claude/index/meta.json"

    if [[ -f "$meta_file" ]]; then
        local json_field=""
        case "$field" in
            Scan-Commit) json_field="scan_commit" ;;
            Last-Scan)   json_field="scan_date" ;;
            File-Count)  json_field="file_count" ;;
            Total-Lines) json_field="total_lines" ;;
        esac
        if [[ -n "$json_field" ]]; then
            local value
            value=$(grep "\"${json_field}\"" "$meta_file" 2>/dev/null | \
                sed 's/.*: *"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/' | tr -d '[:space:]' || true)
            if [[ -n "$value" ]]; then
                printf '%s' "$value"
                return
            fi
        fi
    fi

    # Legacy fallback: HTML-comment markdown header.
    grep "<!-- ${field}:" "$index_file" 2>/dev/null | \
        sed "s/.*<!-- ${field}: *\(.*\) *-->.*/\1/" | \
        tr -d '[:space:]' || true
}
