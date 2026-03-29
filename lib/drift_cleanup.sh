#!/usr/bin/env bash
# =============================================================================
# drift_cleanup.sh — Non-blocking notes management and drift cleanup helpers
#
# Extracted from drift.sh to keep file sizes under the 300-line ceiling.
# Sourced by tekhton.sh after drift.sh — do not run directly.
# Expects: PROJECT_DIR, DRIFT_LOG_FILE, NON_BLOCKING_LOG_FILE (set by config)
# Uses: _awk_join_bullets() from drift.sh (sourced before this file)
# =============================================================================

set -euo pipefail

# =============================================================================
# NON-BLOCKING NOTES ACCUMULATION
# Tracks reviewer Non-Blocking Notes across runs. When they exceed a threshold,
# they are injected into the coder prompt so they get addressed.
# =============================================================================

# _ensure_nonblocking_log — Creates NON_BLOCKING_LOG.md if missing.
_ensure_nonblocking_log() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        cat > "$nb_file" << 'EOF'
# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
EOF
    fi
}

# append_nonblocking_notes — Reads Non-Blocking Notes from REVIEWER_REPORT.md
# and appends new items to NON_BLOCKING_LOG.md under ## Open.
append_nonblocking_notes() {
    local reviewer_report="${PROJECT_DIR}/REVIEWER_REPORT.md"
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

    if [ ! -f "$reviewer_report" ]; then
        return 0
    fi

    local notes
    notes=$(awk '/^## Non-Blocking Notes/{found=1; next} found && /^##/{exit} found{print}' \
        "$reviewer_report" 2>/dev/null || true)

    # Skip if empty or only "None"
    if [ -z "$notes" ] || echo "$notes" | grep -qiE '^\s*-?\s*None\s*$'; then
        return 0
    fi

    _ensure_nonblocking_log

    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local task_desc="${TASK:-unknown}"

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")

    local awk_prog
    awk_prog=$(_awk_join_bullets \
        '/^## Open/' \
        '- [ ] [%s | \"%s\"] %s')

    awk -v date="$date_tag" -v task="$task_desc" -v input="$notes" \
        "$awk_prog" "$nb_file" > "$tmpfile"

    mv "$tmpfile" "$nb_file"
}

# count_open_nonblocking_notes — Returns count of open (unchecked) notes.
count_open_nonblocking_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        echo "0"
        return
    fi
    local count
    count=$(awk '/^## Open/{found=1; next} found && /^## [^#]/{exit} found && /^- \[ \]/{count++} END{print count+0}' \
        "$nb_file" 2>/dev/null)
    echo "$count"
}

# get_open_nonblocking_notes — Returns the text of all open notes.
get_open_nonblocking_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        return
    fi
    awk '/^## Open/{found=1; next} found && /^## [^#]/{exit} found && /^- \[ \]/{print}' \
        "$nb_file" 2>/dev/null || true
}

# _resolve_addressed_nonblocking_notes — After a coder run, check if any open
# notes were addressed (file/line referenced in CODER_SUMMARY.md). Simple
# heuristic: if the coder's modified files list includes a file mentioned in
# an open note, mark it [x].
_resolve_addressed_nonblocking_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    local summary="${PROJECT_DIR}/CODER_SUMMARY.md"

    if [ ! -f "$nb_file" ] || [ ! -f "$summary" ]; then
        return 0
    fi

    # Extract file paths from coder summary's modified/created sections
    local modified_files
    modified_files=$(awk '/^## Files (Created|Modified)/{found=1; next} found && /^##/{exit} found && /^[-*]/{print}' \
        "$summary" 2>/dev/null | sed 's/^[-*][[:space:]]*//' | sed 's/ .*//' | sort -u || true)

    if [ -z "$modified_files" ]; then
        return 0
    fi

    # For each open note, check if any referenced file was modified
    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    local resolved=0
    local in_open=false

    while IFS= read -r line; do
        if echo "$line" | grep -q "^## Open"; then
            in_open=true
            echo "$line" >> "$tmpfile"
            continue
        elif echo "$line" | grep -q "^## " && [[ "$in_open" = true ]]; then
            in_open=false
        fi

        if [[ "$in_open" = true ]] && echo "$line" | grep -q "^- \[ \]"; then
            local matched=false
            while IFS= read -r mod_file; do
                [[ -z "$mod_file" ]] && continue
                local basename_mod
                basename_mod=$(basename "$mod_file" 2>/dev/null || echo "$mod_file")
                if echo "$line" | grep -q "$basename_mod"; then
                    # shellcheck disable=SC2001
                    echo "$line" | sed 's/^- \[ \]/- [x]/' >> "$tmpfile"
                    matched=true
                    resolved=$((resolved + 1))
                    break
                fi
            done <<< "$modified_files"
            if [[ "$matched" = false ]]; then
                echo "$line" >> "$tmpfile"
            fi
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$nb_file"

    if [[ "$resolved" -gt 0 ]]; then
        mv "$tmpfile" "$nb_file"
        log "Resolved ${resolved} non-blocking note(s) based on modified files."
    else
        rm "$tmpfile"
    fi
}

