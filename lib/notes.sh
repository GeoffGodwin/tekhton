#!/usr/bin/env bash
# =============================================================================
# notes.sh — Human notes management
#
# Sourced by tekhton.sh — do not run directly.
# Expects: NOTES_FILTER, LOG_DIR, TIMESTAMP (set by caller)
# Expects: log() from common.sh
# =============================================================================

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

# Extracts unchecked human notes as a formatted block for injection into prompts
extract_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi
    if [ -n "$NOTES_FILTER" ]; then
        grep "^- \[ \] \[${NOTES_FILTER}\]" HUMAN_NOTES.md | sed 's/^- \[ \] /- /'
    else
        grep "^- \[ \]" HUMAN_NOTES.md | sed 's/^- \[ \] /- /'
    fi
}

# Archives HUMAN_NOTES.md and resets it with all items checked off
archive_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi
    cp "HUMAN_NOTES.md" "${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md"
    log "Archived HUMAN_NOTES.md → ${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md"

    if [ -n "$NOTES_FILTER" ]; then
        # Only mark the filtered tag's items as done — leave others unchecked
        sed -i "s/^- \[ \] \[${NOTES_FILTER}\]/- [x] [${NOTES_FILTER}]/" HUMAN_NOTES.md
        log "HUMAN_NOTES.md — [${NOTES_FILTER}] items marked complete. Other tags untouched."
    else
        # Mark everything done
        sed -i 's/^- \[ \] /- [x] /' HUMAN_NOTES.md
        log "HUMAN_NOTES.md — all items marked complete."
    fi
}
