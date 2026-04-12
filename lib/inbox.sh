#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# inbox.sh — Watchtower inbox processing for pipeline startup
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh, notes_core.sh, notes_cli.sh, milestone_dag.sh sourced first.
# Expects: PROJECT_DIR, MILESTONE_DIR, MILESTONE_MANIFEST from config.
#
# M40: _process_note now extracts description, priority, and source from inbox
# files and passes them to add_human_note. Duplicate detection is built in.
# drain_pending_inbox added for pre-commit inbox processing.
#
# Processes files from .claude/watchtower_inbox/ at pipeline startup:
#   - note_*.md   → appended to ${HUMAN_NOTES_FILE} via add_human_note()
#   - manifest_append_*.cfg → validated and appended to MANIFEST.cfg
#   - milestone_*.md → moved to MILESTONE_DIR
#   - task_*.txt  → surfaced to user (not auto-executed)
#
# Processed items are moved to .claude/watchtower_inbox/processed/.
#
# Provides:
#   process_watchtower_inbox  — main entry point, called at pipeline startup
#   drain_pending_inbox       — lightweight drain before commit (M40)
# =============================================================================

# --- Constants ---------------------------------------------------------------

_INBOX_DIR_NAME="watchtower_inbox"
# Common mis-creation: hyphenated variant (the note marker <!-- watchtower-note -->
# uses hyphens, so users naturally create the directory with hyphens too).
_INBOX_DIR_NAME_ALT="watchtower-inbox"

# --- Internal helpers --------------------------------------------------------

# _inbox_dir
# Returns the inbox directory path.
_inbox_dir() {
    echo "${PROJECT_DIR:-.}/.claude/${_INBOX_DIR_NAME}"
}

