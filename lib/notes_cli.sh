#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_cli.sh — CLI note management commands for HUMAN_NOTES.md
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh sourced first (log, success, warn, error, color codes)
# Operates on HUMAN_NOTES.md in the current directory (PROJECT_DIR).
#
# Provides:
#   add_human_note       — append a formatted note entry
#   list_human_notes_cli — display unchecked notes, color-coded by tag
#   complete_human_note  — mark a note as done by line number or text match
#   clear_completed_notes — remove all checked items with confirmation
#   get_notes_summary    — return structured count for use by other modules
# =============================================================================

# --- Constants ---------------------------------------------------------------

_NOTES_FILE="HUMAN_NOTES.md"
_VALID_TAGS="BUG FEAT POLISH"

# --- Helpers -----------------------------------------------------------------

# _ensure_notes_file — Creates HUMAN_NOTES.md with standard header if missing.
_ensure_notes_file() {
    if [[ -f "$_NOTES_FILE" ]]; then
        return 0
    fi

    local project_name="${PROJECT_NAME:-$(basename "${PROJECT_DIR:-.}")}"
    cat > "$_NOTES_FILE" << EOF
# Human Notes — ${project_name}

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use \`- [ ]\` for new notes. Use \`- [x]\` to mark items you want to defer/skip.
Tag with [BUG], [FEAT], or [POLISH] to use --notes-filter.

## Bugs
<!-- - [ ] [BUG] Example: describe a bug you found -->

## Features
<!-- - [ ] [FEAT] Example: describe a feature request -->

## Polish
<!-- - [ ] [POLISH] Example: describe a UX improvement -->
EOF
}

# _tag_to_section — Maps a tag to its HUMAN_NOTES.md section heading.
_tag_to_section() {
    case "$1" in
        BUG)    echo "## Bugs" ;;
        FEAT)   echo "## Features" ;;
        POLISH) echo "## Polish" ;;
    esac
}

# _validate_tag — Returns 0 if tag is valid, 1 otherwise.
_validate_tag() {
    local tag="$1"
    case "$tag" in
        BUG|FEAT|POLISH) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Public Functions --------------------------------------------------------

# add_human_note TEXT [TAG]
# Appends a properly formatted entry to HUMAN_NOTES.md.
# TAG defaults to FEAT if omitted. Creates the file if it doesn't exist.
add_human_note() {
    local text="$1"
    local tag="${2:-FEAT}"

    if [[ -z "$text" ]]; then
        error "Note text is required."
        return 1
    fi

    # Validate tag
    if ! _validate_tag "$tag"; then
        error "Invalid tag: '${tag}'. Must be one of: ${_VALID_TAGS}"
        return 1
    fi

    _ensure_notes_file

    local section_heading
    section_heading=$(_tag_to_section "$tag")
    local entry="- [ ] [${tag}] ${text}"

    # Insert the entry just before the next section heading after the target section.
    # If no next section, append at end of file.
    local tmpfile
    tmpfile=$(mktemp)
    local found_section=false
    local inserted=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found_section" = true ]] && [[ "$inserted" = false ]]; then
            if [[ "$line" =~ ^## ]]; then
                # Hit next section — insert entry before it
                printf '%s\n' "$entry"
                inserted=true
            fi
        fi
        printf '%s\n' "$line"
        if [[ "$inserted" = false ]] && [[ "$line" = "$section_heading" ]]; then
            found_section=true
        fi
    done < "$_NOTES_FILE" > "$tmpfile"

    # If section was found but no next section (end of file), append
    if [[ "$found_section" = true ]] && [[ "$inserted" = false ]]; then
        printf '%s\n' "$entry" >> "$tmpfile"
    fi

    mv "$tmpfile" "$_NOTES_FILE"
    success "Added [${tag}] note: ${text}"
}

# list_human_notes_cli [TAG_FILTER]
# Prints all unchecked notes, optionally filtered by tag.
# Color-coded by tag: BUG=red, FEAT=cyan, POLISH=yellow.
list_human_notes_cli() {
    local filter="${1:-}"

    if [[ ! -f "$_NOTES_FILE" ]]; then
        log "No HUMAN_NOTES.md found. Create notes with: tekhton note \"description\""
        return 0
    fi

    # Validate filter if provided
    if [[ -n "$filter" ]] && ! _validate_tag "$filter"; then
        error "Invalid tag filter: '${filter}'. Must be one of: ${_VALID_TAGS}"
        return 1
    fi

    local bug_count=0
    local feat_count=0
    local polish_count=0
    local total=0

    while IFS= read -r line; do
        [[ ! "$line" =~ ^-\ \[\ \]\  ]] && continue

        local tag=""
        if [[ "$line" =~ \[BUG\] ]]; then
            tag="BUG"
        elif [[ "$line" =~ \[FEAT\] ]]; then
            tag="FEAT"
        elif [[ "$line" =~ \[POLISH\] ]]; then
            tag="POLISH"
        fi

        # Apply filter
        if [[ -n "$filter" ]] && [[ "$tag" != "$filter" ]]; then
            continue
        fi

        total=$((total + 1))
        case "$tag" in
            BUG)
                bug_count=$((bug_count + 1))
                printf '  %s%s%s\n' "${RED}" "$line" "${NC}"
                ;;
            FEAT)
                feat_count=$((feat_count + 1))
                printf '  %s%s%s\n' "${CYAN}" "$line" "${NC}"
                ;;
            POLISH)
                polish_count=$((polish_count + 1))
                printf '  %s%s%s\n' "${YELLOW}" "$line" "${NC}"
                ;;
            *)
                printf '  %s\n' "$line"
                ;;
        esac
    done < "$_NOTES_FILE"

    if [[ "$total" -eq 0 ]]; then
        if [[ -n "$filter" ]]; then
            log "No unchecked [${filter}] notes."
        else
            log "No unchecked notes."
        fi
        return 0
    fi

    # Build count summary
    local parts=()
    if [[ "$bug_count" -gt 0 ]]; then parts+=("${bug_count} BUG"); fi
    if [[ "$feat_count" -gt 0 ]]; then parts+=("${feat_count} FEAT"); fi
    if [[ "$polish_count" -gt 0 ]]; then parts+=("${polish_count} POLISH"); fi

    local summary=""
    if [[ ${#parts[@]} -gt 0 ]]; then
        summary=" ($(IFS=', '; echo "${parts[*]}"))"
    fi

    printf '%s%s note(s)%s%s\n' "${BOLD}" "$total" "$summary" "${NC}"
}

# --- Completion and summary helpers live in notes_cli_write.sh ----------------
