#!/usr/bin/env bash
# =============================================================================
# notes.sh — Human notes management (three-state tracking)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: NOTES_FILTER, LOG_DIR, TIMESTAMP (set by caller)
# Expects: log() from common.sh
#
# Note states:
#   [ ] — not started, available for work
#   [~] — in scope for this pipeline run (transient, never persists between runs)
#   [x] — completed
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

# Extracts unchecked human notes as a formatted block for injection into prompts.
# Returns items with their tags but without the checkbox prefix.
extract_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi
    if [ -n "$NOTES_FILTER" ]; then
        grep "^- \[ \] \[${NOTES_FILTER}\]" HUMAN_NOTES.md | sed 's/^- \[ \] /- /' || true
    else
        grep "^- \[ \]" HUMAN_NOTES.md | sed 's/^- \[ \] /- /' || true
    fi
}

# Marks filtered [ ] items as [~] (in-scope for this run).
# Call BEFORE invoking the coder agent. Archives current state first.
claim_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi

    # Archive pre-run snapshot
    cp "HUMAN_NOTES.md" "${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md"
    log "Archived HUMAN_NOTES.md → ${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md"

    if [ -n "$NOTES_FILTER" ]; then
        sed -i "s/^- \[ \] \[${NOTES_FILTER}\]/- [~] [${NOTES_FILTER}]/" HUMAN_NOTES.md
        local claimed
        claimed=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
        log "HUMAN_NOTES.md — ${claimed} [${NOTES_FILTER}] item(s) marked in-progress [~]."
    else
        sed -i 's/^- \[ \] /- [~] /' HUMAN_NOTES.md
        local claimed
        claimed=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
        log "HUMAN_NOTES.md — ${claimed} item(s) marked in-progress [~]."
    fi
}

# Resolves [~] items based on CODER_SUMMARY.md completion reporting.
# Items the coder reports as COMPLETED → [x]. Items not addressed → back to [ ].
# If CODER_SUMMARY.md lacks a "Human Notes Status" section, falls back to
# marking all [~] items based on the coder's overall status.
resolve_human_notes() {
    if [ ! -f "HUMAN_NOTES.md" ]; then
        return
    fi

    local claimed_count
    claimed_count=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
    if [ "$claimed_count" -eq 0 ]; then
        return
    fi

    # Try parsing structured completion from CODER_SUMMARY.md
    if [ -f "CODER_SUMMARY.md" ]; then
        local notes_section
        notes_section=$(awk '/^## Human Notes Status/{found=1; next} found && /^##/{exit} found{print}' \
            CODER_SUMMARY.md 2>/dev/null || true)

        if [ -n "$notes_section" ]; then
            # Structured reporting: mark individual items based on coder output
            local completed=0
            local reset=0

            while IFS= read -r line; do
                [ -z "$line" ] && continue

                # Extract the note text after COMPLETED:/NOT_ADDRESSED:
                local note_text=""
                local action=""
                if echo "$line" | grep -qi "^- COMPLETED:"; then
                    # shellcheck disable=SC2001
                    note_text=$(echo "$line" | sed 's/^- COMPLETED:[[:space:]]*//')
                    action="complete"
                elif echo "$line" | grep -qi "^- NOT_ADDRESSED:"; then
                    # shellcheck disable=SC2001
                    note_text=$(echo "$line" | sed 's/^- NOT_ADDRESSED:[[:space:]]*//')
                    action="reset"
                else
                    continue
                fi

                # Escape the note text for sed matching (handle regex special chars)
                local escaped_text
                # shellcheck disable=SC2016
                escaped_text=$(printf '%s' "$note_text" | sed 's/[.[\*^$()+?{|/]/\\&/g')

                if [ "$action" = "complete" ]; then
                    # Find the [~] line containing this text and mark [x]
                    if grep -q "^- \[~\].*${escaped_text}" HUMAN_NOTES.md 2>/dev/null; then
                        sed -i "0,/^- \[~\]\(.*${escaped_text}\)/s//- [x]\1/" HUMAN_NOTES.md
                        completed=$((completed + 1))
                    fi
                elif [ "$action" = "reset" ]; then
                    if grep -q "^- \[~\].*${escaped_text}" HUMAN_NOTES.md 2>/dev/null; then
                        sed -i "0,/^- \[~\]\(.*${escaped_text}\)/s//- [ ]\1/" HUMAN_NOTES.md
                        reset=$((reset + 1))
                    fi
                fi
            done <<< "$notes_section"

            log "HUMAN_NOTES.md — ${completed} item(s) completed, ${reset} item(s) reset to [ ]."

            # Safety: any remaining [~] items the coder didn't mention → reset to [ ]
            local remaining
            remaining=$(grep -c "^- \[~\]" HUMAN_NOTES.md || true)
            if [ "$remaining" -gt 0 ]; then
                sed -i 's/^- \[~\] /- [ ] /' HUMAN_NOTES.md
                log "HUMAN_NOTES.md — ${remaining} unmentioned [~] item(s) reset to [ ]."
            fi
            return
        fi
    fi

    # Fallback: no structured reporting. Use coder status to decide.
    local coder_status=""
    if [ -f "CODER_SUMMARY.md" ]; then
        coder_status=$(grep "^## Status" CODER_SUMMARY.md 2>/dev/null | head -1 || true)
    fi

    if [[ "$coder_status" == *"COMPLETE"* ]]; then
        # Coder finished but didn't use structured reporting — mark all claimed as done
        sed -i 's/^- \[~\] /- [x] /' HUMAN_NOTES.md
        log "HUMAN_NOTES.md — all [~] items marked [x] (coder status: COMPLETE, no structured report)."
    else
        # Coder didn't finish or no summary — reset everything
        sed -i 's/^- \[~\] /- [ ] /' HUMAN_NOTES.md
        log "HUMAN_NOTES.md — all [~] items reset to [ ] (coder incomplete or missing summary)."
    fi
}
