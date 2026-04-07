#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_cli_write.sh — Note completion and summary helpers
#
# Sourced by tekhton.sh — do not run directly.
# Extracted from notes_cli.sh to keep it under the 300-line ceiling.
# Depends on: common.sh (error, warn, success, log, color codes),
#             notes_cli.sh (_NOTES_FILE)
# Provides: complete_human_note(), clear_completed_notes(), get_notes_summary()
# =============================================================================

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

    printf '%b' "${YELLOW}Remove ${checked_count} completed note(s)?${NC} [y/N] "
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
