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
    local output=""

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
                output+="  ${RED}${line}${NC}\n"
                ;;
            FEAT)
                feat_count=$((feat_count + 1))
                output+="  ${CYAN}${line}${NC}\n"
                ;;
            POLISH)
                polish_count=$((polish_count + 1))
                output+="  ${YELLOW}${line}${NC}\n"
                ;;
            *)
                output+="  ${line}\n"
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

    echo -e "$output"

    # Build count summary
    local parts=()
    if [[ "$bug_count" -gt 0 ]]; then parts+=("${bug_count} BUG"); fi
    if [[ "$feat_count" -gt 0 ]]; then parts+=("${feat_count} FEAT"); fi
    if [[ "$polish_count" -gt 0 ]]; then parts+=("${polish_count} POLISH"); fi

    local summary=""
    if [[ ${#parts[@]} -gt 0 ]]; then
        summary=" ($(IFS=', '; echo "${parts[*]}"))"
    fi

    echo -e "${BOLD}${total} note(s)${summary}${NC}"
}

# complete_human_note NUMBER_OR_TEXT
# Marks a note as checked (done). Accepts a line number (of unchecked notes)
# or a text substring match.
complete_human_note() {
    local target="$1"

    if [[ -z "$target" ]]; then
        error "Specify a note number or text to complete."
        return 1
    fi

    if [[ ! -f "$_NOTES_FILE" ]]; then
        error "No HUMAN_NOTES.md found."
        return 1
    fi

    # Check if target is a number
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        _complete_by_number "$target"
    else
        _complete_by_text "$target"
    fi
}

# _complete_by_number N — Mark the Nth unchecked note as done.
_complete_by_number() {
    local num="$1"
    local count=0
    local target_line=""

    while IFS= read -r line; do
        [[ ! "$line" =~ ^-\ \[\ \]\  ]] && continue
        count=$((count + 1))
        if [[ "$count" -eq "$num" ]]; then
            target_line="$line"
            break
        fi
    done < "$_NOTES_FILE"

    if [[ -z "$target_line" ]]; then
        error "Note #${num} not found. Only ${count} unchecked note(s) exist."
        return 1
    fi

    _mark_note_done "$target_line"
}

# _complete_by_text TEXT — Find and complete a note by case-insensitive substring.
_complete_by_text() {
    local search="$1"
    local matches=()

    while IFS= read -r line; do
        [[ ! "$line" =~ ^-\ \[\ \]\  ]] && continue
        # Case-insensitive substring match
        local lower_line lower_search
        lower_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        lower_search=$(echo "$search" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_line" == *"$lower_search"* ]]; then
            matches+=("$line")
        fi
    done < "$_NOTES_FILE"

    if [[ ${#matches[@]} -eq 0 ]]; then
        error "No unchecked note matching '${search}'."
        return 1
    fi

    if [[ ${#matches[@]} -gt 1 ]]; then
        warn "Multiple notes match '${search}':"
        local i=1
        for match in "${matches[@]}"; do
            echo "  ${i}. ${match}"
            i=$((i + 1))
        done
        error "Please be more specific or use a note number."
        return 1
    fi

    _mark_note_done "${matches[0]}"
}

# _mark_note_done LINE — Replace the first occurrence of LINE with [x] version.
_mark_note_done() {
    local note_line="$1"
    local done_line="${note_line/\[ \]/[x]}"

    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" = "$note_line" ]]; then
            printf '%s\n' "$done_line"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$_NOTES_FILE" > "$tmpfile"
    mv "$tmpfile" "$_NOTES_FILE"

    if [[ "$found" -eq 1 ]]; then
        # Extract tag and text for display
        local display="${note_line#- \[ \] }"
        success "Completed: ${display}"
    else
        error "Failed to mark note as done."
        return 1
    fi
}

# clear_completed_notes
# Removes all checked items from HUMAN_NOTES.md. Requires confirmation.
clear_completed_notes() {
    if [[ ! -f "$_NOTES_FILE" ]]; then
        log "No HUMAN_NOTES.md found."
        return 0
    fi

    local checked_count
    checked_count=$(grep -c '^- \[x\] ' "$_NOTES_FILE" || true)

    if [[ "$checked_count" -eq 0 ]]; then
        log "No completed notes to clear."
        return 0
    fi

    # Safety: count unchecked before
    local unchecked_before
    unchecked_before=$(grep -c '^- \[ \] ' "$_NOTES_FILE" || true)

    echo -e "${YELLOW}Remove ${checked_count} completed note(s)?${NC} [y/N] "
    read -r confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        log "Cancelled."
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp)
    grep -v '^- \[x\] ' "$_NOTES_FILE" > "$tmpfile"
    mv "$tmpfile" "$_NOTES_FILE"

    # Safety: verify unchecked count unchanged
    local unchecked_after
    unchecked_after=$(grep -c '^- \[ \] ' "$_NOTES_FILE" || true)
    if [[ "$unchecked_after" -ne "$unchecked_before" ]]; then
        warn "Unchecked note count changed unexpectedly (${unchecked_before} → ${unchecked_after})"
    fi

    success "Removed ${checked_count} completed note(s)."
}

# get_notes_summary
# Returns a structured summary: total|bug|feat|polish|checked|unchecked
# Usage: local summary; summary=$(get_notes_summary)
#        IFS='|' read -r total bug feat polish checked unchecked <<< "$summary"
get_notes_summary() {
    if [[ ! -f "$_NOTES_FILE" ]]; then
        echo "0|0|0|0|0|0"
        return 0
    fi

    local bug=0 feat=0 polish=0 checked=0 unchecked=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^-\ \[x\]\  ]]; then
            checked=$((checked + 1))
        elif [[ "$line" =~ ^-\ \[\ \]\  ]]; then
            unchecked=$((unchecked + 1))
            if [[ "$line" =~ \[BUG\] ]]; then
                bug=$((bug + 1))
            elif [[ "$line" =~ \[FEAT\] ]]; then
                feat=$((feat + 1))
            elif [[ "$line" =~ \[POLISH\] ]]; then
                polish=$((polish + 1))
            fi
        fi
    done < "$_NOTES_FILE"

    local total=$((checked + unchecked))
    echo "${total}|${bug}|${feat}|${polish}|${checked}|${unchecked}"
}
