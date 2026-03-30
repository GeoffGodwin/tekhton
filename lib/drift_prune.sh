#!/usr/bin/env bash
# =============================================================================
# drift_prune.sh — Drift log resolved entry pruning
#
# Periodically archives old resolved entries from DRIFT_LOG.md to prevent
# unbounded growth. Called by reset_runs_since_audit() in drift.sh post-audit.
# Sourced by tekhton.sh after drift_cleanup.sh — do not run directly.
# Expects: PROJECT_DIR, DRIFT_LOG_FILE, DRIFT_RESOLVED_KEEP_COUNT (set by config)
# Expects: TEKHTON_SESSION_DIR (used in mktemp fallback)
# Expects: log() from common.sh
# =============================================================================

set -euo pipefail

# prune_resolved_drift_entries — Keeps only N most-recent resolved entries
# in DRIFT_LOG.md, archiving older ones to DRIFT_ARCHIVE.md.
# Preserves the ## Resolved section heading.
# Resolved entries are inserted at the TOP of the section (newest first),
# so head = newest, tail = oldest.
# Default retention: DRIFT_RESOLVED_KEEP_COUNT (typically 20, set in config)
prune_resolved_drift_entries() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return 0
    fi

    local keep_count="${DRIFT_RESOLVED_KEEP_COUNT:-20}"

    # Extract resolved entries (skip the ## Resolved heading)
    local resolved_entries
    resolved_entries=$(awk '/^## Resolved/{found=1; next} found && /^## [^#]/{exit} found && /^- /{print}' \
        "$drift_file" || true)

    if [ -z "$resolved_entries" ]; then
        return 0
    fi

    # Count total entries
    local total_count
    total_count=$(echo "$resolved_entries" | wc -l)

    # If below threshold, nothing to prune
    if [ "$total_count" -le "$keep_count" ]; then
        return 0
    fi

    # Newest entries are at the top (inserted via prepend).
    # Keep the newest (head), archive the oldest (tail).
    local excess_count=$((total_count - keep_count))
    local excess_entries
    excess_entries=$(echo "$resolved_entries" | tail -n "$excess_count")

    local kept_entries
    kept_entries=$(echo "$resolved_entries" | head -n "$keep_count")

    # Append excess to DRIFT_ARCHIVE.md (create if missing)
    local archive_file="${PROJECT_DIR}/DRIFT_ARCHIVE.md"
    if [ ! -f "$archive_file" ]; then
        cat > "$archive_file" << 'EOF'
# Drift Log Archive

Archived resolved drift observations from DRIFT_LOG.md.
Entries are moved here when the resolved section exceeds the configured
retention threshold (DRIFT_RESOLVED_KEEP_COUNT).

## Archived Entries
EOF
    fi

    # Append excess entries to archive
    {
        echo ""
        echo "$excess_entries"
    } >> "$archive_file"

    # Rewrite DRIFT_LOG.md with kept entries only
    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    local in_resolved=false

    while IFS= read -r line; do
        if [[ "$line" == "## Resolved"* ]] && [[ "$line" != "###"* ]]; then
            in_resolved=true
            echo "$line" >> "$tmpfile"
            # Insert kept entries after heading
            if [ -n "$kept_entries" ]; then
                echo "$kept_entries" >> "$tmpfile"
            fi
        elif [[ "$in_resolved" = true ]] && [[ "$line" == "## "* ]] && [[ "$line" != "###"* ]]; then
            in_resolved=false
            echo "$line" >> "$tmpfile"
        elif [[ "$in_resolved" = true ]] && [[ "$line" == "- "* ]]; then
            # Skip old entries (they're now in archive)
            :
        elif [[ "$in_resolved" = true ]] && [[ -z "${line// /}" ]]; then
            # Skip blank lines in resolved section
            :
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$drift_file"

    mv "$tmpfile" "$drift_file"
    log "Pruned ${excess_count} resolved entry(ies) from DRIFT_LOG.md to DRIFT_ARCHIVE.md."
}
