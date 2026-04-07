#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_core.sh — Note ID system, tag registry, and unified claim/resolve API
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh sourced first (log, warn, error, success, color codes).
# Expects: _NOTES_FILE from notes_cli.sh (or defaults to HUMAN_NOTES.md).
#
# Provides:
#   Tag registry:  _NOTE_TAG_SECTION, _NOTE_TAG_COLOR, _NOTE_TAG_PRIORITY
#   ID system:     _next_note_id, _find_note_by_id, _parse_note_metadata,
#                  _set_note_metadata
#   Claim/resolve: claim_note, resolve_note, claim_notes_batch,
#                  resolve_notes_batch
#   Rollback:      (moved to notes_rollback.sh)
# =============================================================================

# --- Tag Registry -----------------------------------------------------------

declare -A _NOTE_TAG_SECTION=(
    [BUG]="## Bugs"
    [FEAT]="## Features"
    [POLISH]="## Polish"
)

declare -A _NOTE_TAG_COLOR=(
    [BUG]="${RED:-}"
    [FEAT]="${CYAN:-}"
    [POLISH]="${YELLOW:-}"
)

declare -a _NOTE_TAG_PRIORITY=( BUG FEAT POLISH )

# _validate_tag_registry TAG — Returns 0 if tag is in the registry, 1 otherwise.
_validate_tag_registry() {
    local tag="$1"
    [[ -n "${_NOTE_TAG_SECTION[$tag]+_}" ]]
}

# _section_for_tag_registry TAG — Maps a tag to its section heading via registry.
_section_for_tag_registry() {
    local tag="${1:-}"
    if [[ -n "${_NOTE_TAG_SECTION[$tag]+_}" ]]; then
        echo "${_NOTE_TAG_SECTION[$tag]}"
    else
        echo ""
    fi
}

# _color_for_tag TAG — Returns color code for a tag.
_color_for_tag() {
    local tag="${1:-}"
    if [[ -n "${_NOTE_TAG_COLOR[$tag]+_}" ]]; then
        echo "${_NOTE_TAG_COLOR[$tag]}"
    else
        echo ""
    fi
}

# _valid_tags_string — Returns space-separated list of valid tags.
_valid_tags_string() {
    echo "${_NOTE_TAG_PRIORITY[*]}"
}

# --- Note ID System ---------------------------------------------------------

# _notes_file — Returns the notes file path.
_notes_file() {
    echo "${_NOTES_FILE:-HUMAN_NOTES.md}"
}

# _next_note_id — Scan HUMAN_NOTES.md for highest existing ID, return next.
# IDs are format nNN (n01, n02, ..., n99, n100, ...). Monotonic, never reused.
_next_note_id() {
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]]; then
        echo "n01"
        return 0
    fi

    local max_id=0
    local id_num
    while IFS= read -r line; do
        if [[ "$line" =~ \<\!--\ note:n([0-9]+) ]]; then
            id_num="${BASH_REMATCH[1]}"
            # Strip leading zeros for arithmetic
            id_num=$((10#$id_num))
            if [[ "$id_num" -gt "$max_id" ]]; then
                max_id="$id_num"
            fi
        fi
    done < "$nf"

    local next=$(( max_id + 1 ))
    printf 'n%02d\n' "$next"
}

# _find_note_by_id ID — Return the full line for a note by its ID.
# Returns empty string if not found.
_find_note_by_id() {
    local id="$1"
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]]; then
        echo ""
        return 0
    fi

    grep -m1 "<!-- note:${id} " "$nf" 2>/dev/null || echo ""
}

# _parse_note_metadata LINE — Extract metadata fields from a note line.
# Sets global vars: _NM_ID, _NM_CREATED, _NM_PRIORITY, _NM_SOURCE, _NM_TRIAGE
_parse_note_metadata() {
    local line="$1"
    _NM_ID="" _NM_CREATED="" _NM_PRIORITY="" _NM_SOURCE="" _NM_TRIAGE=""

    if [[ "$line" =~ \<\!--\ note:([^ ]+) ]]; then
        _NM_ID="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ created:([^ ]+) ]]; then
        _NM_CREATED="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ priority:([^ ]+) ]]; then
        _NM_PRIORITY="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ source:([^ ]+) ]]; then
        _NM_SOURCE="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ triage:([^ ]+) ]]; then
        _NM_TRIAGE="${BASH_REMATCH[1]}"
    fi
}

# _set_note_metadata ID KEY VALUE — Update a single metadata field in-place.
_set_note_metadata() {
    local id="$1" key="$2" value="$3"
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]]; then
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" =~ \<\!--\ note:${id}\  ]]; then
            found=1
            local _key_pat="${key}:[^ ]+"
            if [[ "$line" =~ $_key_pat ]]; then
                # Replace existing key
                # BASH_REMATCH[0] holds the full match e.g. "priority:high"
                line="${line/${BASH_REMATCH[0]}/${key}:${value}}"
            else
                # Insert before closing -->
                line="${line/ -->/ ${key}:${value} -->}"
            fi
        fi
        printf '%s\n' "$line"
    done < "$nf" > "$tmpfile"
    mv "$tmpfile" "$nf"
    return 0
}

