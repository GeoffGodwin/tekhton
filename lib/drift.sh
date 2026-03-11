#!/usr/bin/env bash
# =============================================================================
# drift.sh — Drift log, Architecture Decision Log, and Human Action management
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PROJECT_DIR, DRIFT_LOG_FILE, ARCHITECTURE_LOG_FILE,
#          HUMAN_ACTION_FILE, DRIFT_OBSERVATION_THRESHOLD,
#          DRIFT_RUNS_SINCE_AUDIT_THRESHOLD, TASK (set by caller/config)
# =============================================================================

# --- Shared AWK helper -------------------------------------------------------

# _awk_join_bullets — AWK program that parses markdown bullet lists, joins
# continuation lines, and inserts formatted entries after a target section header.
# Args: $1 = section_regex  $2 = printf_format (for date, task, note)
# Returns the AWK program text. Caller passes -v date=... -v task=... -v input=...
_awk_join_bullets() {
    local section_regex="$1"
    local line_format="$2"
    cat <<AWKEOF
${section_regex} {
    print
    n = split(input, lines, "\\n")
    note = ""
    for (i = 1; i <= n; i++) {
        line = lines[i]
        gsub(/[[:space:]]+\$/, "", line)
        if (length(line) == 0) continue
        if (match(line, /^[[:space:]]*-[[:space:]]*/)) {
            if (length(note) > 0 && tolower(note) != "none") {
                printf "${line_format}\\n", date, task, note
            }
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/^[[:space:]]+/, "", line)
            note = line
        } else {
            gsub(/^[[:space:]]+/, "", line)
            if (length(note) > 0) {
                note = note " " line
            } else {
                note = line
            }
        }
    }
    if (length(note) > 0 && tolower(note) != "none") {
        printf "${line_format}\\n", date, task, note
    }
    next
}
{ print }
AWKEOF
}

# --- Drift Log ---------------------------------------------------------------

# _ensure_drift_log — Creates DRIFT_LOG.md with initial structure if missing.
_ensure_drift_log() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        cat > "$drift_file" << 'EOF'
# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 0

## Unresolved Observations

## Resolved
EOF
    fi
}

# append_drift_observations — Reads reviewer report's drift section, appends to log.
# Skips if section contains only "None" or is absent.
append_drift_observations() {
    local reviewer_report="${PROJECT_DIR}/REVIEWER_REPORT.md"
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"

    if [ ! -f "$reviewer_report" ]; then
        return 0
    fi

    # Extract drift observations section
    local observations
    observations=$(awk '/^## Drift Observations/{found=1; next} found && /^##/{exit} found{print}' \
        "$reviewer_report" 2>/dev/null || true)

    # Skip if empty or only "None"
    if [ -z "$observations" ] || echo "$observations" | grep -qE '^\s*-?\s*None\s*$'; then
        return 0
    fi

    _ensure_drift_log

    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local task_desc="${TASK:-unknown}"

    # Append each observation bullet to the Unresolved section
    local tmpfile
    tmpfile=$(mktemp)

    local awk_prog
    awk_prog=$(_awk_join_bullets \
        '/^## Unresolved Observations/' \
        '- [%s | \"%s\"] %s')

    awk -v date="$date_tag" -v task="$task_desc" -v input="$observations" \
        "$awk_prog" "$drift_file" > "$tmpfile"

    mv "$tmpfile" "$drift_file"
}

# count_drift_observations — Returns count of unresolved observations.
count_drift_observations() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        echo "0"
        return
    fi
    local count
    count=$(awk '/^## Unresolved Observations/{found=1; next} found && /^##/{exit} found && /^- \[/{count++} END{print count+0}' \
        "$drift_file" 2>/dev/null)
    echo "$count"
}

# resolve_drift_observations — Marks matching observations as resolved.
# Usage: resolve_drift_observations "pattern1" "pattern2" ...
# Moves lines matching any pattern from Unresolved to Resolved.
resolve_drift_observations() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return 0
    fi

    local date_tag
    date_tag=$(date +%Y-%m-%d)

    local tmpfile
    tmpfile=$(mktemp)
    local resolved_lines=""

    # Collect patterns into a single grep -E pattern
    local combined_pattern=""
    for pattern in "$@"; do
        if [ -n "$combined_pattern" ]; then
            combined_pattern="${combined_pattern}|${pattern}"
        else
            combined_pattern="$pattern"
        fi
    done

    if [ -z "$combined_pattern" ]; then
        return 0
    fi

    # Process file: move matching unresolved lines to resolved section
    local in_unresolved=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "^## Unresolved Observations"; then
            in_unresolved=1
            echo "$line" >> "$tmpfile"
        elif echo "$line" | grep -q "^## Resolved"; then
            in_unresolved=0
            echo "$line" >> "$tmpfile"
            # Append newly resolved lines here
            if [ -n "$resolved_lines" ]; then
                echo "$resolved_lines" >> "$tmpfile"
            fi
        elif [ "$in_unresolved" -eq 1 ] && echo "$line" | grep -qE "$combined_pattern"; then
            # This line matches — save for resolved section
            local stripped
            # shellcheck disable=SC2001
            stripped=$(echo "$line" | sed 's/^- \[[^]]*\] //')
            resolved_lines="${resolved_lines}
