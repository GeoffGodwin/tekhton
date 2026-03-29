#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# inbox.sh — Watchtower inbox processing for pipeline startup
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh, notes_cli.sh, milestone_dag.sh sourced first.
# Expects: PROJECT_DIR, MILESTONE_DIR, MILESTONE_MANIFEST from config.
#
# Processes files from .claude/watchtower_inbox/ at pipeline startup:
#   - note_*.md   → appended to HUMAN_NOTES.md via add_human_note()
#   - manifest_append_*.cfg → validated and appended to MANIFEST.cfg
#   - milestone_*.md → moved to MILESTONE_DIR
#   - task_*.txt  → surfaced to user (not auto-executed)
#
# Processed items are moved to .claude/watchtower_inbox/processed/.
#
# Provides:
#   process_watchtower_inbox  — main entry point, called at pipeline startup
# =============================================================================

# --- Constants ---------------------------------------------------------------

_INBOX_DIR_NAME="watchtower_inbox"

# --- Internal helpers --------------------------------------------------------

# _inbox_dir
# Returns the inbox directory path.
_inbox_dir() {
    echo "${PROJECT_DIR:-.}/.claude/${_INBOX_DIR_NAME}"
}

# _processed_dir
# Returns the processed subdirectory path, creating it if needed.
_processed_dir() {
    local dir
    dir="$(_inbox_dir)/processed"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

# _process_note FILE
# Reads a note file from the inbox and appends it to HUMAN_NOTES.md.
_process_note() {
    local file="$1"
    local tag="" title="" line

    # Extract the checkbox line to get tag and title
    while IFS= read -r line; do
        if [[ "$line" =~ ^-\ \[\ \]\ \[([A-Z]+)\]\ (.+)$ ]]; then
            tag="${BASH_REMATCH[1]}"
            title="${BASH_REMATCH[2]}"
            break
        fi
    done < "$file"

    if [[ -z "$title" ]]; then
        warn "Inbox: skipping malformed note: $(basename "$file")"
        return 1
    fi

    # Validate tag
    case "$tag" in
        BUG|FEAT|POLISH) ;;
        *) tag="FEAT" ;;
    esac

    # Use the existing add_human_note function.
    # Known limitation: description, priority, and source fields from the inbox
    # file are not passed through — only title+tag are written to the flat
    # HUMAN_NOTES.md checklist format.
    if command -v add_human_note &>/dev/null; then
        add_human_note "$title" "$tag"
    else
        warn "Inbox: add_human_note not available, appending raw note"
        echo "- [ ] [${tag}] ${title}" >> "${PROJECT_DIR:-.}/HUMAN_NOTES.md"
    fi
}

# _process_milestone FILE
# Validates and processes a milestone .md file from the inbox.
_process_milestone() {
    local file="$1"
    local basename
    basename=$(basename "$file")

    # Only milestone_mNN.md files reach here (from the milestone_*.md glob loop)

    local ms_dir="${MILESTONE_DIR:-${PROJECT_DIR:-.}/.claude/milestones}"
    if [[ ! -d "$ms_dir" ]]; then
        mkdir -p "$ms_dir" 2>/dev/null || true
    fi

    # Move milestone file to the milestones directory
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

    # Parse the line: id|title|status|deps|file|parallel_group
    local mid
    mid=$(echo "$line" | cut -d'|' -f1)
    mid="${mid## }"; mid="${mid%% }"

    if [[ -z "$mid" ]]; then
        warn "Inbox: malformed manifest line in $(basename "$file")"
        return 1
    fi

    # Check for ID collision
    if grep -q "^${mid}|" "$manifest" 2>/dev/null; then
        warn "Inbox: milestone ID '${mid}' already exists in MANIFEST.cfg, skipping"
        return 1
    fi

    # Validate deps exist in manifest
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

    # Append to manifest (atomic via tmpfile+mv)
    local tmpfile="${manifest}.tmp.$$"
    cp "$manifest" "$tmpfile"
    printf '%s\n' "$line" >> "$tmpfile"
    mv "$tmpfile" "$manifest"
    success "Inbox: added milestone '${mid}' to MANIFEST.cfg"
}

# --- Public function ---------------------------------------------------------

# process_watchtower_inbox
# Main entry point: processes all pending inbox items at pipeline startup.
# Returns 0 on success, even if individual items fail.
# Sets INBOX_TASK_DESCRIPTIONS as a newline-separated list of task descriptions
# (for the caller to surface to the user).
process_watchtower_inbox() {
    local inbox_dir
    inbox_dir="$(_inbox_dir)"

    INBOX_TASK_DESCRIPTIONS=""

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
        if _process_note "$file"; then
            mv "$file" "${processed_dir}/${basename}"
            count=$((count + 1))
        fi
    done

    # Process milestone files (milestone_mNN.md first, then manifest_append)
    for file in "${inbox_dir}"/milestone_*.md; do
        [[ ! -f "$file" ]] && continue
        basename=$(basename "$file")
        if _process_milestone "$file"; then
            # milestone_*.md files are moved by _process_milestone itself
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

    # Collect task files (surfaced to user, not auto-executed)
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

    # Emit updated inbox data for dashboard
    if command -v emit_dashboard_inbox &>/dev/null; then
        emit_dashboard_inbox 2>/dev/null || true
    fi
}
