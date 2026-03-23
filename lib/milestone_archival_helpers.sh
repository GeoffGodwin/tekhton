#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_archival_helpers.sh — Helpers for milestone archival
#
# Extracted from milestone_archival.sh to stay under the 300-line guideline.
# Sourced by milestone_archival.sh — do not run directly.
# Expects: TEKHTON_SESSION_DIR from caller
#
# Provides:
#   _extract_milestone_block   — extract a milestone block from CLAUDE.md
#   _get_initiative_name       — find the initiative heading for a milestone
#   _milestone_in_archive      — check if milestone already archived
#   _insert_archive_pointer    — insert archive reference comment
#   _collapse_blank_lines      — normalize consecutive blank lines
#   _replace_milestone_block   — replace a milestone block in CLAUDE.md
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
        if [[ "$in_block" = false ]] && [[ "$line" =~ ^(#{1,5})[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*[^[:alnum:]] ]]; then
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
# For inline milestones: matches the initiative section containing the heading.
# For DAG milestones: matches the initiative section containing the
#   milestone pointer comment (<!-- Milestones are managed as individual files).
_get_initiative_name() {
    local claude_md="$1"
    local num="$2"
    local current_initiative=""
    local num_pattern="${num//./\\.}"

    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+((Completed|Current|Future)[[:space:]]+)?Initiative:[[:space:]]*(.*) ]]; then
            current_initiative="${BASH_REMATCH[3]}"
            current_initiative="${current_initiative%"${current_initiative##*[![:space:]]}"}"
        fi
        # Inline match: milestone heading directly in CLAUDE.md
        if [[ "$line" =~ ^#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*[^[:alnum:]] ]]; then
            echo "${current_initiative:-Unknown Initiative}"
            return 0
        fi
        # DAG match: milestone pointer comment (milestones live in external files)
        if [[ "$line" == *"Milestones are managed as individual files"* ]]; then
            echo "${current_initiative:-Unknown Initiative}"
            return 0
        fi
    done < "$claude_md"

    echo "Unknown Initiative"
}

# _milestone_in_archive MILESTONE_NUM ARCHIVE_FILE [INITIATIVE]
# Returns 0 if the milestone is already present in the archive file.
# When INITIATIVE is provided, only matches milestones within sections
# for that initiative (prevents cross-version number collisions).
_milestone_in_archive() {
    local num="$1"
    local archive_file="$2"
    local initiative="${3:-}"

    if [[ ! -f "$archive_file" ]]; then
        return 1
    fi

    local num_pattern="${num//./\\.}"

    # If no initiative specified, fall back to global match (backward compat)
    if [[ -z "$initiative" ]]; then
        grep -qE "^#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*[^[:alnum:]]" "$archive_file" 2>/dev/null
        return $?
    fi

    # Initiative-scoped match: only check within sections for this initiative
    local in_initiative=false
    while IFS= read -r line; do
        # Track which initiative section we're in via archive headers
        if [[ "$line" =~ ^##[[:space:]]+Archived:.*—[[:space:]]*(.*) ]]; then
            local section_initiative="${BASH_REMATCH[1]}"
            section_initiative="${section_initiative%"${section_initiative##*[![:space:]]}"}"
            if [[ "$section_initiative" == "$initiative" ]]; then
                in_initiative=true
            else
                in_initiative=false
            fi
            continue
        fi
        if [[ "$in_initiative" = true ]] \
           && [[ "$line" =~ ^#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?(M|m)ilestone[[:space:]]+${num_pattern}[[:space:]]*[^[:alnum:]] ]]; then
            return 0
        fi
    done < "$archive_file"

    return 1
}

# _insert_archive_pointer CLAUDE_MD_PATH INITIATIVE_NAME
# Inserts '<!-- See MILESTONE_ARCHIVE.md for completed milestones -->' after the
# '### Milestone Plan' heading within the initiative section, if not already present.
_insert_archive_pointer() {
    local claude_md="$1"
    local initiative="$2"
    local pointer="<!-- See MILESTONE_ARCHIVE.md for completed milestones -->"

    # Find the ### Milestone Plan heading within the initiative section and insert
    # the pointer comment on the line immediately after it — but only if the pointer
    # is not already present within that specific initiative section.
    local tmp_dir="${TEKHTON_SESSION_DIR:-$(dirname "$claude_md")}"
    local tmp_file
    tmp_file="$(mktemp "${tmp_dir}/pointer_XXXXXX" 2>/dev/null)" \
        || tmp_file="$(mktemp "$(dirname "$claude_md")/pointer_XXXXXX")"

    local in_initiative=false
    local pending_insert=false
    local inserted=false
    while IFS= read -r line; do
        # If we just saw ### Milestone Plan, check if the next line is already
        # the pointer. If so, skip insertion. If not, insert before this line.
        if [[ "$pending_insert" = true ]]; then
            if [[ "$line" == "$pointer" ]]; then
                # Pointer already present in this section — no insertion needed
                pending_insert=false
            else
                echo "$pointer"
                inserted=true
                pending_insert=false
            fi
        fi
        echo "$line"
        if [[ "$line" =~ ^##[[:space:]]+(Completed|Current)[[:space:]]+Initiative: ]]; then
            if [[ "$line" == *"$initiative"* ]]; then
                in_initiative=true
            else
                in_initiative=false
            fi
        fi
        if [[ "$in_initiative" = true ]] && [[ "$line" =~ ^###[[:space:]]+Milestone[[:space:]]+Plan ]]; then
            pending_insert=true
            in_initiative=false
        fi
    done < "$claude_md" > "$tmp_file"
    # Handle edge case: ### Milestone Plan was the last line
    if [[ "$pending_insert" = true ]]; then
        echo "$pointer" >> "$tmp_file"
        inserted=true
    fi

    if [[ "$inserted" = true ]]; then
        mv -f "$tmp_file" "$claude_md"
    else
        rm -f "$tmp_file"
    fi
}

# _collapse_blank_lines FILEPATH
# Collapses 3+ consecutive blank lines down to 2 blank lines.
_collapse_blank_lines() {
    local filepath="$1"
    local tmp_dir="${TEKHTON_SESSION_DIR:-$(dirname "$filepath")}"
    local tmp_file
    tmp_file="$(mktemp "${tmp_dir}/collapse_XXXXXX" 2>/dev/null)" \
        || tmp_file="$(mktemp "$(dirname "$filepath")/collapse_XXXXXX")"

    awk '
    BEGIN { blank_count = 0 }
    /^[[:space:]]*$/ {
        blank_count++
        if (blank_count <= 2) print
        next
    }
    {
        blank_count = 0
        print
    }
    ' "$filepath" > "$tmp_file"

    mv -f "$tmp_file" "$filepath"
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
        if (!in_block && match($0, /^#{1,5}/) && $0 ~ "[Mm]ilestone[[:space:]]+" safe_num "[[:space:]]*[^[:alnum:]]") {
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