# _extract_note_id LINE — Extract just the note ID from a line.
_extract_note_id() {
    local line="$1"
    if [[ "$line" =~ \<\!--\ note:([^ ]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# _build_metadata_comment ID [PRIORITY] [SOURCE] [INBOX_FILE]
# Builds the HTML comment metadata string for a note.
_build_metadata_comment() {
    local id="$1"
    local priority="${2:-medium}"
    local source="${3:-cli}"
    local inbox_file="${4:-}"
    local created
    created=$(date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    local meta="<!-- note:${id} created:${created} priority:${priority} source:${source}"
    if [[ -n "$inbox_file" ]]; then
        meta="${meta} inbox_file:${inbox_file}"
    fi
    meta="${meta} -->"
    echo "$meta"
}

# --- Unified Claim/Resolve API -----------------------------------------------

# CLAIMED_NOTE_IDS — Tracks IDs claimed during this run.
# Set by claim_note/claim_notes_batch, read by resolve hooks.
CLAIMED_NOTE_IDS=""

# claim_note ID — Mark a single note [ ] -> [~] by ID.
# Falls back to text matching for legacy notes without IDs.
# Returns 0 on success, 1 if note not found.
claim_note() {
    local id="$1"
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]] || [[ -z "$id" ]]; then
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" =~ ^-\ \[\ \] ]] \
           && [[ "$line" =~ \<\!--\ note:${id}\  ]]; then
            printf '%s\n' "${line/\[ \]/[~]}"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$nf" > "$tmpfile"
    mv "$tmpfile" "$nf"

    if [[ "$found" -eq 1 ]]; then
        CLAIMED_NOTE_IDS="${CLAIMED_NOTE_IDS:+${CLAIMED_NOTE_IDS} }${id}"
        return 0
    fi
    return 1
}

# resolve_note ID OUTCOME — Resolve a single note by ID.
# OUTCOME: "complete" -> [~] -> [x], "reset" -> [~] -> [ ]
# Falls back to matching [~] notes with this ID.
resolve_note() {
    local id="$1"
    local outcome="${2:-reset}"
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]] || [[ -z "$id" ]]; then
        return 1
    fi

    local new_marker
    if [[ "$outcome" == "complete" ]]; then
        new_marker="[x]"
    else
        new_marker="[ ]"
    fi

    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" =~ ^-\ \[~\] ]] \
           && [[ "$line" =~ \<\!--\ note:${id}\  ]]; then
            printf '%s\n' "${line/\[~\]/${new_marker}}"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$nf" > "$tmpfile"
    mv "$tmpfile" "$nf"

    [[ "$found" -eq 1 ]]
}

# claim_notes_batch [FILTER] — Claim all matching unchecked notes.
# FILTER: tag filter (e.g. "BUG") or empty for all.
# Returns space-separated list of claimed IDs on stdout.
# Also archives pre-run snapshot.
claim_notes_batch() {
    local filter="${1:-}"
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]]; then
        echo ""
        return 0
    fi

    # Archive pre-run snapshot
    if [[ -n "${LOG_DIR:-}" ]] && [[ -n "${TIMESTAMP:-}" ]] && [[ -d "${LOG_DIR:-}" ]]; then
        cp "$nf" "${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md"
    fi

    local claimed_ids=""
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^-\ \[\ \] ]]; then
            local should_claim=true
            if [[ -n "$filter" ]] && [[ ! "$line" =~ \[${filter}\] ]]; then
                should_claim=false
            fi
            if [[ "$should_claim" == true ]]; then
                local nid
                nid=$(_extract_note_id "$line")
                if [[ -n "$nid" ]]; then
                    claimed_ids="${claimed_ids:+${claimed_ids} }${nid}"
                    CLAIMED_NOTE_IDS="${CLAIMED_NOTE_IDS:+${CLAIMED_NOTE_IDS} }${nid}"
                fi
                printf '%s\n' "${line/\[ \]/[~]}"
                continue
            fi
        fi
        printf '%s\n' "$line"
    done < "$nf" > "$tmpfile"
    mv "$tmpfile" "$nf"

    echo "$claimed_ids"
}

# resolve_notes_batch IDS EXIT_CODE — Resolve a list of IDs based on exit code.
# EXIT_CODE 0 -> complete, non-zero -> reset.
resolve_notes_batch() {
    local ids="$1"
    local exit_code="${2:-1}"
    local outcome="reset"
    if [[ "$exit_code" -eq 0 ]]; then
        outcome="complete"
    fi

    local id
    for id in $ids; do
        resolve_note "$id" "$outcome" || true
    done
}

# --- Rollback Support --------------------------------------------------------
# Extracted to lib/notes_rollback.sh (sourced separately by tekhton.sh).
# Functions: snapshot_note_states, restore_note_states
