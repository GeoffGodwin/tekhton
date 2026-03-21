#!/usr/bin/env bash
# =============================================================================
# drift_artifacts.sh — Architecture Decision Log, Human Action, and post-pipeline
#                      drift processing
#
# Extracted from drift.sh to keep file sizes under the 300-line ceiling.
# Sourced by tekhton.sh after drift.sh and drift_cleanup.sh — do not run directly.
# Expects: PROJECT_DIR, ARCHITECTURE_LOG_FILE, HUMAN_ACTION_FILE, TASK,
#          TEKHTON_SESSION_DIR (set by caller/config)
# Uses: append_drift_observations(), increment_runs_since_audit() from drift.sh
# Uses: append_nonblocking_notes(), _resolve_addressed_nonblocking_notes()
#       from drift_cleanup.sh
# Also provides: clear_resolved_drift_observations(), get_resolved_drift_observations()
# =============================================================================

set -euo pipefail

# --- Architecture Decision Log -----------------------------------------------

# _ensure_adl — Creates ARCHITECTURE_LOG.md with initial structure if missing.
_ensure_adl() {
    local adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE}"
    if [[ ! -f "$adl_file" ]]; then
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
    if [[ ! -f "$adl_file" ]]; then
        echo "1"
        return
    fi
    local max
    max=$(grep -oE 'ADL-[0-9]+' "$adl_file" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || true)
    if [[ -z "$max" ]] || ! [[ "$max" =~ ^[0-9]+$ ]]; then
        echo "1"
    else
        echo "$((max + 1))"
    fi
}

# append_architecture_decision — Records accepted ACPs from reviewer report.
# Reads the ACCEPTED_ACPS global (set by review.sh) and the coder summary.
append_architecture_decision() {
    if [[ -z "${ACCEPTED_ACPS:-}" ]]; then
        return 0
    fi

    _ensure_adl

    local adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE}"
    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local task_desc="${TASK:-unknown}"

    # Parse each accepted ACP line and create an ADL entry
    while IFS= read -r acp_line; do
        [[ -z "$acp_line" ]] && continue

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
    if [[ ! -f "$action_file" ]]; then
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
    if [[ ! -f "$action_file" ]]; then
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
    [[ "$count" -gt 0 ]]
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
    if [[ ! -f "$summary" ]]; then
        return 0
    fi

    local observations
    observations=$(awk '/^## Design Observations/{found=1; next} found && /^##/{exit} found{print}' \
        "$summary" 2>/dev/null || true)

    if [[ -z "$observations" ]] || echo "$observations" | grep -qE '^\s*$'; then
        return 0
    fi

    # Each observation line becomes a human action item (filter non-actionable)
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^[[:space:]]*//')
        [[ -z "$line" ]] && continue
        # Skip placeholder / no-action lines
        echo "$line" | grep -qiE '^None\b' && continue
        echo "$line" | grep -qiE '^N/?A\b' && continue
        echo "$line" | grep -qiE '^No (design|doc|observations?|issues?|action|items?)\b' && continue
        echo "$line" | grep -qiE '^(All|No) (drift |design )?(observations?|items?) (are|have been|were)\b' && continue
        echo "$line" | grep -qiE '^Nothing (to|requiring|needs)\b' && continue
        append_human_action "coder" "$line"
    done <<< "$observations"
}

# --- Drift observation cleanup -----------------------------------------------

# clear_resolved_drift_observations — Removes items from the ## Resolved section.
# Called at the start of each run so only the current run's resolutions are visible.
clear_resolved_drift_observations() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return 0
    fi

    # Count resolved items first — skip file rewrite if none exist
    local resolved_count
    resolved_count=$(awk '/^## Resolved/{f=1; next} f && /^##/{exit} f && /^- \[RESOLVED/{c++} END{print c+0}' \
        "$drift_file" 2>/dev/null)
    if [ "$resolved_count" -eq 0 ] 2>/dev/null; then
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    local in_resolved=false

    while IFS= read -r line; do
        if echo "$line" | grep -q "^## Resolved"; then
            in_resolved=true
            echo "$line" >> "$tmpfile"
        elif echo "$line" | grep -q "^## " && [[ "$in_resolved" = true ]]; then
            in_resolved=false
            echo "$line" >> "$tmpfile"
        elif [[ "$in_resolved" = true ]] && echo "$line" | grep -q "^- \[RESOLVED"; then
            # Skip resolved items
            :
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$drift_file"

    mv "$tmpfile" "$drift_file"
    log "Cleared ${resolved_count} resolved item(s) from DRIFT_LOG.md."
}

# get_resolved_drift_observations — Returns text of [RESOLVED ...] items from ## Resolved.
# Used to include resolved drift items in the commit message.
get_resolved_drift_observations() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return
    fi
    awk '/^## Resolved/{f=1; next} f && /^##/{exit} f && /^- \[RESOLVED/{print}' \
        "$drift_file" 2>/dev/null || true
}
