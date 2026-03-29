#!/usr/bin/env bash
set -euo pipefail
# notes.sh — Human notes management (three-state tracking)
# Sourced by tekhton.sh. Expects: NOTES_FILTER, LOG_DIR, TIMESTAMP, log()
# States: [ ] not started, [~] in-scope this run (transient), [x] completed

# should_claim_notes — Returns 0 (true) if human notes should be claimed for
# this run. Notes are only injected when an explicit flag is set:
#   --with-notes (WITH_NOTES=true)
#   --human      (HUMAN_MODE=true)
#   --notes-filter X (NOTES_FILTER non-empty)
# Task text is never inspected. This prevents phantom notes injection.
# Usage: should_claim_notes
should_claim_notes() {
    # --with-notes flag forces claiming
    if [[ "${WITH_NOTES:-false}" = "true" ]]; then
        return 0
    fi

    # --human flag forces claiming
    if [[ "${HUMAN_MODE:-false}" = "true" ]]; then
        return 0
    fi

    # Active notes filter implies intent to address notes
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
                        # GNU sed 0, address: first-match-only range (not portable to BSD sed/macOS)
                        sed -i "0,/^- \[~\]\(.*${escaped_text}\)/s//- [x]\1/" HUMAN_NOTES.md
                        completed=$((completed + 1))
                    fi
                elif [ "$action" = "reset" ]; then
                    if grep -q "^- \[~\].*${escaped_text}" HUMAN_NOTES.md 2>/dev/null; then
                        # GNU sed 0, address: first-match-only range (not portable to BSD sed/macOS)
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
                warn "HUMAN_NOTES.md — ${remaining} unmentioned [~] item(s) reset to [ ]."
                log "Some human notes were not fully addressed."
            fi

            # If nothing was completed or explicitly addressed, notes were ignored
            if [ "$completed" -eq 0 ] && [ "$reset" -eq 0 ]; then
                warn "Coder wrote ## Human Notes Status section but did not address any notes."
                log "Some human notes were not fully addressed."
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
        # NOTE: Without structured reporting we can't verify, but trust COMPLETE status
        sed -i 's/^- \[~\] /- [x] /' HUMAN_NOTES.md
        log "HUMAN_NOTES.md — all [~] items marked [x] (coder status: COMPLETE, no structured report)."
        warn "Coder did not produce structured ## Human Notes Status section."
    # Fallback for success without CODER_SUMMARY.md: _PIPELINE_EXIT_CODE is set to 0 by
    # tekhton.sh:991 before calling this function when pipeline succeeds. The elif path fires
    # only when CODER_SUMMARY.md is absent but exit code is clean (features implemented and
    # committed). This guard exists to allow test harnesses to set _PIPELINE_EXIT_CODE to
    # non-zero to simulate failure scenarios.
    elif [[ -n "${_PIPELINE_EXIT_CODE:-}" ]] && [[ "${_PIPELINE_EXIT_CODE}" -eq 0 ]]; then
        # Pipeline succeeded (exit 0) but CODER_SUMMARY.md is missing or incomplete.
        # Features were implemented and committed — treat as success rather than resetting.
        sed -i 's/^- \[~\] /- [x] /' HUMAN_NOTES.md
        log "HUMAN_NOTES.md — all [~] items marked [x] (pipeline succeeded, no structured report)."
    else
        # Coder didn't finish or no summary — reset everything
        sed -i 's/^- \[~\] /- [ ] /' HUMAN_NOTES.md
        log "HUMAN_NOTES.md — all [~] items reset to [ ] (coder incomplete or missing summary)."
    fi
}

# --- Single-note functions extracted to lib/notes_single.sh ---
# Provides: _escape_sed_pattern, _section_for_tag, pick_next_note,
#   claim_single_note, resolve_single_note, extract_note_text, count_unchecked_notes

# clear_completed_human_notes — Removes [x] items from HUMAN_NOTES.md.
# Called at the start of each pipeline run so completed notes from prior runs
# do not accumulate. Non-interactive (no confirmation prompt).
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
    grep -v '^- \[x\] ' "$notes_file" > "$tmpfile"
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
# Provides: count_unresolved_notes, select_cleanup_batch,
#   mark_note_resolved, mark_note_deferred
