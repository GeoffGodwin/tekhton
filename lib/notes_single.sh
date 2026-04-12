#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_single.sh — Single-note utility functions for --human mode
#
# Extracted from notes.sh to stay under the 300-line guideline.
# Sourced by tekhton.sh after notes.sh and notes_core.sh — do not run directly.
# Expects: LOG_DIR, TIMESTAMP from caller
# Operates on "${HUMAN_NOTES_FILE}" in the current directory.
#
# M40: _section_for_tag and _validate_tag now delegate to the tag registry
# in notes_core.sh. pick_next_note uses _NOTE_TAG_PRIORITY for ordering.
# claim_single_note/resolve_single_note preserved for backward compat but
# also support ID-based operation when notes have IDs.
#
# Provides:
#   _escape_sed_pattern    — regex escaping for sed patterns
#   _section_for_tag       — tag-to-section heading mapping (delegates to registry)
#   pick_next_note         — priority-ordered note selection
#   claim_single_note      — mark one note [ ] → [~] (by ID or text)
#   resolve_single_note    — mark one note [~] → [x] or [ ] (by ID or text)
#   extract_note_text      — strip checkbox prefix
#   count_unchecked_notes  — count remaining [ ] notes
# =============================================================================

# _escape_sed_pattern — Escapes regex special characters for safe sed matching.
_escape_sed_pattern() {
    # shellcheck disable=SC2016
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|/&]/\\&/g'
}

# _section_for_tag — Maps a tag filter to the "${HUMAN_NOTES_FILE}" section heading.
# M40: Delegates to the tag registry in notes_core.sh.
_section_for_tag() {
    local tag="${1:-}"
    _section_for_tag_registry "$tag"
}

# pick_next_note — Returns the first unchecked note from "${HUMAN_NOTES_FILE}" in priority
# order determined by _NOTE_TAG_PRIORITY array from the tag registry.
# If tag_filter is set, only scans the corresponding section.
pick_next_note() {
    local tag_filter="${1:-}"

    if [[ ! -f "${HUMAN_NOTES_FILE}" ]]; then
        echo ""
        return 0
    fi

    local sections=()
    if [[ -n "$tag_filter" ]]; then
        local target_section
        target_section=$(_section_for_tag "$tag_filter")
        if [[ -z "$target_section" ]]; then
            echo ""
            return 0
        fi
        sections=("$target_section")
    else
        # Build sections list from registry priority order
        local tag
        for tag in "${_NOTE_TAG_PRIORITY[@]}"; do
            sections+=("${_NOTE_TAG_SECTION[$tag]}")
        done
    fi

    local section
    for section in "${sections[@]}"; do
        local result
        result=$(awk -v sect="$section" '
            BEGIN { in_section = 0 }
            $0 == sect { in_section = 1; next }
            in_section && /^## / { exit }
            in_section && /^- \[ \] / { print; exit }
        ' "${HUMAN_NOTES_FILE}")
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    done

    echo ""
    return 0
}

# claim_single_note — Marks exactly ONE note from [ ] to [~] in "${HUMAN_NOTES_FILE}".
# M40: If the note line has an ID, also registers it in CLAIMED_NOTE_IDS.
# Archives pre-run snapshot before modification.
claim_single_note() {
    local note_line="$1"

    if [[ ! -f "${HUMAN_NOTES_FILE}" ]] || [[ -z "$note_line" ]]; then
        return 1
    fi

    # Archive pre-run snapshot
    if [[ -n "${LOG_DIR:-}" ]] && [[ -n "${TIMESTAMP:-}" ]] && [[ -d "${LOG_DIR:-}" ]]; then
        cp "${HUMAN_NOTES_FILE}" "${LOG_DIR}/${TIMESTAMP}_$(basename "${HUMAN_NOTES_FILE}")"
    else
        cp "${HUMAN_NOTES_FILE}" "${HUMAN_NOTES_FILE}.bak"
    fi

    # Extract ID if present for CLAIMED_NOTE_IDS tracking
    local nid=""
    nid=$(_extract_note_id "$note_line")

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
    done < "${HUMAN_NOTES_FILE}" > "$tmpfile"
    mv "$tmpfile" "${HUMAN_NOTES_FILE}"

    if [[ "$found" -eq 1 ]]; then
        # Track claimed ID for batch resolution
        if [[ -n "$nid" ]]; then
            CLAIMED_NOTE_IDS="${CLAIMED_NOTE_IDS:+${CLAIMED_NOTE_IDS} }${nid}"
        fi
        return 0
    fi
    return 1
}

# resolve_single_note — Resolves a single in-progress note.
# If exit_code=0: [~] → [x]. If non-zero: [~] → [ ].
# M40: If the note has an ID, uses ID-based matching as primary path.
# Falls back to text matching for legacy notes.
resolve_single_note() {
    local note_line="$1"
    local exit_code="${2:-1}"

    if [[ ! -f "${HUMAN_NOTES_FILE}" ]] || [[ -z "$note_line" ]]; then
        return 1
    fi

    # Try ID-based resolution first
    local nid=""
    nid=$(_extract_note_id "$note_line")
    if [[ -n "$nid" ]]; then
        local outcome="reset"
        if [[ "$exit_code" -eq 0 ]]; then
            outcome="complete"
        fi
        if resolve_note "$nid" "$outcome"; then
            return 0
        fi
        # Fall through to text matching if ID-based failed
    fi

    # Text-based fallback for legacy notes
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
            printf '%s\n' "$replacement"
            found=1
        elif [[ "$found" -eq 0 ]] && [[ "$line" = "$note_line" ]]; then
            printf '%s\n' "$replacement"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "${HUMAN_NOTES_FILE}" > "$tmpfile"
    mv "$tmpfile" "${HUMAN_NOTES_FILE}"

    if [[ "$found" -eq 1 ]]; then
        return 0
    fi
    return 1
}

# extract_note_text — Strips the checkbox prefix from a note line.
# Returns the rest of the line after "- [ ] ", "- [~] ", or "- [x] ".
# M40: Also strips trailing HTML comment metadata.
extract_note_text() {
    local note_line="$1"
    local text="${note_line#- \[?\] }"
    # Strip trailing metadata comment
    text="${text%% <!-- note:*}"
    echo "$text"
}

# count_unchecked_notes — Counts remaining [ ] lines in "${HUMAN_NOTES_FILE}".
# If tag_filter is set, counts only within the matching section.
count_unchecked_notes() {
    local tag_filter="${1:-}"

    if [[ ! -f "${HUMAN_NOTES_FILE}" ]]; then
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
        ' "${HUMAN_NOTES_FILE}")
        echo "$count"
    else
        local count
        count=$(grep -c '^- \[ \] ' "${HUMAN_NOTES_FILE}" || true)
        echo "${count:-0}"
    fi
    return 0
}
