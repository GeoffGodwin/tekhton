#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# draft_milestones_write.sh — Validation and manifest writing for draft milestones
#
# Sourced by draft_milestones.sh — do not run directly.
# Expects: PROJECT_DIR, MILESTONE_DIR, MILESTONE_MANIFEST
# Expects: log(), warn(), error(), success() from common.sh
#
# Provides:
#   draft_milestones_validate_output — validates generated milestone files
#   draft_milestones_write_manifest  — appends rows to MANIFEST.cfg
# =============================================================================

# --- Output validation -------------------------------------------------------

# draft_milestones_validate_output FILE
# Validates a generated milestone file has required structure.
# Returns 0 if valid, 1 if errors found. Errors printed to stderr.
draft_milestones_validate_output() {
    local file="$1"
    local errors=0

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File does not exist: $file" >&2
        return 1
    fi

    # Check H1 heading: # Milestone NN: Title
    if ! grep -qE '^# Milestone [0-9]+:' "$file"; then
        echo "ERROR: Missing H1 heading '# Milestone NN: Title' in $(basename "$file")" >&2
        errors=$((errors + 1))
    fi

    # Check milestone-meta block
    if ! grep -q '<!-- milestone-meta' "$file"; then
        echo "ERROR: Missing <!-- milestone-meta --> block in $(basename "$file")" >&2
        errors=$((errors + 1))
    else
        if ! grep -qE '^\s*id:\s*"[0-9]+"' "$file"; then
            echo "ERROR: Missing or malformed id: in milestone-meta in $(basename "$file")" >&2
            errors=$((errors + 1))
        fi
        if ! grep -qE '^\s*status:\s*"' "$file"; then
            echo "ERROR: Missing status: in milestone-meta in $(basename "$file")" >&2
            errors=$((errors + 1))
        fi
    fi

    # Required sections
    local section
    for section in "Overview" "Design Decisions" "Scope Summary" \
                   "Implementation Plan" "Files Touched" "Negative Space" \
                   "Acceptance Criteria"; do
        if ! grep -qE "^## ${section}" "$file"; then
            echo "ERROR: Missing required section '## ${section}' in $(basename "$file")" >&2
            errors=$((errors + 1))
        fi
    done

    # Acceptance Criteria must have at least 5 items
    local ac_count=0
    local in_ac=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\  ]]; then
            if [[ "$in_ac" = true ]]; then
                break
            fi
            if [[ "$line" =~ ^##\ Acceptance\ Criteria ]]; then
                in_ac=true
            fi
        elif [[ "$in_ac" = true ]] && [[ "$line" =~ ^-\ \[.\] ]]; then
            ac_count=$((ac_count + 1))
        fi
    done < "$file"

    if [[ "$ac_count" -lt 5 ]]; then
        echo "ERROR: Acceptance Criteria has ${ac_count} items (minimum 5) in $(basename "$file")" >&2
        errors=$((errors + 1))
    fi

    # Acceptance criteria quality lint (non-blocking; emitted during authoring
    # so warnings are actionable before the milestone is run). See
    # lib/milestone_acceptance_lint.sh for the rule set.
    if [[ "$errors" -eq 0 ]] && declare -f lint_acceptance_criteria &>/dev/null; then
        local lint_warnings
        lint_warnings=$(lint_acceptance_criteria "$file" 2>/dev/null || true)
        if [[ -n "$lint_warnings" ]]; then
            echo "LINT: $(basename "$file") — acceptance criteria warnings:" >&2
            while IFS= read -r lint_line; do
                [[ -n "$lint_line" ]] && echo "  ${lint_line}" >&2
            done <<< "$lint_warnings"
        fi
    fi

    [[ "$errors" -eq 0 ]]
}

# --- Manifest writer ----------------------------------------------------------

# draft_milestones_write_manifest ID_LIST GROUP
# Appends rows to MANIFEST.cfg for each ID in the space-separated ID_LIST.
# First milestone depends on the highest existing milestone; subsequent ones
# chain linearly. Skips IDs that already have rows (idempotent).
draft_milestones_write_manifest() {
    local id_list="$1"
    local group="${2:-devx}"
    local manifest_path="${PROJECT_DIR}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"

    if [[ ! -f "$manifest_path" ]]; then
        error "MANIFEST.cfg not found at ${manifest_path}"
        return 1
    fi

    # Find highest existing milestone ID for dependency chaining
    local max_existing=0
    local line_id
    while IFS='|' read -r line_id _ || [[ -n "$line_id" ]]; do
        [[ "$line_id" =~ ^#.*$ ]] && continue
        [[ -z "$line_id" ]] && continue
        local num="${line_id#m}"
        if [[ "$num" =~ ^[0-9]+$ ]] && (( 10#$num > max_existing )); then
            max_existing=$((10#$num))
        fi
    done < "$manifest_path"

    local prev_dep="m${max_existing}"
    local added=0
    local id
    for id in $id_list; do
        # Skip if ID already in manifest
        if grep -qE "^m${id}\|" "$manifest_path"; then
            warn "Milestone m${id} already in MANIFEST.cfg, skipping"
            prev_dep="m${id}"
            continue
        fi

        # Find the milestone file to extract title
        local ms_file
        ms_file=$(find "${PROJECT_DIR}/${MILESTONE_DIR}" -name "m${id}-*.md" -print -quit 2>/dev/null || true)
        if [[ -z "$ms_file" ]]; then
            warn "No milestone file found for m${id}, skipping manifest entry"
            continue
        fi

        local fname
        fname=$(basename "$ms_file")
        local title=""
        title=$(grep -oE '^# Milestone [0-9]+: (.+)$' "$ms_file" | sed 's/^# Milestone [0-9]*: //' || true)
        [[ -z "$title" ]] && title="Milestone ${id}"
        title="${title//|/}"

        echo "m${id}|${title}|pending|${prev_dep}|${fname}|${group}" >> "$manifest_path"
        prev_dep="m${id}"
        added=$((added + 1))
    done

    if [[ "$added" -gt 0 ]]; then
        log "Added ${added} milestone(s) to MANIFEST.cfg"
    fi
}
