#!/usr/bin/env bash
set -euo pipefail
# notes.sh — Human notes management (three-state tracking)
# Sourced by tekhton.sh. Expects: NOTES_FILTER, LOG_DIR, TIMESTAMP, log()
# States: [ ] not started, [~] in-scope this run (transient), [x] completed
#
# M40: Claim/resolve logic moved to notes_core.sh. This file retains the
# public API surface (should_claim_notes, count_human_notes, extract_human_notes,
# claim_human_notes, resolve_human_notes, clear_completed_human_notes) but
# delegates to the unified ID-based API in notes_core.sh.

# should_claim_notes — Returns 0 (true) if human notes should be claimed for
# this run. Notes are only injected when an explicit flag is set:
#   --with-notes (WITH_NOTES=true)
#   --human      (HUMAN_MODE=true)
#   --notes-filter X (NOTES_FILTER non-empty)
# Task text is never inspected. This prevents phantom notes injection.
should_claim_notes() {
    if [[ "${WITH_NOTES:-false}" = "true" ]]; then
        return 0
    fi
    if [[ "${HUMAN_MODE:-false}" = "true" ]]; then
        return 0
    fi
    if [[ -n "${NOTES_FILTER:-}" ]]; then
        return 0
    fi
    return 1
}

# Reads HUMAN_NOTES.md and returns unchecked items count
count_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        echo "0"
        return
    fi
    local pattern="^- \[ \]"
    if [ -n "$NOTES_FILTER" ]; then
        pattern="^- \[ \] \[${NOTES_FILTER}\]"
    fi
    local count
    count=$(grep -c "$pattern" HUMAN_NOTES.md || true)
    echo "$count" | tr -d '[:space:]'
}

# Extracts unchecked human notes as a formatted block for injection into prompts.
# Returns items with their tags but without the checkbox prefix or metadata comments.
extract_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi
    if [ -n "$NOTES_FILTER" ]; then
        grep "^- \[ \] \[${NOTES_FILTER}\]" HUMAN_NOTES.md \
            | sed 's/^- \[ \] /- /' \
            | sed 's/ <!-- note:[^>]*-->//' || true
    else
        grep "^- \[ \]" HUMAN_NOTES.md \
            | sed 's/^- \[ \] /- /' \
            | sed 's/ <!-- note:[^>]*-->//' || true
    fi
}

# claim_human_notes — Marks filtered [ ] items as [~] (in-scope for this run).
# M40: Delegates to claim_notes_batch from notes_core.sh.
claim_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi

    # Archive handled by claim_notes_batch() — no duplicate cp needed

    local filter="${NOTES_FILTER:-}"
    # claim_notes_batch also populates CLAIMED_NOTE_IDS (used by finalize hooks)
    claim_notes_batch "$filter" >/dev/null

    local claimed
    claimed=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
    if [ -n "$filter" ]; then
        log "HUMAN_NOTES.md — ${claimed} [${filter}] item(s) marked in-progress [~]."
    else
        log "HUMAN_NOTES.md — ${claimed} item(s) marked in-progress [~]."
    fi
}

# resolve_human_notes — Resolves [~] items based on pipeline outcome.
# M40: Delegates to resolve_notes_batch from notes_core.sh using CLAIMED_NOTE_IDS.
resolve_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi

    local claimed_count
    claimed_count=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
    if [ "$claimed_count" -eq 0 ]; then
        return
    fi

    local exit_code="${_PIPELINE_EXIT_CODE:-1}"
    if [[ -n "${CLAIMED_NOTE_IDS:-}" ]]; then
        resolve_notes_batch "$CLAIMED_NOTE_IDS" "$exit_code"
        local resolved
        if [[ "$exit_code" -eq 0 ]]; then
            resolved=$(echo "$CLAIMED_NOTE_IDS" | wc -w | tr -d '[:space:]')
            log "HUMAN_NOTES.md — ${resolved} item(s) resolved via ID-based batch."
        else
            log "HUMAN_NOTES.md — ${claimed_count} item(s) reset to [ ] (pipeline failed)."
        fi
    fi

    # Safety: any remaining [~] items → resolve based on exit code
    local remaining
    remaining=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
    if [ "$remaining" -gt 0 ]; then
        if [[ "$exit_code" -eq 0 ]]; then
            sed -i 's/^- \[~\] /- [x] /' HUMAN_NOTES.md
            log "HUMAN_NOTES.md — ${remaining} remaining [~] item(s) marked [x] (pipeline success)."
        else
            sed -i 's/^- \[~\] /- [ ] /' HUMAN_NOTES.md
            warn "HUMAN_NOTES.md — ${remaining} remaining [~] item(s) reset to [ ]."
        fi
    fi
}

# --- Single-note functions extracted to lib/notes_single.sh ---

# clear_completed_human_notes — Removes [x] items from HUMAN_NOTES.md.
# Called at the start of each pipeline run so completed notes from prior runs
# do not accumulate. Non-interactive (no confirmation prompt).
# Preserves description blocks (indented > lines below completed notes).
clear_completed_human_notes() {
    local notes_file="${PROJECT_DIR}/HUMAN_NOTES.md"
    if [ ! -f "$notes_file" ]; then
        return 0
    fi

    local completed_count
    completed_count=$(grep -c '^- \[x\] ' "$notes_file" || true)
    if [ "$completed_count" -eq 0 ]; then
        return 0
    fi

    # Safety: count unchecked before
    local unchecked_before
    unchecked_before=$(grep -c '^- \[ \] ' "$notes_file" || true)

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/notes_XXXXXXXX")
    local skip_desc=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^-\ \[x\]\  ]]; then
            # Delete inbox source file if this was a watchtower note
            if [[ "$line" =~ inbox_file:([^\ ]+) ]]; then
                local inbox_processed="${PROJECT_DIR}/.claude/watchtower_inbox/processed/${BASH_REMATCH[1]}"
                rm -f "$inbox_processed" 2>/dev/null || true
            fi
            skip_desc=true
            continue
        fi
        # Skip description blocks belonging to removed [x] notes
        if [[ "$skip_desc" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*\> ]] || [[ "$line" =~ ^[[:space:]]+\> ]]; then
                continue
            fi
            skip_desc=false
        fi
        printf '%s\n' "$line"
    done < "$notes_file" > "$tmpfile"
    mv "$tmpfile" "$notes_file"

    # Safety: verify unchecked count unchanged
    local unchecked_after
    unchecked_after=$(grep -c '^- \[ \] ' "$notes_file" || true)
    if [ "$unchecked_after" -ne "$unchecked_before" ]; then
        warn "HUMAN_NOTES.md unchecked count changed unexpectedly (${unchecked_before} → ${unchecked_after})"
    fi

    log "Cleared ${completed_count} completed [x] item(s) from HUMAN_NOTES.md."
}

# --- NON_BLOCKING_LOG batch functions extracted to lib/notes_cleanup.sh ---
