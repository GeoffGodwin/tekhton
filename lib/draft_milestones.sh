#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# draft_milestones.sh — Interactive milestone authoring flow
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TEKHTON_HOME, PROJECT_DIR, MILESTONE_DIR, MILESTONE_MANIFEST
# Expects: run_agent() from agent.sh, render_prompt() from prompts.sh
# Expects: log(), warn(), error(), success(), header() from common.sh
#
# Provides:
#   run_draft_milestones          — entry point for --draft-milestones
#   draft_milestones_next_id      — returns next free milestone ID
#   draft_milestones_build_exemplars — assembles exemplar content for prompt
#
# Also sources draft_milestones_write.sh which provides:
#   draft_milestones_validate_output — validates generated milestone files
#   draft_milestones_write_manifest  — appends rows to MANIFEST.cfg
# =============================================================================

# Source validation and manifest writing helpers
# shellcheck source=lib/draft_milestones_write.sh
source "${TEKHTON_HOME}/lib/draft_milestones_write.sh"

# --- Next ID detection -------------------------------------------------------

# draft_milestones_next_id [COUNT]
# Scans MANIFEST.cfg and milestone files to find the highest ID, returns
# max+1. If COUNT is given, prints COUNT consecutive IDs (one per line).
draft_milestones_next_id() {
    local count="${1:-1}"
    local manifest_path="${PROJECT_DIR}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"
    local milestone_dir="${PROJECT_DIR}/${MILESTONE_DIR}"

    local max_id=0

    # Scan MANIFEST.cfg for m<N> entries
    if [[ -f "$manifest_path" ]]; then
        local line_id
        while IFS='|' read -r line_id _ || [[ -n "$line_id" ]]; do
            [[ "$line_id" =~ ^#.*$ ]] && continue
            [[ -z "$line_id" ]] && continue
            local num="${line_id#m}"
            if [[ "$num" =~ ^[0-9]+$ ]] && (( 10#$num > max_id )); then
                max_id=$((10#$num))
            fi
        done < "$manifest_path"
    fi

    # Scan milestone filenames for m<N>-*.md
    if [[ -d "$milestone_dir" ]]; then
        local fname
        for fname in "${milestone_dir}"/m[0-9]*.md; do
            [[ -f "$fname" ]] || continue
            local base
            base=$(basename "$fname")
            local num="${base#m}"
            num="${num%%-*}"
            if [[ "$num" =~ ^[0-9]+$ ]] && (( 10#$num > max_id )); then
                max_id=$((10#$num))
            fi
        done
    fi

    local i
    for (( i = 1; i <= count; i++ )); do
        echo $(( max_id + i ))
    done
}

# --- Exemplar builder ---------------------------------------------------------

# draft_milestones_build_exemplars
# Returns the first 100 lines of the N most recent milestone files as
# format exemplars for the prompt. N = DRAFT_MILESTONES_SEED_EXEMPLARS.
draft_milestones_build_exemplars() {
    local count="${DRAFT_MILESTONES_SEED_EXEMPLARS:-3}"
    local milestone_dir="${PROJECT_DIR}/${MILESTONE_DIR}"
    local exemplars=""

    if [[ ! -d "$milestone_dir" ]]; then
        return
    fi

    # Get the N most recent milestone files by modification time
    local files
    files=$(find "${milestone_dir}" -maxdepth 1 -name 'm[0-9]*.md' -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | head -"$count" | cut -f2- || true)

    [[ -z "$files" ]] && return

    local f
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f")
        exemplars="${exemplars}--- EXEMPLAR: ${base} (first 100 lines) ---
$(head -100 "$f")
--- END EXEMPLAR ---

"
    done <<< "$files"

    printf '%s' "$exemplars"
}

# --- Entry point --------------------------------------------------------------

# run_draft_milestones [SEED_DESCRIPTION]
# Runs the interactive milestone authoring flow:
# 1. Builds prompt with repo context and exemplars
# 2. Invokes agent to clarify, analyze, propose, and generate
# 3. Validates generated files
# 4. Asks for confirmation (unless DRAFT_MILESTONES_AUTO_WRITE=true)
# 5. Writes MANIFEST.cfg rows
run_draft_milestones() {
    local seed="${1:-}"
    local milestone_dir="${PROJECT_DIR}/${MILESTONE_DIR}"
    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_draft-milestones.log"

    mkdir -p "$log_dir" "$milestone_dir"

    header "Draft Milestones — Interactive Authoring"
    log "Model: ${DRAFT_MILESTONES_MODEL}"
    [[ -n "$seed" ]] && log "Seed: ${seed}"

    # Compute next ID and exemplars for the prompt
    local next_id
    next_id=$(draft_milestones_next_id 1)
    export DRAFT_NEXT_MILESTONE_ID="$next_id"

    local exemplar_content
    exemplar_content=$(draft_milestones_build_exemplars)
    export DRAFT_EXEMPLAR_MILESTONES="$exemplar_content"

    export DRAFT_SEED_DESCRIPTION="${seed}"

    # Repo map slice (if available)
    export DRAFT_REPO_MAP_SLICE=""
    if [[ "${REPO_MAP_ENABLED:-false}" = "true" ]] && command -v get_repo_map_slice &>/dev/null; then
        local slice_keywords="${seed:-milestones}"
        DRAFT_REPO_MAP_SLICE=$(get_repo_map_slice "$slice_keywords" 2>/dev/null || true)
    fi

    # Render prompt
    local prompt
    prompt=$(render_prompt "draft_milestones")

    # Invoke agent
    run_agent "Draft Milestones" \
        "${DRAFT_MILESTONES_MODEL}" \
        "${DRAFT_MILESTONES_MAX_TURNS}" \
        "$prompt" \
        "$log_file" \
        "$AGENT_TOOLS_CODER"

    # Discover generated milestone files (new files matching m<next_id+>-*.md)
    local generated_files=()
    local f
    for f in "${milestone_dir}"/m[0-9]*.md; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f")
        local num="${base#m}"
        num="${num%%-*}"
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge "$next_id" ]]; then
            generated_files+=("$f")
        fi
    done

    if [[ ${#generated_files[@]} -eq 0 ]]; then
        warn "No milestone files were generated."
        return 1
    fi

    # Validate all generated files
    log "Validating ${#generated_files[@]} generated milestone file(s)..."
    local validation_errors=0
    local valid_ids=""
    for f in "${generated_files[@]}"; do
        if draft_milestones_validate_output "$f"; then
            success "  PASS: $(basename "$f")"
            local base
            base=$(basename "$f")
            local num="${base#m}"
            num="${num%%-*}"
            valid_ids="${valid_ids} ${num}"
        else
            warn "  FAIL: $(basename "$f")"
            validation_errors=$((validation_errors + 1))
        fi
    done

    if [[ "$validation_errors" -gt 0 ]]; then
        warn "${validation_errors} file(s) failed validation. Files left in place but MANIFEST not updated."
        warn "Fix the files and re-run --draft-milestones to retry."
        return 1
    fi

    # Confirmation gate
    if [[ "${DRAFT_MILESTONES_AUTO_WRITE}" != "true" ]]; then
        echo
        echo "Generated milestone files:"
        for f in "${generated_files[@]}"; do
            echo "  ${f}"
        done
        echo "Will add ${#generated_files[@]} row(s) to MANIFEST.cfg."
        echo
        local confirm=""
        read -r -p "Proceed? [y/N] " confirm < /dev/tty 2>/dev/null || confirm="n"
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log "Aborted. Generated files remain in ${milestone_dir}/ for manual editing."
            return 0
        fi
    fi

    # Write manifest entries
    draft_milestones_write_manifest "$valid_ids" "devx"

    success "Draft milestones complete. ${#generated_files[@]} milestone(s) created."
}