# _migrate_hyphenated_inbox
# If .claude/watchtower-inbox/ exists (common mis-creation due to the
# <!-- watchtower-note --> marker using hyphens), move its contents into
# the canonical .claude/watchtower_inbox/ directory.
_migrate_hyphenated_inbox() {
    local alt_dir="${PROJECT_DIR:-.}/.claude/${_INBOX_DIR_NAME_ALT}"
    local canon_dir
    canon_dir="$(_inbox_dir)"

    [[ -d "$alt_dir" ]] || return 0

    mkdir -p "$canon_dir" 2>/dev/null || true

    # Move any files from the hyphenated dir into the canonical dir
    local moved=0
    local f
    for f in "${alt_dir}"/*; do
        [[ -e "$f" ]] || continue
        local base
        base=$(basename "$f")
        # Skip if same-named file already exists in canonical dir
        if [[ -e "${canon_dir}/${base}" ]]; then
            warn "Inbox: skipping duplicate '${base}' during inbox directory migration"
            continue
        fi
        mv "$f" "${canon_dir}/${base}"
        moved=$((moved + 1))
    done

    # Remove the hyphenated directory if now empty (including processed/ subdir)
    rmdir "${alt_dir}/processed" 2>/dev/null || true
    rmdir "$alt_dir" 2>/dev/null || true

    if [[ "$moved" -gt 0 ]]; then
        log "Inbox: migrated ${moved} file(s) from watchtower-inbox/ to watchtower_inbox/"
    fi
}

# _processed_dir
# Returns the processed subdirectory path, creating it if needed.
_processed_dir() {
    local dir
    dir="$(_inbox_dir)/processed"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

# _process_note FILE [INBOX_BASENAME]
# Reads a note file from the inbox and appends it to ${HUMAN_NOTES_FILE}.
# M40: Extracts full watchtower note structure (title, description, priority,
# timestamp, source) and passes them to add_human_note with metadata.
_process_note() {
    local file="$1"
    local inbox_basename="${2:-}"
    local tag="" title="" description="" priority="medium" source="watchtower"
    local line in_description=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^-\ \[\ \]\ \[([A-Z]+)\]\ (.+)$ ]]; then
            tag="${BASH_REMATCH[1]}"
            title="${BASH_REMATCH[2]}"
            in_description=true
            continue
        fi
        # Extract priority from metadata line
        if [[ "$line" =~ ^priority:\ *(.+)$ ]]; then
            priority="${BASH_REMATCH[1]}"
            continue
        fi
        # Extract source from metadata line
        if [[ "$line" =~ ^source:\ *(.+)$ ]]; then
            source="${BASH_REMATCH[1]}"
            continue
        fi
        # Collect description lines (indented or > prefixed)
        if [[ "$in_description" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*\> ]] || [[ "$line" =~ ^[[:space:]]{2,} ]]; then
                local desc_text="${line#*> }"
                desc_text="${desc_text#  }"  # strip 2-space indent
                if [[ -n "$description" ]]; then
                    description="${description} ${desc_text}"
                else
                    description="$desc_text"
                fi
            fi
        fi
    done < "$file"

    if [[ -z "$title" ]]; then
        warn "Inbox: skipping malformed note: $(basename "$file")"
        return 1
    fi

    # Validate tag via registry
    if ! _validate_tag_registry "$tag" 2>/dev/null; then
        tag="FEAT"
    fi

    # add_human_note handles duplicate detection internally (M40)
    if command -v add_human_note &>/dev/null; then
        add_human_note "$title" "$tag" "$priority" "$source" "$description" "$inbox_basename"
    else
        warn "Inbox: add_human_note not available, appending raw note"
        echo "- [ ] [${tag}] ${title}" >> "${PROJECT_DIR:-.}/${HUMAN_NOTES_FILE}"
    fi
}

# _process_milestone FILE
# Validates and processes a milestone .md file from the inbox.
_process_milestone() {
    local file="$1"
    local basename
    basename=$(basename "$file")

    local ms_dir="${MILESTONE_DIR:-${PROJECT_DIR:-.}/.claude/milestones}"
    if [[ ! -d "$ms_dir" ]]; then
        mkdir -p "$ms_dir" 2>/dev/null || true
    fi

    mv "$file" "${ms_dir}/${basename}"
    log "Inbox: moved milestone file to ${ms_dir}/${basename}"
}

# _process_manifest_append FILE
# Validates a manifest append line and adds it to MANIFEST.cfg.
_process_manifest_append() {
    local file="$1"
    local manifest
    if declare -f _dag_manifest_path &>/dev/null; then
        manifest=$(_dag_manifest_path)
    else
        manifest="${MILESTONE_DIR:-${PROJECT_DIR:-.}/.claude/milestones}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"
    fi

    if [[ ! -f "$manifest" ]]; then
        warn "Inbox: MANIFEST.cfg not found, skipping manifest append: $(basename "$file")"
        return 1
    fi

    local line
    line=$(head -1 "$file" 2>/dev/null || true)
    if [[ -z "$line" ]]; then
        warn "Inbox: empty manifest append file: $(basename "$file")"
        return 1
    fi

    local mid
    mid=$(echo "$line" | cut -d'|' -f1)
    mid="${mid## }"; mid="${mid%% }"

    if [[ -z "$mid" ]]; then
        warn "Inbox: malformed manifest line in $(basename "$file")"
        return 1
    fi

    if grep -q "^${mid}|" "$manifest" 2>/dev/null; then
        warn "Inbox: milestone ID '${mid}' already exists in MANIFEST.cfg, skipping"
        return 1
    fi

    local deps
    deps=$(echo "$line" | cut -d'|' -f4)
    deps="${deps## }"; deps="${deps%% }"
    if [[ -n "$deps" ]]; then
        local dep
        local IFS=','
        for dep in $deps; do
            dep="${dep## }"; dep="${dep%% }"
            if [[ -n "$dep" ]] && ! grep -q "^${dep}|" "$manifest" 2>/dev/null; then
                warn "Inbox: dependency '${dep}' not found in MANIFEST.cfg for milestone '${mid}', skipping"
                return 1
            fi
        done
    fi

    local tmpfile="${manifest}.tmp.$$"
    cp "$manifest" "$tmpfile"
    printf '%s\n' "$line" >> "$tmpfile"
    mv "$tmpfile" "$manifest"
    success "Inbox: added milestone '${mid}' to MANIFEST.cfg"
}

# --- Public functions --------------------------------------------------------

# process_watchtower_inbox
# Main entry point: processes all pending inbox items at pipeline startup.
process_watchtower_inbox() {
    # Migrate hyphenated variant before anything else
    _migrate_hyphenated_inbox

    local inbox_dir
    inbox_dir="$(_inbox_dir)"

    INBOX_TASK_DESCRIPTIONS=""

    # Ensure the inbox directory exists so Watchtower submissions have a
    # landing zone even before the first note is submitted (Bug fix).
    mkdir -p "$inbox_dir" 2>/dev/null || true

    if [[ ! -d "$inbox_dir" ]]; then
        return 0
    fi

    local processed_dir
    processed_dir="$(_processed_dir)"

    local count=0
    local file basename

    # Process note files
    for file in "${inbox_dir}"/note_*.md; do
        [[ ! -f "$file" ]] && continue
        basename=$(basename "$file")
        if _process_note "$file" "$basename"; then
            mv "$file" "${processed_dir}/${basename}"
            # Mark in-progress in the processed copy
            sed -i 's/^- \[ \]/- [~]/' "${processed_dir}/${basename}" 2>/dev/null || true
            count=$((count + 1))
        fi
    done

    # Process milestone files
    for file in "${inbox_dir}"/milestone_*.md; do
        [[ ! -f "$file" ]] && continue
        basename=$(basename "$file")
        if _process_milestone "$file"; then
            count=$((count + 1))
        fi
    done

    for file in "${inbox_dir}"/manifest_append_*.cfg; do
        [[ ! -f "$file" ]] && continue
        basename=$(basename "$file")
        if _process_manifest_append "$file"; then
            mv "$file" "${processed_dir}/${basename}"
            count=$((count + 1))
        fi
    done

    # Collect task files
    for file in "${inbox_dir}"/task_*.txt; do
        [[ ! -f "$file" ]] && continue
        basename=$(basename "$file")
        local task_desc
        task_desc=$(head -1 "$file" 2>/dev/null || echo "(unreadable)")
        INBOX_TASK_DESCRIPTIONS="${INBOX_TASK_DESCRIPTIONS}${task_desc}"$'\n'
        mv "$file" "${processed_dir}/${basename}"
        count=$((count + 1))
    done

    if [[ "$count" -gt 0 ]]; then
        log "Inbox: processed ${count} item(s) from Watchtower"
    fi

    if command -v emit_dashboard_inbox &>/dev/null; then
        emit_dashboard_inbox 2>/dev/null || true
    fi
}

# drain_pending_inbox — Lightweight pre-commit inbox drain (M40).
# Processes any new inbox note files that arrived mid-run into ${HUMAN_NOTES_FILE}.
# These notes are persisted in the committed file but won't be triaged or
# executed in the current run.
drain_pending_inbox() {
    local inbox_dir
    inbox_dir="$(_inbox_dir)"

    if [[ ! -d "$inbox_dir" ]]; then
        return 0
    fi

    local processed_dir
    processed_dir="$(_processed_dir)"

    local count=0
    local file basename
    for file in "${inbox_dir}"/note_*.md; do
        [[ ! -f "$file" ]] && continue
        basename=$(basename "$file")
        if _process_note "$file" "$basename"; then
            mv "$file" "${processed_dir}/${basename}"
            # Mark in-progress in the processed copy
            sed -i 's/^- \[ \]/- [~]/' "${processed_dir}/${basename}" 2>/dev/null || true
            count=$((count + 1))
        fi
    done

    if [[ "$count" -gt 0 ]]; then
        log "Inbox drain: processed ${count} mid-run note(s) before commit"
    fi
}