# =============================================================================
# CLEANUP HELPERS
# =============================================================================

# clear_completed_nonblocking_notes — Removes [x] items from the ## Open section.
# Called at the start of each run so only the current run's completions are visible.
clear_completed_nonblocking_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        return 0
    fi

    # Count [x] items first — skip file rewrite if none exist.
    # Use /^## [^#]/ as section boundary to avoid matching ### subheadings.
    local completed_count
    completed_count=$(awk '/^## Open/{f=1; next} f && /^## [^#]/{exit} f && /^- \[x\]/{c++} END{print c+0}' \
        "$nb_file" 2>/dev/null)
    if [ "$completed_count" -eq 0 ] 2>/dev/null; then
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    local in_open=false

    while IFS= read -r line; do
        if [[ "$line" == "## Open"* ]] && [[ "$line" != "###"* ]]; then
            in_open=true
            echo "$line" >> "$tmpfile"
        elif [[ "$in_open" = true ]] && [[ "$line" == "## "* ]] && [[ "$line" != "###"* ]]; then
            in_open=false
            echo "$line" >> "$tmpfile"
        elif [[ "$in_open" = true ]] && echo "$line" | grep -qi "^- \[x\]"; then
            # Skip completed items
            :
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$nb_file"

    mv "$tmpfile" "$nb_file"
    log "Cleared ${completed_count} completed item(s) from NON_BLOCKING_LOG.md."
}

# get_completed_nonblocking_notes — Returns text of [x] items from ## Open.
# Used to include completed items in the commit message.
get_completed_nonblocking_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        return
    fi
    awk '/^## Open/{f=1; next} f && /^## [^#]/{exit} f && /^- \[x\]/{print}' \
        "$nb_file" 2>/dev/null || true
}

# clear_resolved_nonblocking_notes — Empties the ## Resolved section of
# NON_BLOCKING_LOG.md. Returns the cleared items on stdout for metrics capture.
# Only call on successful pipeline completion. Preserves the ## Resolved heading.
clear_resolved_nonblocking_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        return 0
    fi

    # Count non-blank content lines in ## Resolved section.
    # Use /^## [^#]/ as section boundary to avoid matching ### subheadings.
    local resolved_count
    resolved_count=$(awk '/^## Resolved/{f=1; next} f && /^## [^#]/{exit} f && /[^[:space:]]/{c++} END{print c+0}' \
        "$nb_file" 2>/dev/null)
    if [ "$resolved_count" -eq 0 ] 2>/dev/null; then
        return 0
    fi

    # Extract resolved bullet items for metrics capture (output them before clearing)
    local resolved_items
    resolved_items=$(awk '/^## Resolved/{f=1; next} f && /^## [^#]/{exit} f && /^- /{print}' \
        "$nb_file" 2>/dev/null || true)

    # Output cleared items for caller to capture
    if [ -n "$resolved_items" ]; then
        echo "$resolved_items"
    fi

    # Rewrite file dropping everything in ## Resolved section except the heading.
    # Match section boundary with ^## followed by non-# to avoid matching ### subheadings.
    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    local in_resolved=false

    while IFS= read -r line; do
        if [[ "$line" == "## Resolved"* ]] && [[ "$line" != "###"* ]]; then
            in_resolved=true
            echo "$line" >> "$tmpfile"
        elif [[ "$in_resolved" = true ]] && [[ "$line" == "## "* ]] && [[ "$line" != "###"* ]]; then
            in_resolved=false
            echo "$line" >> "$tmpfile"
        elif [[ "$in_resolved" = true ]]; then
            # Skip all content in the Resolved section (bullets, subheadings, blank lines)
            :
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$nb_file"

    mv "$tmpfile" "$nb_file"
    local count
    count=$(echo "$resolved_items" | wc -l)
    log "Cleared ${count} resolved item(s) from NON_BLOCKING_LOG.md ## Resolved section."
}

