#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_migrate.sh — Lazy migration for legacy ${HUMAN_NOTES_FILE} files
#
# Sourced by tekhton.sh — do not run directly.
# Expects: notes_core.sh sourced first (_next_note_id, _build_metadata_comment).
# Expects: log(), warn() from common.sh.
#
# Provides:
#   migrate_legacy_notes — Adds IDs and metadata to notes lacking them
# =============================================================================

_NOTES_FORMAT_MARKER="<!-- notes-format: v2 -->"

# _needs_notes_migration — Returns 0 if ${HUMAN_NOTES_FILE} exists and lacks the
# v2 format marker, indicating migration is needed.
_needs_notes_migration() {
    local nf="${_NOTES_FILE:-${HUMAN_NOTES_FILE}}"
    if [[ ! -f "$nf" ]]; then
        return 1
    fi
    # Already migrated?
    if head -5 "$nf" | grep -qF "$_NOTES_FORMAT_MARKER" 2>/dev/null; then
        return 1
    fi
    # Has any notes at all?
    if ! grep -q '^- \[[ x~]\] ' "$nf" 2>/dev/null; then
        return 1
    fi
    return 0
}

# migrate_legacy_notes — Adds IDs to all existing notes idempotently.
# Creates a .v1-backup before modifying. Adds version marker at top.
# Preserves all existing content (descriptions, comments, section headings).
migrate_legacy_notes() {
    local nf="${_NOTES_FILE:-${HUMAN_NOTES_FILE}}"
    if ! _needs_notes_migration; then
        return 0
    fi

    log "Migrating ${HUMAN_NOTES_FILE} to v2 format (adding note IDs)..."

    # Pre-migration backup
    cp "$nf" "${nf}.v1-backup"

    # Find current max ID (in case some notes already have IDs)
    local max_id=0
    local id_num
    while IFS= read -r line; do
        if [[ "$line" =~ \<\!--\ note:n([0-9]+) ]]; then
            id_num=$((10#${BASH_REMATCH[1]}))
            if [[ "$id_num" -gt "$max_id" ]]; then
                max_id="$id_num"
            fi
        fi
    done < "$nf"

    local tmpfile
    tmpfile=$(mktemp)
    local next_id=$(( max_id + 1 ))
    local migrated=0
    local added_marker=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Add format marker after the first heading line
        if [[ "$added_marker" == false ]] && [[ "$line" =~ ^#\  ]]; then
            printf '%s\n' "$line"
            printf '%s\n' "$_NOTES_FORMAT_MARKER"
            printf '%s\n' "<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->"
            added_marker=true
            continue
        fi

        # Only modify note lines that lack an existing ID
        local _note_pat='^- \[[ x~]\] '
        if [[ "$line" =~ $_note_pat ]] && [[ ! "$line" =~ \<\!--\ note: ]]; then
            local nid
            nid=$(printf 'n%02d' "$next_id")
            local created
            created=$(date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
            local meta="<!-- note:${nid} created:${created} priority:medium source:legacy -->"
            printf '%s %s\n' "$line" "$meta"
            next_id=$(( next_id + 1 ))
            migrated=$(( migrated + 1 ))
        else
            printf '%s\n' "$line"
        fi
    done < "$nf" > "$tmpfile"

    # If we never found a heading (unusual), prepend the marker
    if [[ "$added_marker" == false ]]; then
        local tmpfile2
        tmpfile2=$(mktemp)
        { printf '%s\n' "$_NOTES_FORMAT_MARKER"
          printf '%s\n' "<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->"
          cat "$tmpfile"
        } > "$tmpfile2"
        rm "$tmpfile"
        tmpfile="$tmpfile2"
    fi

    mv "$tmpfile" "$nf"
    log "Migrated ${migrated} note(s) to v2 format. Backup: ${nf}.v1-backup"
}

# _ensure_gitignore_inbox — Adds .claude/watchtower_inbox/ to .gitignore if missing.
_ensure_gitignore_inbox() {
    local gitignore="${PROJECT_DIR:-.}/.gitignore"
    local entry=".claude/watchtower_inbox/"

    if [[ -f "$gitignore" ]]; then
        if grep -qF "$entry" "$gitignore" 2>/dev/null; then
            return 0
        fi
        # Ensure newline before appending
        if [[ -s "$gitignore" ]] && [[ "$(tail -c1 "$gitignore" | wc -l)" -eq 0 ]]; then
            printf '\n' >> "$gitignore"
        fi
        printf '%s\n' "$entry" >> "$gitignore"
    fi
}