- [RESOLVED ${date_tag}] ${stripped}"
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$drift_file"

    mv "$tmpfile" "$drift_file"
}

# get_runs_since_audit — Returns the run counter from drift log metadata.
get_runs_since_audit() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        echo "0"
        return
    fi
    local count
    count=$(grep -m1 "Runs since audit:" "$drift_file" 2>/dev/null | grep -oE '[0-9]+' || echo "0")
    # Defensive: ensure count is numeric (guards against corrupted drift files)
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        count="0"
    fi
    echo "$count"
}

# increment_runs_since_audit — Bumps the run counter by 1.
increment_runs_since_audit() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    _ensure_drift_log

    local current
    current=$(get_runs_since_audit)
    local new_count=$((current + 1))

    local tmpfile
    tmpfile=$(mktemp)
    sed "s/Runs since audit: ${current}/Runs since audit: ${new_count}/" "$drift_file" > "$tmpfile"
    mv "$tmpfile" "$drift_file"
}

# reset_runs_since_audit — Resets counter to 0 and updates last audit date.
reset_runs_since_audit() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return 0
    fi

    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local current
    current=$(get_runs_since_audit)

    local tmpfile
    tmpfile=$(mktemp)
    sed -e "s/Runs since audit: ${current}/Runs since audit: 0/" \
        -e "s/Last audit: .*/Last audit: ${date_tag}/" \
        "$drift_file" > "$tmpfile"
    mv "$tmpfile" "$drift_file"
}

# should_trigger_audit — Returns 0 (true) if audit threshold is reached.
should_trigger_audit() {
    local obs_count
    obs_count=$(count_drift_observations)
    local runs_count
    runs_count=$(get_runs_since_audit)

    if [ "$obs_count" -ge "$DRIFT_OBSERVATION_THRESHOLD" ] 2>/dev/null; then
        return 0
    fi
    if [ "$runs_count" -ge "$DRIFT_RUNS_SINCE_AUDIT_THRESHOLD" ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- Architecture Decision Log -----------------------------------------------

# _ensure_adl — Creates ARCHITECTURE_LOG.md with initial structure if missing.
_ensure_adl() {
    local adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE}"
    if [ ! -f "$adl_file" ]; then
        cat > "$adl_file" << 'EOF'
# Architecture Decision Log

Accepted Architecture Change Proposals are recorded here for institutional memory.
Each entry captures why a structural change was made, preventing future developers
(or agents) from reverting to the old approach without understanding the context.
EOF
    fi
}

# get_next_adl_number — Returns the next sequential ADL number.
get_next_adl_number() {
    local adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE}"
    if [ ! -f "$adl_file" ]; then
        echo "1"
        return
    fi
    local max
    max=$(grep -oE 'ADL-[0-9]+' "$adl_file" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || true)
    if [ -z "$max" ] || ! [[ "$max" =~ ^[0-9]+$ ]]; then
        echo "1"
    else
        echo "$((max + 1))"
    fi
}

# append_architecture_decision — Records accepted ACPs from reviewer report.
# Reads the ACCEPTED_ACPS global (set by review.sh) and the coder summary.
append_architecture_decision() {
    if [ -z "${ACCEPTED_ACPS:-}" ]; then
        return 0
    fi

    _ensure_adl

    local adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE}"
    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local task_desc="${TASK:-unknown}"

    # Parse each accepted ACP line and create an ADL entry
    while IFS= read -r acp_line; do
        [ -z "$acp_line" ] && continue

        local adl_num
        adl_num=$(get_next_adl_number)

        # Extract ACP name from format: "- ACP: [name] — ACCEPT — [rationale]"
        local acp_name
        acp_name=$(echo "$acp_line" | sed 's/^.*ACP: //' | sed 's/ — .*//' | sed 's/^[[:space:]]*//' | head -c 80)

        local rationale
        rationale=$(echo "$acp_line" | sed 's/.*ACCEPT[[:space:]]*—[[:space:]]*//' | head -c 200)

        cat >> "$adl_file" << EOF

## ADL-${adl_num}: ${acp_name} (Task: "${task_desc}")
- **Date**: ${date_tag}
- **Rationale**: ${rationale}
- **Source**: Accepted ACP from pipeline run
EOF
    done <<< "$ACCEPTED_ACPS"
}

