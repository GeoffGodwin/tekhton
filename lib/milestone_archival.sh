#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_archival.sh — Milestone archival (CLAUDE.md → MILESTONE_ARCHIVE.md)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn(), success() from common.sh
# Expects: is_milestone_done(), get_milestone_title() from milestones.sh
# Expects: MILESTONE_ARCHIVE_FILE from config.sh
#
# Helpers extracted to milestone_archival_helpers.sh:
#   _extract_milestone_block, _get_initiative_name, _milestone_in_archive,
#   _insert_archive_pointer, _collapse_blank_lines, _replace_milestone_block
#
# Provides:
#   archive_completed_milestone      — move one [DONE] milestone to archive
#   archive_all_completed_milestones — archive all [DONE] milestones in bulk
# =============================================================================

# Source helpers from dedicated module
# shellcheck source=/dev/null
source "${TEKHTON_HOME:-.}/lib/milestone_archival_helpers.sh"

# archive_completed_milestone MILESTONE_NUM CLAUDE_MD_PATH
# Moves a completed milestone definition to MILESTONE_ARCHIVE.md.
# In DAG mode: reads the milestone file directly via dag_get_file().
# In inline mode: extracts from CLAUDE.md (original behavior).
# Returns 0 on success, 1 if not found, already archived, or not done.
archive_completed_milestone() {
    local num="$1"
    local claude_md="${2:-CLAUDE.md}"
    local archive_file="${MILESTONE_ARCHIVE_FILE:-MILESTONE_ARCHIVE.md}"

    if ! is_milestone_done "$num" "$claude_md"; then
        return 1
    fi

    if _milestone_in_archive "$num" "$archive_file"; then
        return 1
    fi

    local block=""
    local initiative="Milestone DAG"

    # DAG path: read milestone file directly
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        local id
        id=$(dag_number_to_id "$num")
        local file
        file=$(dag_get_file "$id" 2>/dev/null) || true
        if [[ -n "$file" ]]; then
            local milestone_dir
            milestone_dir=$(_dag_milestone_dir)
            if [[ -f "${milestone_dir}/${file}" ]]; then
                block=$(cat "${milestone_dir}/${file}")
            fi
        fi
        if [[ -z "$block" ]]; then
            return 1
        fi
    else
        # Inline path: extract from CLAUDE.md
        block=$(_extract_milestone_block "$num" "$claude_md") || return 1
        initiative=$(_get_initiative_name "$claude_md" "$num")
    fi

    if [[ ! -f "$archive_file" ]]; then
        cat > "$archive_file" << 'ARCHIVE_HEADER'
# Milestone Archive

Completed milestone definitions archived from CLAUDE.md.
See git history for the commit that completed each milestone.
ARCHIVE_HEADER
    fi

    {
        echo ""
        echo "---"
        echo ""
        echo "## Archived: $(date '+%Y-%m-%d') — ${initiative}"
        echo ""
        echo "$block"
    } >> "$archive_file"

    # In inline mode, also remove the block from CLAUDE.md
    if [[ "${MILESTONE_DAG_ENABLED:-true}" != "true" ]] \
       || ! declare -f has_milestone_manifest &>/dev/null \
       || ! has_milestone_manifest; then
        local tmp_file
        local tmp_dir="${TEKHTON_SESSION_DIR:-$(dirname "$claude_md")}"
        tmp_file="$(mktemp "${tmp_dir}/archival_XXXXXX" 2>/dev/null)" \
            || tmp_file="$(mktemp "$(dirname "$claude_md")/archival_XXXXXX")"

        awk -v num="$num" '
        BEGIN {
            in_block = 0; heading_level = 0
            safe_num = num
            gsub(/\./, "\\.", safe_num)
        }
        {
            if (!in_block && match($0, /^#{1,5}/) && $0 ~ /\[DONE\]/ && $0 ~ "[Mm]ilestone[[:space:]]+" safe_num "[[:space:]]*[^[:alnum:]]") {
                heading_level = RLENGTH
                in_block = 1
                next
            }

            if (in_block) {
                if (match($0, /^#{1,5}[[:space:]]/)) {
                    this_level = RLENGTH - 1
                    if (this_level <= heading_level) {
                        in_block = 0
                        print
                        next
                    }
                }
                next
            }

            print
        }
        ' "$claude_md" > "$tmp_file"

        mv -f "$tmp_file" "$claude_md"

        _insert_archive_pointer "$claude_md" "$initiative"
        _collapse_blank_lines "$claude_md"
    fi

    log "Archived milestone ${num} to ${archive_file}"
    return 0
}

# archive_all_completed_milestones CLAUDE_MD_PATH
# Archives all [DONE] milestones that still have full definitions in CLAUDE.md.
# Idempotent — skips milestones already archived or already summarized.
archive_all_completed_milestones() {
    local claude_md="${1:-CLAUDE.md}"

    if [[ ! -f "$claude_md" ]]; then
        return 0
    fi

    local archived_count=0

    # Find all [DONE] milestone numbers
    local done_nums
    done_nums=$(grep -oE '^\#{1,5}[[:space:]]*\[DONE\][[:space:]]*(M|m)ilestone[[:space:]]+([0-9]+([.][0-9]+)*)' "$claude_md" 2>/dev/null \
        | grep -oE '[0-9]+([.][0-9]+)*$' || true)

    if [[ -z "$done_nums" ]]; then
        return 0
    fi

    while IFS= read -r num; do
        if [[ -z "$num" ]]; then
            continue
        fi
        if archive_completed_milestone "$num" "$claude_md"; then
            archived_count=$((archived_count + 1))
        fi
    done <<< "$done_nums"

    if [[ "$archived_count" -gt 0 ]]; then
        log "Archived ${archived_count} completed milestone(s) from ${claude_md}"
    fi
}
