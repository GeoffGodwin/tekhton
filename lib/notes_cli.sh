#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_cli.sh — CLI note management commands for HUMAN_NOTES.md
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh sourced first (log, success, warn, error, color codes)
# Expects: notes_core.sh sourced first (tag registry, ID functions)
# Operates on HUMAN_NOTES.md in the current directory (PROJECT_DIR).
#
# M40: Tag validation and section mapping now use the registry from notes_core.sh.
# add_human_note auto-assigns note IDs and accepts optional metadata params.
#
# Provides:
#   add_human_note       — append a formatted note entry with ID
#   list_human_notes_cli — display unchecked notes, color-coded by tag
# =============================================================================

# --- Constants ---------------------------------------------------------------

_NOTES_FILE="HUMAN_NOTES.md"

# --- Helpers -----------------------------------------------------------------

# _ensure_notes_file — Creates HUMAN_NOTES.md with standard header if missing.
# M40: Uses tag registry to generate section headings.
_ensure_notes_file() {
    if [[ -f "$_NOTES_FILE" ]]; then
        return 0
    fi

    local project_name="${PROJECT_NAME:-$(basename "${PROJECT_DIR:-.}")}"
    {
        printf '# Human Notes — %s\n' "$project_name"
        printf '%s\n' "<!-- notes-format: v2 -->"
        printf '%s\n' "<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->"
        printf '\n'
        printf '%s\n' "Add your observations below as unchecked items. The pipeline will inject"
        printf '%s\n' "unchecked items into the next coder run and archive them when done."
        printf '\n'
        # shellcheck disable=SC2016
        printf '%s\n' 'Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.'
        printf '%s\n' "Tag with [BUG], [FEAT], or [POLISH] to use --notes-filter."
        printf '\n'
        # Generate section headings from registry
        local tag
        for tag in "${_NOTE_TAG_PRIORITY[@]}"; do
            local section="${_NOTE_TAG_SECTION[$tag]}"
            printf '%s\n' "$section"
            printf '<!-- - [ ] [%s] Example: describe a %s -->\n' "$tag" "$(echo "$tag" | tr '[:upper:]' '[:lower:]')"
            printf '\n'
        done
    } > "$_NOTES_FILE"
}

# _tag_to_section — Maps a tag to its HUMAN_NOTES.md section heading.
# M40: Delegates to the registry.
_tag_to_section() {
    _section_for_tag_registry "$1"
}

# _validate_tag — Returns 0 if tag is valid, 1 otherwise.
# M40: Delegates to the registry.
_validate_tag() {
    _validate_tag_registry "$1"
}

# --- Public Functions --------------------------------------------------------

