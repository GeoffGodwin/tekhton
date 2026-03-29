#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_single.sh — Single-note utility functions for --human mode
#
# Extracted from notes.sh to stay under the 300-line guideline.
# Sourced by tekhton.sh after notes.sh — do not run directly.
# Expects: LOG_DIR, TIMESTAMP from caller
# Operates on HUMAN_NOTES.md in the current directory.
#
# Provides:
#   _escape_sed_pattern    — regex escaping for sed patterns
#   _section_for_tag       — tag-to-section heading mapping
#   pick_next_note         — priority-ordered note selection
#   claim_single_note      — mark one note [ ] → [~]
#   resolve_single_note    — mark one note [~] → [x] or [ ]
#   extract_note_text      — strip checkbox prefix
#   count_unchecked_notes  — count remaining [ ] notes
# =============================================================================

# _escape_sed_pattern — Escapes regex special characters for safe sed matching.
# Currently unused: claim_single_note/resolve_single_note use exact string
# matching instead. Retained for 15.4.2/15.4.3 which may need sed-based matching.
# Usage: escaped=$(_escape_sed_pattern "$text")
_escape_sed_pattern() {
    # shellcheck disable=SC2016
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|/&]/\\&/g'
}

# _section_for_tag — Maps a tag filter to the HUMAN_NOTES.md section heading.
# BUG → ## Bugs, FEAT → ## Features, POLISH → ## Polish
_section_for_tag() {
    local tag="${1:-}"
    case "$tag" in
        BUG)    echo "## Bugs" ;;
        FEAT)   echo "## Features" ;;
        POLISH) echo "## Polish" ;;
        *)      echo "" ;;
    esac
}

# pick_next_note — Returns the first unchecked note from HUMAN_NOTES.md in priority
# order: ## Bugs first, then ## Features, then ## Polish.
# If tag_filter is set, only scans the corresponding section.
# Usage: note_line=$(pick_next_note "BUG")  # or "" for all sections
pick_next_note() {
    local tag_filter="${1:-}"

    if [[ ! -f "HUMAN_NOTES.md" ]]; then
        echo ""
        return 0
    fi

    local sections
    if [[ -n "$tag_filter" ]]; then
        local target_section
        target_section=$(_section_for_tag "$tag_filter")
        if [[ -z "$target_section" ]]; then
            echo ""
            return 0
        fi
        sections=("$target_section")
    else
        sections=("## Bugs" "## Features" "## Polish")
    fi

    local section
    for section in "${sections[@]}"; do
        local result
        result=$(awk -v sect="$section" '
            BEGIN { in_section = 0 }
            $0 == sect { in_section = 1; next }
            in_section && /^## / { exit }
            in_section && /^- \[ \] / { print; exit }
        ' HUMAN_NOTES.md)
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    done

    echo ""
    return 0
}

# claim_single_note — Marks exactly ONE note from [ ] to [~] in HUMAN_NOTES.md.
# Archives pre-run snapshot before modification.
# Usage: claim_single_note "- [ ] [BUG] Fix the thing"
claim_single_note() {
    local note_line="$1"

    if [[ ! -f "HUMAN_NOTES.md" ]] || [[ -z "$note_line" ]]; then
        return 1
    fi

    # Archive pre-run snapshot
    if [[ -n "${LOG_DIR:-}" ]] && [[ -n "${TIMESTAMP:-}" ]] && [[ -d "${LOG_DIR:-}" ]]; then
        cp "HUMAN_NOTES.md" "${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md"
    else
        cp "HUMAN_NOTES.md" "HUMAN_NOTES.md.bak"
    fi

    # Replace first occurrence of the exact [ ] line with [~]
    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" = "$note_line" ]]; then
            # Replace [ ] with [~]
            printf '%s\n' "${line/\[ \]/[~]}"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "HUMAN_NOTES.md" > "$tmpfile"
    mv "$tmpfile" "HUMAN_NOTES.md"

    if [[ "$found" -eq 1 ]]; then
        return 0
    fi
    return 1
}

# resolve_single_note — Resolves a single in-progress note.
# If exit_code=0: [~] → [x]. If non-zero: [~] → [ ].
# The note_line should be the ORIGINAL line (with [ ]); this function
# reconstructs the [~] version to match against the file.
#
# Resilience: If the [~] form is not found (e.g., an agent rewrote the file
# and clobbered the marker back to [ ]), falls back to matching the original
# [ ] form. This prevents silent resolution failures when agents have write
# access to HUMAN_NOTES.md.
# Usage: resolve_single_note "- [ ] [BUG] Fix the thing" 0
resolve_single_note() {
    local note_line="$1"
    local exit_code="${2:-1}"

    if [[ ! -f "HUMAN_NOTES.md" ]] || [[ -z "$note_line" ]]; then
        return 1
    fi

    # Reconstruct the [~] version of the note line
    local claimed_line="${note_line/\[ \]/[~]}"

    local replacement
    if [[ "$exit_code" -eq 0 ]]; then
        replacement="${note_line/\[ \]/[x]}"
    else
        replacement="$note_line"
    fi

    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" = "$claimed_line" ]]; then
            # Primary match: [~] form found as expected
            printf '%s\n' "$replacement"
            found=1
        elif [[ "$found" -eq 0 ]] && [[ "$line" = "$note_line" ]]; then
            # Fallback: agent clobbered [~] back to [ ] — match original form
            printf '%s\n' "$replacement"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "HUMAN_NOTES.md" > "$tmpfile"
    mv "$tmpfile" "HUMAN_NOTES.md"

    if [[ "$found" -eq 1 ]]; then
        return 0
    fi
    return 1
}

# extract_note_text — Strips the checkbox prefix from a note line.
# Returns the rest of the line after "- [ ] ", "- [~] ", or "- [x] ".
# Usage: text=$(extract_note_text "- [ ] [BUG] Fix the thing")
#   → "[BUG] Fix the thing"
extract_note_text() {
    local note_line="$1"
    # Strip "- [ ] ", "- [~] ", or "- [x] " prefix using glob ? for the checkbox char
    local text="${note_line#- \[?\] }"
    echo "$text"
}

# count_unchecked_notes — Counts remaining [ ] lines in HUMAN_NOTES.md.
# If tag_filter is set, counts only within the matching section.
# Usage: remaining=$(count_unchecked_notes "BUG")
count_unchecked_notes() {
    local tag_filter="${1:-}"

    if [[ ! -f "HUMAN_NOTES.md" ]]; then
        echo "0"
        return 0
    fi

    if [[ -n "$tag_filter" ]]; then
        local target_section
        target_section=$(_section_for_tag "$tag_filter")
        if [[ -z "$target_section" ]]; then
            echo "0"
            return 0
        fi
        local count
        count=$(awk -v sect="$target_section" '
            BEGIN { in_section = 0; count = 0 }
            $0 == sect { in_section = 1; next }
            in_section && /^## / { exit }
            in_section && /^- \[ \] / { count++ }
            END { print count }
        ' HUMAN_NOTES.md)
        echo "$count"
    else
        local count
        count=$(grep -c '^- \[ \] ' HUMAN_NOTES.md || true)
        echo "${count:-0}"
    fi
    return 0
}
