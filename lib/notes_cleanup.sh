#!/usr/bin/env bash
set -euo pipefail
# notes_cleanup.sh — NON_BLOCKING_LOG batch selection and marking functions
# Sourced by tekhton.sh. Expects: PROJECT_DIR, NON_BLOCKING_LOG_FILE, log(), warn()

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
