#!/usr/bin/env bash
# =============================================================================
# drift.sh — Drift log, Architecture Decision Log, and Human Action management
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PROJECT_DIR, DRIFT_LOG_FILE, ARCHITECTURE_LOG_FILE,
#          HUMAN_ACTION_FILE, DRIFT_OBSERVATION_THRESHOLD,
#          DRIFT_RUNS_SINCE_AUDIT_THRESHOLD, TASK (set by caller/config)
# =============================================================================

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

    awk -v date="$date_tag" -v task="$task_desc" -v obs="$observations" '
    /^## Unresolved Observations/ {
        print
        # Split observations into lines and format each
        n = split(obs, lines, "\n")
        for (i = 1; i <= n; i++) {
            line = lines[i]
            # Strip leading "- " if present, skip empty lines
            gsub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/^[[:space:]]+/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            if (length(line) > 0 && line != "None") {
                printf "- [%s | \"%s\"] %s\n", date, task, line
            }
        }
        next
    }
    { print }
    ' "$drift_file" > "$tmpfile"

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
    local in_resolved=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "^## Unresolved Observations"; then
            in_unresolved=1
            in_resolved=0
            echo "$line" >> "$tmpfile"
        elif echo "$line" | grep -q "^## Resolved"; then
            in_unresolved=0
            in_resolved=1
            echo "$line" >> "$tmpfile"
            # Append newly resolved lines here
            if [ -n "$resolved_lines" ]; then
                echo "$resolved_lines" >> "$tmpfile"
            fi
        elif [ "$in_unresolved" -eq 1 ] && echo "$line" | grep -qE "$combined_pattern"; then
            # This line matches — save for resolved section
            local stripped
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
    max=$(grep -oE 'ADL-[0-9]+' "$adl_file" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    if [ -z "$max" ]; then
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
    count=$(grep -c "^- \[ \]" "$action_file" 2>/dev/null || echo "0")
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

    # 4. Increment the runs-since-audit counter
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