# --- Human Action Required ---------------------------------------------------

# _ensure_human_action — Creates HUMAN_ACTION_REQUIRED.md if missing.
_ensure_human_action() {
    local action_file="${PROJECT_DIR}/${HUMAN_ACTION_FILE}"
    if [ ! -f "$action_file" ]; then
        cat > "$action_file" << 'EOF'
# Human Action Required

The pipeline identified items that need your attention. Review each item
and check it off when addressed. The pipeline will display a banner until
all items are resolved.

## Action Items
EOF
    fi
}

# append_human_action — Adds an item to HUMAN_ACTION_REQUIRED.md.
# Usage: append_human_action "source_label" "description"
append_human_action() {
    local source="$1"
    local description="$2"

    _ensure_human_action

    local action_file="${PROJECT_DIR}/${HUMAN_ACTION_FILE}"
    local date_tag
    date_tag=$(date +%Y-%m-%d)

    echo "- [ ] [${date_tag} | Source: ${source}] ${description}" >> "$action_file"
}

# count_human_actions — Returns count of unchecked action items.
count_human_actions() {
    local action_file="${PROJECT_DIR}/${HUMAN_ACTION_FILE}"
    if [ ! -f "$action_file" ]; then
        echo "0"
        return
    fi
    local count
    count=$(grep -c "^- \[ \]" "$action_file" 2>/dev/null) || count="0"
    count=$(echo "$count" | tr -d '[:space:]')
    echo "$count"
}

# has_human_actions — Returns 0 (true) if unchecked items exist.
has_human_actions() {
    local count
    count=$(count_human_actions)
    [ "$count" -gt 0 ]
}

# --- Post-pipeline drift processing -----------------------------------------

# process_drift_artifacts — Called after pipeline completion to process all
# drift-related outputs from the run. This is the main integration point.
# Reads reviewer report + coder summary and updates drift log, ADL, and
# human action file as needed.
process_drift_artifacts() {
    # 1. Append drift observations from reviewer report
    append_drift_observations

    # 2. Record accepted ACPs in the Architecture Decision Log
    append_architecture_decision

    # 3. Extract design observations from coder summary → human action items
    _process_design_observations

    # 4. Accumulate non-blocking notes from reviewer report
    append_nonblocking_notes

    # 5. Mark addressed non-blocking notes from coder summary
    _resolve_addressed_nonblocking_notes

    # 6. Increment the runs-since-audit counter
    increment_runs_since_audit
}

# _process_design_observations — Reads CODER_SUMMARY.md for design observations
# and adds them to HUMAN_ACTION_REQUIRED.md.
_process_design_observations() {
    local summary="${PROJECT_DIR}/CODER_SUMMARY.md"
    if [ ! -f "$summary" ]; then
        return 0
    fi

    local observations
    observations=$(awk '/^## Design Observations/{found=1; next} found && /^##/{exit} found{print}' \
        "$summary" 2>/dev/null || true)

    if [ -z "$observations" ] || echo "$observations" | grep -qE '^\s*$'; then
        return 0
    fi

    # Each observation line becomes a human action item
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^[[:space:]]*//')
        [ -z "$line" ] && continue
        append_human_action "coder" "$line"
    done <<< "$observations"
}

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
    tmpfile=$(mktemp)

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
    count=$(awk '/^## Open/{found=1; next} found && /^##/{exit} found && /^- \[ \]/{count++} END{print count+0}' \
        "$nb_file" 2>/dev/null)
    echo "$count"
}

# get_open_nonblocking_notes — Returns the text of all open notes.
get_open_nonblocking_notes() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        return
    fi
    awk '/^## Open/{found=1; next} found && /^##/{exit} found && /^- \[ \]/{print}' \
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
    tmpfile=$(mktemp)
    local resolved=0
    local in_open=false

    while IFS= read -r line; do
        if echo "$line" | grep -q "^## Open"; then
            in_open=true
            echo "$line" >> "$tmpfile"
            continue
        elif echo "$line" | grep -q "^## " && [ "$in_open" = true ]; then
            in_open=false
        fi

        if [ "$in_open" = true ] && echo "$line" | grep -q "^- \[ \]"; then
            local matched=false
            while IFS= read -r mod_file; do
                [ -z "$mod_file" ] && continue
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
            if [ "$matched" = false ]; then
                echo "$line" >> "$tmpfile"
            fi
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$nb_file"

    if [ "$resolved" -gt 0 ]; then
        mv "$tmpfile" "$nb_file"
        log "Resolved ${resolved} non-blocking note(s) based on modified files."
    else
        rm "$tmpfile"
    fi
}
