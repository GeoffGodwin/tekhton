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
# Provides:
#   archive_completed_milestone      — move one [DONE] milestone to archive
#   archive_all_completed_milestones — archive all [DONE] milestones in bulk
# =============================================================================

# _extract_milestone_block MILESTONE_NUM CLAUDE_MD_PATH
# Extracts the full definition block for a milestone from CLAUDE.md.
# Outputs the block from the milestone heading to the next sibling heading.
# Returns 0 if found and multi-line (not already archived), 1 otherwise.
_extract_milestone_block() {
    local num="$1"
    local claude_md="$2"

    if [[ ! -f "$claude_md" ]]; then
        return 1
    fi

    local num_pattern="${num//./\\.}"
    local block=""
    local in_block=false
    local heading_level=0
    local line_count=0

    while IFS= read -r line; do
        if [[ "$in_block" = false ]] && [[ "$line" =~ ^(#{1,5})[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*([:.\ -]|—) ]]; then
            heading_level=${#BASH_REMATCH[1]}
            in_block=true
            block="${line}"
            line_count=1
            continue
        fi

        if [[ "$in_block" = true ]]; then
            if [[ "$line" =~ ^(#{1,5})[[:space:]] ]]; then
                local this_level=${#BASH_REMATCH[1]}
                if [[ "$this_level" -le "$heading_level" ]]; then
                    break
                fi
            fi
            block="${block}"$'\n'"${line}"
            line_count=$((line_count + 1))
        fi
    done < "$claude_md"

    if [[ "$in_block" = false ]]; then
        return 1
    fi

    if [[ "$line_count" -le 1 ]]; then
        return 1
    fi

    echo "$block"
    return 0
}

# _get_initiative_name CLAUDE_MD_PATH MILESTONE_NUM
# Finds the initiative name (## heading) that contains the given milestone.
_get_initiative_name() {
    local claude_md="$1"
    local num="$2"
    local current_initiative=""
    local num_pattern="${num//./\\.}"

    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+(Completed|Current)[[:space:]]+Initiative:[[:space:]]*(.*) ]]; then
            current_initiative="${BASH_REMATCH[2]}"
            current_initiative="${current_initiative%"${current_initiative##*[![:space:]]}"}"
        fi
        if [[ "$line" =~ ^#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*([:.\ -]|—) ]]; then
            echo "${current_initiative:-Unknown Initiative}"
            return 0
        fi
    done < "$claude_md"

    echo "Unknown Initiative"
}

# _milestone_in_archive MILESTONE_NUM ARCHIVE_FILE
# Returns 0 if the milestone is already present in the archive file.
_milestone_in_archive() {
    local num="$1"
    local archive_file="$2"

    if [[ ! -f "$archive_file" ]]; then
        return 1
    fi

    local num_pattern="${num//./\\.}"
    # Match milestone heading with portable delimiter pattern (avoids em-dash in char class)
    grep -qE "^#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*([:.\-]|—)" "$archive_file" 2>/dev/null
}

# archive_completed_milestone MILESTONE_NUM CLAUDE_MD_PATH
# Moves a completed milestone definition from CLAUDE.md to MILESTONE_ARCHIVE.md.
# 1. Extracts the full block from CLAUDE.md
# 2. Appends to MILESTONE_ARCHIVE.md with timestamp and initiative name
# 3. Replaces the full block in CLAUDE.md with a one-line summary
# Returns 0 on success, 1 if not found, already archived, or not [DONE].
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

    local block
    block=$(_extract_milestone_block "$num" "$claude_md") || return 1

    local title
    title=$(get_milestone_title "$num" "$claude_md" 2>/dev/null) || true

    local initiative
    initiative=$(_get_initiative_name "$claude_md" "$num")

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

    local summary_line="#### [DONE] Milestone ${num}: ${title}"

    local tmp_file
    local tmp_dir="${TEKHTON_SESSION_DIR:-$(dirname "$claude_md")}"
    tmp_file="$(mktemp "${tmp_dir}/archival_XXXXXX" 2>/dev/null)" \
        || tmp_file="$(mktemp "$(dirname "$claude_md")/archival_XXXXXX")"

    awk -v num="$num" -v summary="$summary_line" '
    BEGIN { in_block = 0; heading_level = 0 }
    {
        safe_num = num
        gsub(/\./, "\\.", safe_num)

        if (!in_block && match($0, /^#{1,5}/) && $0 ~ /\[DONE\]/ && $0 ~ "[Mm]ilestone[[:space:]]+" safe_num "[[:space:]]*([:. -]|—)") {
            heading_level = RLENGTH
            in_block = 1
            print summary
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

    log "Archived milestone ${num} to ${archive_file}"
    return 0
}

# _replace_milestone_block MILESTONE_NUM CLAUDE_MD_PATH REPLACEMENT_TEXT
# Replaces the full milestone block in CLAUDE.md with the given text.
# Used by both archival and splitting operations. Returns 0 on success, 1 on failure.
_replace_milestone_block() {
    local num="$1"
    local claude_md="$2"
    local replacement="$3"

    if [[ ! -f "$claude_md" ]]; then
        return 1
    fi

    # Escape dots in milestone number for regex
    local num_pattern="${num//./\\.}"

    # Write replacement to a temp file for awk to read
    local tmp_dir="${TEKHTON_SESSION_DIR:-$(dirname "$claude_md")}"
    local rep_file
    rep_file="$(mktemp "${tmp_dir}/rep_XXXXXX" 2>/dev/null)" \
        || rep_file="$(mktemp "$(dirname "$claude_md")/rep_XXXXXX")"
    echo "$replacement" > "$rep_file"

    local tmp_file
    tmp_file="$(mktemp "${tmp_dir}/out_XXXXXX" 2>/dev/null)" \
        || tmp_file="$(mktemp "$(dirname "$claude_md")/out_XXXXXX")"

    awk -v num="$num" -v repfile="$rep_file" '
    BEGIN {
        in_block = 0; heading_level = 0; matched = 0
        safe_num = num
        gsub(/\./, "\\.", safe_num)
    }
    {
        if (!in_block && match($0, /^#{1,5}/) && $0 ~ "[Mm]ilestone[[:space:]]+" safe_num "[[:space:]]*([:. -]|—)") {
            heading_level = RLENGTH
            in_block = 1
            matched = 1
            while ((getline line < repfile) > 0) {
                print line
            }
            close(repfile)
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
    END { exit (matched ? 0 : 1) }
    ' "$claude_md" > "$tmp_file" || {
        # awk exits 1 when the heading was not matched (END { exit (matched ? 0 : 1) }).
        # Clean up temp files before propagating the error.
        rm -f "$tmp_file" "$rep_file"
        return 1
    }

    mv -f "$tmp_file" "$claude_md"
    rm -f "$rep_file"
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
    done_nums=$(grep -oE '^\#{1,5}[[:space:]]*\[DONE\][[:space:]]*(M|m)ilestone[[:space:]]+([0-9]+([.][0-9]+)?)' "$claude_md" 2>/dev/null \
        | grep -oE '[0-9]+([.][0-9]+)?$' || true)

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