# add_human_note TEXT [TAG] [PRIORITY] [SOURCE] [DESCRIPTION] [INBOX_FILE]
# Appends a properly formatted entry with auto-assigned ID to HUMAN_NOTES.md.
# TAG defaults to FEAT if omitted. Creates the file if it doesn't exist.
add_human_note() {
    local text="$1"
    local tag="${2:-FEAT}"
    local priority="${3:-medium}"
    local source="${4:-cli}"
    local description="${5:-}"
    local inbox_file="${6:-}"

    if [[ -z "$text" ]]; then
        error "Note text is required."
        return 1
    fi

    # Validate tag
    if ! _validate_tag "$tag"; then
        error "Invalid tag: '${tag}'. Must be one of: $(_valid_tags_string)"
        return 1
    fi

    _ensure_notes_file

    # Check for duplicate (same tag + title, case-insensitive)
    local lower_text
    lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r line; do
        local _dup_pat="^- \[[ x~]\] \[${tag}\]"
        if [[ "$line" =~ $_dup_pat ]]; then
            # Extract title (between tag and metadata comment)
            local existing_title="${line#*\] }"       # after checkbox+tag
            existing_title="${existing_title#*\] }"    # after second bracket
            existing_title="${existing_title%% <!-- note:*}"  # strip metadata
            local lower_existing
            lower_existing=$(echo "$existing_title" | tr '[:upper:]' '[:lower:]')
            if [[ "$lower_existing" == "$lower_text" ]]; then
                warn "Duplicate note detected — [${tag}] ${text} already exists. Skipping."
                return 0
            fi
        fi
    done < "$_NOTES_FILE"

    local nid
    nid=$(_next_note_id)
    local meta
    meta=$(_build_metadata_comment "$nid" "$priority" "$source" "$inbox_file")
    local entry="- [ ] [${tag}] ${text} ${meta}"

    local section_heading
    section_heading=$(_tag_to_section "$tag")

    # Insert the entry just before the next section heading after the target section.
    local tmpfile
    tmpfile=$(mktemp)
    local found_section=false
    local inserted=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found_section" = true ]] && [[ "$inserted" = false ]]; then
            if [[ "$line" =~ ^## ]]; then
                # Hit next section — insert entry before it
                printf '%s\n' "$entry"
                # Add description block if provided
                if [[ -n "$description" ]]; then
                    printf '  > %s\n' "$description"
                fi
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
        if [[ -n "$description" ]]; then
            printf '  > %s\n' "$description" >> "$tmpfile"
        fi
    fi

    mv "$tmpfile" "$_NOTES_FILE"
    success "Added [${tag}] note (${nid}): ${text}"
}

# list_human_notes_cli [TAG_FILTER]
# Prints all unchecked notes, optionally filtered by tag.
# Color-coded by tag using the registry.
list_human_notes_cli() {
    local filter="${1:-}"

    if [[ ! -f "$_NOTES_FILE" ]]; then
        log "No HUMAN_NOTES.md found. Create notes with: tekhton note \"description\""
        return 0
    fi

    # Validate filter if provided
    if [[ -n "$filter" ]] && ! _validate_tag "$filter"; then
        error "Invalid tag filter: '${filter}'. Must be one of: $(_valid_tags_string)"
        return 1
    fi

    local total=0
    declare -A tag_counts=()
    local tag
    for tag in "${_NOTE_TAG_PRIORITY[@]}"; do
        tag_counts[$tag]=0
    done

    while IFS= read -r line; do
        [[ ! "$line" =~ ^-\ \[\ \]\  ]] && continue

        local detected_tag=""
        for tag in "${_NOTE_TAG_PRIORITY[@]}"; do
            if [[ "$line" =~ \[${tag}\] ]]; then
                detected_tag="$tag"
                break
            fi
        done

        # Apply filter
        if [[ -n "$filter" ]] && [[ "$detected_tag" != "$filter" ]]; then
            continue
        fi

        total=$((total + 1))
        if [[ -n "$detected_tag" ]]; then
            tag_counts[$detected_tag]=$(( ${tag_counts[$detected_tag]} + 1 ))
            local color
            color=$(_color_for_tag "$detected_tag")
            printf '  %s%s%s\n' "$color" "$line" "${NC}"
        else
            printf '  %s\n' "$line"
        fi
    done < "$_NOTES_FILE"

    if [[ "$total" -eq 0 ]]; then
        if [[ -n "$filter" ]]; then
            log "No unchecked [${filter}] notes."
        else
            log "No unchecked notes."
        fi
        return 0
    fi

    # Build count summary from registry order
    local parts=()
    for tag in "${_NOTE_TAG_PRIORITY[@]}"; do
        if [[ "${tag_counts[$tag]}" -gt 0 ]]; then
            parts+=("${tag_counts[$tag]} ${tag}")
        fi
    done

    local summary=""
    if [[ ${#parts[@]} -gt 0 ]]; then
        summary=" ($(IFS=', '; echo "${parts[*]}"))"
    fi

    printf '%s%s note(s)%s%s\n' "${BOLD}" "$total" "$summary" "${NC}"
}

# --- Completion and summary helpers live in notes_cli_write.sh ----------------
