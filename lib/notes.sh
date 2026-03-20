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

# --- Single-note utility functions (Milestone 15.4.1) — operates on HUMAN_NOTES.md ---
# These enable precise one-at-a-time note processing for --human mode.

# _escape_sed_pattern — Escapes regex special characters for safe sed matching.
# Usage: escaped=$(_escape_sed_pattern "$text")
_escape_sed_pattern() {
    # shellcheck disable=SC2016
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|/&]/\\&/g'
}

# _section_for_tag — Maps a tag filter to the HUMAN_NOTES.md section heading.
# BUG → ## Bugs, FEAT → ## Features, POLISH → ## Polish
_section_for_tag() {
    local tag="${1:-}"
    case "$tag" in
        BUG)    echo "## Bugs" ;;
        FEAT)   echo "## Features" ;;
        POLISH) echo "## Polish" ;;
        *)      echo "" ;;
    esac
}

# pick_next_note — Returns the first unchecked note from HUMAN_NOTES.md in priority
# order: ## Bugs first, then ## Features, then ## Polish.
# If tag_filter is set, only scans the corresponding section.
# Usage: note_line=$(pick_next_note "BUG")  # or "" for all sections
pick_next_note() {
    local tag_filter="${1:-}"

    if [[ ! -f "HUMAN_NOTES.md" ]]; then
        echo ""
        return 0
    fi

    local sections
    if [[ -n "$tag_filter" ]]; then
        local target_section
        target_section=$(_section_for_tag "$tag_filter")
        if [[ -z "$target_section" ]]; then
            echo ""
            return 0
        fi
        sections=("$target_section")
    else
        sections=("## Bugs" "## Features" "## Polish")
    fi

    local section
    for section in "${sections[@]}"; do
        local result
        result=$(awk -v sect="$section" '
            BEGIN { in_section = 0 }
            $0 == sect { in_section = 1; next }
            in_section && /^## / { exit }
            in_section && /^- \[ \] / { print; exit }
        ' HUMAN_NOTES.md)
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    done

    echo ""
    return 0
}

# claim_single_note — Marks exactly ONE note from [ ] to [~] in HUMAN_NOTES.md.
# Archives pre-run snapshot before modification.
# Usage: claim_single_note "- [ ] [BUG] Fix the thing"
claim_single_note() {
    local note_line="$1"

    if [[ ! -f "HUMAN_NOTES.md" ]] || [[ -z "$note_line" ]]; then
        return 1
    fi

    # Archive pre-run snapshot
    if [[ -n "${LOG_DIR:-}" ]] && [[ -n "${TIMESTAMP:-}" ]] && [[ -d "${LOG_DIR:-}" ]]; then
        cp "HUMAN_NOTES.md" "${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md"
    else
        cp "HUMAN_NOTES.md" "HUMAN_NOTES.md.bak"
    fi

    # Replace first occurrence of the exact [ ] line with [~]
    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" = "$note_line" ]]; then
            # Replace [ ] with [~]
            printf '%s\n' "${line/\[ \]/[~]}"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "HUMAN_NOTES.md" > "$tmpfile"
    mv "$tmpfile" "HUMAN_NOTES.md"

    if [[ "$found" -eq 1 ]]; then
        return 0
    fi
    return 1
}

# resolve_single_note — Resolves a single in-progress note.
# If exit_code=0: [~] → [x]. If non-zero: [~] → [ ].
# The note_line should be the ORIGINAL line (with [ ]); this function
# reconstructs the [~] version to match against the file.
# Usage: resolve_single_note "- [ ] [BUG] Fix the thing" 0
resolve_single_note() {
    local note_line="$1"
    local exit_code="${2:-1}"

    if [[ ! -f "HUMAN_NOTES.md" ]] || [[ -z "$note_line" ]]; then
        return 1
    fi

    # Reconstruct the [~] version of the note line
    local claimed_line="${note_line/\[ \]/[~]}"

    local replacement
    if [[ "$exit_code" -eq 0 ]]; then
        replacement="${note_line/\[ \]/[x]}"
    else
        replacement="$note_line"
    fi

    local tmpfile
    tmpfile=$(mktemp)
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$found" -eq 0 ]] && [[ "$line" = "$claimed_line" ]]; then
            printf '%s\n' "$replacement"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "HUMAN_NOTES.md" > "$tmpfile"
    mv "$tmpfile" "HUMAN_NOTES.md"

    if [[ "$found" -eq 1 ]]; then
        return 0
    fi
    return 1
}

# extract_note_text — Strips the checkbox prefix from a note line.
# Returns the rest of the line after "- [ ] ", "- [~] ", or "- [x] ".
# Usage: text=$(extract_note_text "- [ ] [BUG] Fix the thing")
#   → "[BUG] Fix the thing"
extract_note_text() {
    local note_line="$1"
    # Strip "- [ ] ", "- [~] ", or "- [x] " prefix (6 chars)
    local text="${note_line#- \[?\] }"
    # If the simple strip didn't work, try each pattern
    if [[ "$text" = "$note_line" ]]; then
        text="${note_line#- \[ \] }"
    fi
    if [[ "$text" = "$note_line" ]]; then
        text="${note_line#- \[~\] }"
    fi
    if [[ "$text" = "$note_line" ]]; then
        text="${note_line#- \[x\] }"
    fi
    echo "$text"
}

# count_unchecked_notes — Counts remaining [ ] lines in HUMAN_NOTES.md.
# If tag_filter is set, counts only within the matching section.
# Usage: remaining=$(count_unchecked_notes "BUG")
count_unchecked_notes() {
    local tag_filter="${1:-}"

    if [[ ! -f "HUMAN_NOTES.md" ]]; then
        echo "0"
        return 0
    fi

    if [[ -n "$tag_filter" ]]; then
        local target_section
        target_section=$(_section_for_tag "$tag_filter")
        if [[ -z "$target_section" ]]; then
            echo "0"
            return 0
        fi
        local count
        count=$(awk -v sect="$target_section" '
            BEGIN { in_section = 0; count = 0 }
            $0 == sect { in_section = 1; next }
            in_section && /^## / { exit }
            in_section && /^- \[ \] / { count++ }
            END { print count }
        ' HUMAN_NOTES.md)
        echo "$count"
    else
        local count
        count=$(grep -c '^- \[ \] ' HUMAN_NOTES.md || true)
        echo "${count:-0}"
    fi
    return 0
}

# --- Cleanup batch selection (Milestone 5) — operates on NON_BLOCKING_LOG.md ---

# count_unresolved_notes — Returns count of open (non-deferred) non-blocking notes.
# Excludes items marked [x] (resolved) and [DEFERRED].
count_unresolved_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        echo "0"
        return
    fi
    local count
    count=$(awk '/^## Open/{found=1; next} found && /^##/{exit} found && /^- \[ \]/{count++} END{print count+0}' \
        "$nb_file" 2>/dev/null)
    echo "$count"
}

# select_cleanup_batch — Returns up to N open non-blocking notes, prioritized by:
#   1. Recurring patterns (notes referencing the same file appear most often)
#   2. Files modified this run (passed via $2 by the caller)
#   3. Age (oldest first — FIFO)
#
# Usage: select_cleanup_batch 5 "$modified_files"
# Args:  $1 = batch size (default: 5)
#        $2 = newline-separated list of modified file paths (optional, from caller)
# Output: One note per line (full markdown line from NON_BLOCKING_LOG.md)
select_cleanup_batch() {
    local batch_size="${1:-5}"
    local modified_files="${2:-}"
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

    if [ ! -f "$nb_file" ]; then
        return
    fi

    # Extract all open (non-deferred) notes
    local open_notes
    open_notes=$(awk '/^## Open/{found=1; next} found && /^##/{exit} found && /^- \[ \]/{print}' \
        "$nb_file" 2>/dev/null || true)

    if [ -z "$open_notes" ]; then
        return
    fi

    # Score each note: recurrence (how many other open notes reference the same file),
    # then file-overlap (files modified this run, passed by caller), then age (line order).
    local scored_notes
    scored_notes=$(echo "$open_notes" | awk -v mod_files="$modified_files" '
    BEGIN {
        # Build modified-files lookup
        n = split(mod_files, mf, "\n")
        for (i = 1; i <= n; i++) {
            # Extract basename for fuzzy matching
            sub(/.*\//, "", mf[i])
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", mf[i])
            if (length(mf[i]) > 0) modified[mf[i]] = 1
        }
    }
    {
        lines[NR] = $0
        # Extract file references (backtick-quoted paths like `lib/foo.sh`)
        match($0, /`[^`]+\.[a-zA-Z]+`/)
        if (RSTART > 0) {
            ref = substr($0, RSTART+1, RLENGTH-2)
            sub(/.*\//, "", ref)  # basename
            file_refs[NR] = ref
        } else {
            file_refs[NR] = ""
        }
    }
    END {
        # Count recurrence: how many notes reference each file
        for (i = 1; i <= NR; i++) {
            if (length(file_refs[i]) > 0) {
                file_count[file_refs[i]]++
            }
        }

        for (i = 1; i <= NR; i++) {
            score = 0
            # Recurrence score: notes referencing files that appear in multiple notes
            if (length(file_refs[i]) > 0 && file_refs[i] in file_count) {
                score += file_count[file_refs[i]] * 10
            }
            # File-overlap score: note references a file modified this run
            if (length(file_refs[i]) > 0 && file_refs[i] in modified) {
                score += 100
            }
            # Age score: older notes (lower line number) get slight priority
            score += (NR - i)
            printf "%06d\t%s\n", score, lines[i]
        }
    }' | sort -t$'\t' -k1 -rn | head -n "$batch_size" | cut -f2-)

    echo "$scored_notes"
}

# mark_note_resolved — Marks a specific open note as [x] in NON_BLOCKING_LOG.md.
# Usage: mark_note_resolved "partial text to match"
# Matches the first open note containing the given text.
mark_note_resolved() {
    local match_text="$1"
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

    if [ ! -f "$nb_file" ]; then
        return 1
    fi

    # Escape special regex characters in match text
    local escaped
    # shellcheck disable=SC2016
    escaped=$(printf '%s' "$match_text" | sed 's/[.[\*^$()+?{|/]/\\&/g')

    if grep -q "^- \[ \].*${escaped}" "$nb_file" 2>/dev/null; then
        # GNU sed 0, address: first-match-only range (not portable to BSD sed/macOS)
        sed -i "0,/^- \[ \]\(.*${escaped}\)/s//- [x]\1/" "$nb_file"
        return 0
    fi
    return 1
}

# mark_note_deferred — Tags an open note as [DEFERRED] in NON_BLOCKING_LOG.md.
# Deferred notes are excluded from future cleanup batch selection.
# Usage: mark_note_deferred "partial text to match"
mark_note_deferred() {
    local match_text="$1"
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

    if [ ! -f "$nb_file" ]; then
        return 1
    fi

    # Escape special regex characters in match text
    local escaped
    # shellcheck disable=SC2016
    escaped=$(printf '%s' "$match_text" | sed 's/[.[\*^$()+?{|/]/\\&/g')

    if grep -q "^- \[ \].*${escaped}" "$nb_file" 2>/dev/null; then
        # GNU sed 0, address: first-match-only range (not portable to BSD sed/macOS)
        sed -i "0,/^- \[ \]\(.*${escaped}\)/s//- [DEFERRED]\1/" "$nb_file"
        return 0
    fi
    return 1
}
