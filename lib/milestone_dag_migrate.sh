#!/usr/bin/env bash
# =============================================================================
# milestone_dag_migrate.sh — Migrate inline CLAUDE.md milestones to DAG files
#
# Sourced by tekhton.sh — do not run directly.
# Expects: milestone_dag.sh sourced first (provides _dag_manifest_path, etc.)
# Expects: milestones.sh sourced first (provides parse_milestones)
# Expects: milestone_archival_helpers.sh (provides _extract_milestone_block)
# Expects: log(), warn(), success() from common.sh
#
# Provides:
#   migrate_inline_milestones — extract milestones from CLAUDE.md into files
# =============================================================================
set -euo pipefail

# _slugify TEXT
# Converts a title to a filename-safe slug: lowercase, spaces→hyphens,
# strip non-alphanumeric except hyphens.
_slugify() {
    local text="$1"
    text="${text,,}"                          # lowercase
    text="${text// /-}"                       # spaces → hyphens
    text="${text//[^a-z0-9-]/}"              # strip non-alnum
    # Collapse multiple hyphens (loop until stable)
    while [[ "$text" == *--* ]]; do
        text="${text//--/-}"
    done
    text="${text#-}"                          # trim leading hyphen
    text="${text%-}"                          # trim trailing hyphen
    # Truncate to 40 chars for filesystem safety
    echo "${text:0:40}"
}

# _infer_dependencies MILESTONE_BLOCK MILESTONE_NUM ALL_NUMS
# Scans the milestone block text for "depends on Milestone N" references.
# Falls back to sequential dependency (previous milestone) if none found.
# ALL_NUMS is a newline-separated list of milestone numbers in order.
# Outputs comma-separated dependency IDs (e.g., "m01,m02").
_infer_dependencies() {
    local block="$1"
    local num="$2"
    local all_nums="$3"

    local deps=""

    # Look for explicit dependency references
    local dep_num
    while IFS= read -r dep_num; do
        [[ -z "$dep_num" ]] && continue
        local dep_id
        local main_num="${dep_num%%.*}"
        local suffix="${dep_num#"$main_num"}"
        dep_id=$(printf "m%02d%s" "$main_num" "$suffix")
        if [[ -n "$deps" ]]; then
            deps="${deps},${dep_id}"
        else
            deps="$dep_id"
        fi
    done < <(echo "$block" | grep -ioE '[Dd]epends?\s+on\s+[Mm]ilestone\s+([0-9]+([.][0-9]+)*)' | grep -oE '[0-9]+([.][0-9]+)*$' || true)

    # If explicit deps found, use them
    if [[ -n "$deps" ]]; then
        echo "$deps"
        return
    fi

    # Fallback: sequential dependency on previous milestone
    local prev=""
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if [[ "$n" == "$num" ]]; then
            break
        fi
        prev="$n"
    done <<< "$all_nums"

    if [[ -n "$prev" ]]; then
        local main_num="${prev%%.*}"
        local suffix="${prev#"$main_num"}"
        printf "m%02d%s" "$main_num" "$suffix"
    fi
}

# migrate_inline_milestones CLAUDE_MD_PATH MILESTONE_DIR
# Extracts all milestones from a CLAUDE.md file into individual files
# in the milestone directory, and generates a valid MANIFEST.cfg.
# Idempotent: returns 0 immediately if MANIFEST.cfg already exists.
# Returns 0 on success, 1 on failure.
migrate_inline_milestones() {
    local claude_md="${1:-CLAUDE.md}"
    local milestone_dir="${2:-$(_dag_milestone_dir)}"

    local manifest="${milestone_dir}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"

    # Idempotent — skip if manifest already exists
    if [[ -f "$manifest" ]]; then
        log "Manifest already exists at ${manifest} — skipping migration"
        return 0
    fi

    if [[ ! -f "$claude_md" ]]; then
        warn "migrate_inline_milestones: ${claude_md} not found"
        return 1
    fi

    # Parse milestones to get the ordered list
    local milestones_raw
    milestones_raw=$(parse_milestones "$claude_md" 2>/dev/null) || true

    if [[ -z "$milestones_raw" ]]; then
        warn "migrate_inline_milestones: no milestones found in ${claude_md}"
        return 1
    fi

    # Collect all milestone numbers for dependency inference
    local all_nums
    all_nums=$(echo "$milestones_raw" | awk -F'|' '{print $1}')

    # Create milestone directory
    mkdir -p "$milestone_dir"

    # Build manifest header
    local tmpmanifest
    tmpmanifest="$(mktemp "${manifest}.XXXXXX")"
    {
        echo "# Tekhton Milestone Manifest v1"
        echo "# id|title|status|depends_on|file|parallel_group"
    } > "$tmpmanifest"

    local count=0
    while IFS='|' read -r num title _criteria; do
        [[ -z "$num" ]] && continue

        # Generate ID: m{NN} with zero-padding
        local main_num="${num%%.*}"
        local suffix="${num#"$main_num"}"
        local id
        id=$(printf "m%02d%s" "$main_num" "$suffix")

        # Generate filename
        local slug
        slug=$(_slugify "$title")
        local filename="${id}-${slug}.md"

        # Determine status from [DONE] marker
        local status="pending"
        if is_milestone_done "$num" "$claude_md" 2>/dev/null; then
            status="done"
        fi

        # Extract full milestone block
        local block
        block=$(_extract_milestone_block "$num" "$claude_md" 2>/dev/null) || true

        if [[ -z "$block" ]]; then
            # Minimal fallback — create a stub file
            block="#### Milestone ${num}: ${title}"$'\n\n'"(Migrated from ${claude_md} — original content not extractable)"
        fi

        # Infer dependencies
        local deps
        deps=$(_infer_dependencies "$block" "$num" "$all_nums")

        # Write milestone file
        echo "$block" > "${milestone_dir}/${filename}"

        # Append manifest row
        echo "${id}|${title}|${status}|${deps}|${filename}|" >> "$tmpmanifest"

        count=$((count + 1))
    done <<< "$milestones_raw"

    if [[ "$count" -eq 0 ]]; then
        rm -f "$tmpmanifest"
        warn "migrate_inline_milestones: no milestones extracted"
        return 1
    fi

    # Atomic move
    mv -f "$tmpmanifest" "$manifest"

    success "Migrated ${count} milestone(s) to ${milestone_dir}/"
    return 0
}
