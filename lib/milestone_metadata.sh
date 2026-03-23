#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_metadata.sh — Milestone metadata emission and pipeline attempt logging
#
# Sourced by tekhton.sh — do not run directly.
# Expects: milestones.sh, milestone_ops.sh sourced first
# Expects: log(), warn() from common.sh
# Expects: PROJECT_RULES_FILE from config
#
# Provides:
#   emit_milestone_metadata    — write/update HTML metadata comment in CLAUDE.md
#   record_pipeline_attempt    — log attempt outcome for progress detection
# =============================================================================

# --- Milestone metadata comments -----------------------------------------------
#
# Writes an HTML comment block immediately after a milestone heading in CLAUDE.md.
# Format:
#   <!-- milestone-meta
#   id: "16"
#   depends_on: ["15.3", "15.4"]
#   seeds_forward: ["17", "18"]
#   estimated_complexity: "large"
#   status: "in_progress"
#   -->
#
# Idempotent: if a <!-- milestone-meta block already exists after the heading,
# it is replaced rather than duplicated.

# emit_milestone_metadata MILESTONE_NUM STATUS [CLAUDE_MD_PATH]
# STATUS: "pending", "in_progress", "done"
# In DAG mode, writes metadata into the milestone file instead of CLAUDE.md.
emit_milestone_metadata() {
    local milestone_num="$1"
    local status="$2"
    local claude_md="${3:-${PROJECT_RULES_FILE:-CLAUDE.md}}"

    # DAG path: write metadata into milestone file
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        local id
        id=$(dag_number_to_id "$milestone_num")
        local file
        file=$(dag_get_file "$id" 2>/dev/null) || true
        if [[ -z "$file" ]]; then
            warn "emit_milestone_metadata: no file for milestone ${milestone_num}"
            return 1
        fi
        local milestone_dir
        milestone_dir=$(_dag_milestone_dir)
        local filepath="${milestone_dir}/${file}"
        if [[ ! -f "$filepath" ]]; then
            warn "emit_milestone_metadata: ${filepath} not found"
            return 1
        fi

        # Also update manifest status
        dag_set_status "$id" "$status"
        save_manifest

        local meta_block
        meta_block="<!-- milestone-meta
id: \"${milestone_num}\"
status: \"${status}\"
-->"

        # Check if meta block already exists in the file
        if grep -q '^<!-- milestone-meta' "$filepath" 2>/dev/null; then
            # Replace existing meta block
            local tmpfile
            tmpfile=$(mktemp)
            awk -v meta="$meta_block" '
            /^<!-- milestone-meta/ { in_meta = 1; next }
            in_meta && /^-->/ { in_meta = 0; print meta; next }
            in_meta { next }
            { print }
            ' "$filepath" > "$tmpfile"
            mv "$tmpfile" "$filepath"
        else
            # Insert after the first heading line
            local tmpfile
            tmpfile=$(mktemp)
            awk -v meta="$meta_block" '
            !inserted && /^#{1,5}[[:space:]]/ {
                print
                print meta
                print ""
                inserted = 1
                next
            }
            { print }
            ' "$filepath" > "$tmpfile"
            mv "$tmpfile" "$filepath"
        fi

        log "Milestone ${milestone_num} metadata updated in ${file}: status=${status}"
        return 0
    fi

    # Inline path: original CLAUDE.md behavior
    if [[ ! -f "$claude_md" ]]; then
        warn "emit_milestone_metadata: ${claude_md} not found"
        return 1
    fi

    # Escape dots in milestone number for regex
    local num_pattern="${milestone_num//./\\.}"

    # Check heading exists
    if ! grep -qE "^#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?[Mm]ilestone[[:space:]]+${num_pattern}[[:space:]]*[:.\—\-]" "$claude_md" 2>/dev/null; then
        warn "emit_milestone_metadata: Milestone ${milestone_num} not found in ${claude_md}"
        return 1
    fi

    # Estimate complexity from acceptance criteria count and file list length
    local complexity="medium"
    local criteria_count=0
    local file_count=0
    local in_milestone=false
    local in_acceptance=false
    local in_files=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^#{1,5}[[:space:]]*(\[DONE\][[:space:]]*)?[Mm]ilestone[[:space:]]+${num_pattern}[[:space:]]*[:.\—\-] ]]; then
            in_milestone=true
            continue
        fi
        if [[ "$in_milestone" = true ]] && [[ "$line" =~ ^#{1,4}[[:space:]] ]] && [[ ! "$line" =~ ^#{5,} ]]; then
            break
        fi
        if [[ "$in_milestone" = true ]]; then
            if [[ "$line" =~ [Aa]cceptance[[:space:]]+[Cc]riteria ]]; then
                in_acceptance=true
                in_files=false
            elif [[ "$line" =~ [Ff]iles[[:space:]]+to[[:space:]]+(modify|create) ]]; then
                in_files=true
                in_acceptance=false
            elif [[ "$line" =~ ^#{5,}[[:space:]] ]] || [[ "$line" =~ ^\*\*[A-Z] ]]; then
                in_acceptance=false
                in_files=false
            fi
            if [[ "$in_acceptance" = true ]] && [[ "$line" =~ ^[[:space:]]*[-*][[:space:]] ]]; then
                criteria_count=$((criteria_count + 1))
            fi
            if [[ "$in_files" = true ]] && [[ "$line" =~ ^[[:space:]]*[-*][[:space:]] ]]; then
                file_count=$((file_count + 1))
            fi
        fi
    done < "$claude_md"

    if [[ "$criteria_count" -le 3 ]] && [[ "$file_count" -le 2 ]]; then
        complexity="small"
    elif [[ "$criteria_count" -le 8 ]] && [[ "$file_count" -le 5 ]]; then
        complexity="medium"
    else
        complexity="large"
    fi

    # Build the metadata block
    local meta_block
    meta_block=$(cat <<METAEOF
<!-- milestone-meta
id: "${milestone_num}"
estimated_complexity: "${complexity}"
status: "${status}"
-->
METAEOF
)

    # Use awk to insert or replace the metadata block
    local tmpfile
    tmpfile=$(mktemp)

    awk -v num_pat="$num_pattern" -v meta="$meta_block" '
    BEGIN { found_heading = 0; in_meta = 0; meta_replaced = 0 }
    {
        # Match milestone heading
        if (match($0, "^#{1,5}[[:space:]]*" "(\\[DONE\\][[:space:]]*)?" "[Mm]ilestone[[:space:]]+" num_pat "[[:space:]]*[:.\342\200\224\\-]") ||
            ($0 ~ ("^#{1,5} *(\\[DONE\\] *)?[Mm]ilestone +" num_pat "[ ]*[:.\\-]"))) {
            found_heading = 1
            print
            next
        }

        # If we just printed the heading, check for existing meta block
        if (found_heading == 1) {
            if ($0 ~ /^<!-- milestone-meta/) {
                in_meta = 1
                found_heading = 0
                next
            }
            # No existing meta — insert new block
            print meta
            print ""
            found_heading = 0
            meta_replaced = 1
            print
            next
        }

        # Skip existing meta block lines
        if (in_meta == 1) {
            if ($0 ~ /^-->/) {
                in_meta = 0
                meta_replaced = 1
                # Print replacement meta
                print meta
            }
            next
        }

        print
    }
    ' "$claude_md" > "$tmpfile"

    mv "$tmpfile" "$claude_md"
    log "Milestone ${milestone_num} metadata updated: status=${status}, complexity=${complexity}"
}

# --- Pipeline attempt recording ------------------------------------------------
#
# record_pipeline_attempt MILESTONE_NUM ATTEMPT OUTCOME TURNS_USED FILES_CHANGED
# Logs attempt metadata to an in-memory variable for the progress detector and
# metrics. Each call appends to _ORCH_ATTEMPT_LOG (exported for state persistence).

record_pipeline_attempt() {
    local milestone_num="$1"
    local attempt="$2"
    local outcome="$3"
    local turns_used="$4"
    local files_changed="$5"

    local entry="- Attempt ${attempt}: ${outcome} (${turns_used} turns, ${files_changed} files changed)"
    if [[ -n "${_ORCH_ATTEMPT_LOG:-}" ]]; then
        _ORCH_ATTEMPT_LOG="${_ORCH_ATTEMPT_LOG}
${entry}"
    else
        _ORCH_ATTEMPT_LOG="${entry}"
    fi
    export _ORCH_ATTEMPT_LOG

    log "Pipeline attempt ${attempt}: ${outcome} (${turns_used} turns, ${files_changed} files)"
}
