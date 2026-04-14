#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/init_synthesize.sh — Agent-assisted project synthesis (Milestone 21)
#
# Uses $PROJECT_INDEX_FILE + tech stack detection as input to an agent-assisted
# synthesis pipeline that generates ${DESIGN_FILE} and CLAUDE.md for brownfield
# projects. The brownfield equivalent of --plan — reads existing code instead
# of interviewing the user.
#
# Sourced by tekhton.sh when --plan-from-index is passed. Do not run directly.
# Expects: log(), success(), warn(), error(), header() from common.sh
# Expects: render_prompt(), _call_planning_batch() from lib/plan.sh
# Expects: check_context_budget(), measure_context_size() from lib/context.sh
# Expects: compress_context() from lib/context_compiler.sh
# Expects: format_detection_report() from lib/detect_report.sh
# Expects: check_design_completeness() from lib/plan_completeness.sh
#
# Helpers extracted to lib/init_synthesize_helpers.sh:
#   _assemble_synthesis_context, _compress_synthesis_context,
#   _check_synthesis_completeness, _get_section_content_simple
#
# UI functions extracted to lib/init_synthesize_ui.sh:
#   _synthesis_review_menu, _print_synthesis_next_steps
# =============================================================================

# Source helpers from dedicated modules
# shellcheck source=/dev/null
source "${TEKHTON_HOME:-.}/lib/init_synthesize_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME:-.}/lib/init_synthesize_ui.sh"

# --- Config defaults for synthesis -------------------------------------------

export SYNTHESIS_MODEL="${SYNTHESIS_MODEL:-${PLAN_GENERATION_MODEL:-opus}}"
export SYNTHESIS_MAX_TURNS="${SYNTHESIS_MAX_TURNS:-${PLAN_GENERATION_MAX_TURNS:-50}}"

# --- ${DESIGN_FILE} generation ----------------------------------------------------

# _synthesize_design — Generates ${DESIGN_FILE} from project index and detection.
#
# Args: $1 = project directory
# Returns: 0 if ${DESIGN_FILE} was produced, 1 otherwise
_synthesize_design() {
    local project_dir="$1"
    local log_dir="${project_dir}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_synthesize-design.log"

    mkdir -p "$log_dir"

    # Render the synthesis prompt
    local prompt
    prompt=$(render_prompt "init_synthesize_design")

    header "${DESIGN_FILE:-DESIGN.md} Synthesis"
    log "Model: ${SYNTHESIS_MODEL}"
    log "Max turns: ${SYNTHESIS_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Synthesizing ${DESIGN_FILE:-DESIGN.md} from project index..."

    # Write session metadata to log
    {
        echo "=== Tekhton Project Synthesis (${DESIGN_FILE}) ==="
        echo "Date: $(date)"
        echo "Model: ${SYNTHESIS_MODEL}"
        echo "Max Turns: ${SYNTHESIS_MAX_TURNS}"
        echo "=== Session Start ==="
    } > "$log_file"

    local design_content=""
    local batch_exit=0
    design_content=$(_call_planning_batch \
        "$SYNTHESIS_MODEL" \
        "$SYNTHESIS_MAX_TURNS" \
        "$prompt" \
        "$log_file") || batch_exit=$?

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    # Trim preamble lines before the first top-level heading.
    if [[ -n "$design_content" ]]; then
        design_content=$(printf '%s' "$design_content" | _trim_document_preamble)
    fi

    if [[ -n "$design_content" ]]; then
        local design_file="${project_dir}/${DESIGN_FILE}"
        printf '%s\n' "$design_content" > "$design_file"
        local line_count
        line_count=$(wc -l < "$design_file" | tr -d '[:space:]')
        success "${DESIGN_FILE} synthesized (${line_count} lines)."
        return 0
    else
        warn "Synthesis produced no output — ${DESIGN_FILE} was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        return 1
    fi
}

# --- CLAUDE.md generation ----------------------------------------------------

# _synthesize_claude — Generates CLAUDE.md from ${DESIGN_FILE} and project index.
#
# Args: $1 = project directory
# Returns: 0 if CLAUDE.md was produced, 1 otherwise
_synthesize_claude() {
    local project_dir="$1"
    local design_file="${project_dir}/${DESIGN_FILE}"

    if [[ ! -f "$design_file" ]]; then
        error "${DESIGN_FILE} not found at ${design_file} — cannot generate CLAUDE.md."
        return 1
    fi

    local log_dir="${project_dir}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_synthesize-claude.log"

    mkdir -p "$log_dir"

    # Set DESIGN_CONTENT for the prompt
    export DESIGN_CONTENT
    DESIGN_CONTENT=$(cat "$design_file")

    # Render the CLAUDE.md synthesis prompt
    local prompt
    prompt=$(render_prompt "init_synthesize_claude")

    header "CLAUDE.md Synthesis"
    log "Model: ${SYNTHESIS_MODEL}"
    log "Max turns: ${SYNTHESIS_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Generating CLAUDE.md from ${DESIGN_FILE} + project index..."

    {
        echo "=== Tekhton Project Synthesis (CLAUDE.md) ==="
        echo "Date: $(date)"
        echo "Model: ${SYNTHESIS_MODEL}"
        echo "Max Turns: ${SYNTHESIS_MAX_TURNS}"
        echo "=== Session Start ==="
    } > "$log_file"

    local claude_content=""
    local batch_exit=0
    claude_content=$(_call_planning_batch \
        "$SYNTHESIS_MODEL" \
        "$SYNTHESIS_MAX_TURNS" \
        "$prompt" \
        "$log_file") || batch_exit=$?

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    # Trim preamble lines before the first top-level heading.
    if [[ -n "$claude_content" ]]; then
        claude_content=$(printf '%s' "$claude_content" | _trim_document_preamble)
    fi

    if [[ -n "$claude_content" ]]; then
        local claude_file="${project_dir}/CLAUDE.md"
        printf '%s\n' "$claude_content" > "$claude_file"
        # Append tekhton-managed marker for artifact detection (idempotency guard)
        if ! grep -q '<!-- tekhton-managed -->' "$claude_file"; then
            echo "<!-- tekhton-managed -->" >> "$claude_file"
        fi
        local line_count
        line_count=$(wc -l < "$claude_file" | tr -d '[:space:]')
        success "CLAUDE.md synthesized (${line_count} lines)."
        return 0
    else
        warn "Generation produced no output — CLAUDE.md was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        return 1
    fi
}

# --- Main entry point --------------------------------------------------------

# run_project_synthesis — Main entry point for --plan-from-index.
#
# Phases:
#   1. Context assembly (load index, detection, README, etc.)
#   2. ${DESIGN_FILE} generation
#   3. Completeness check + optional re-synthesis
#   4. CLAUDE.md generation
#   5. Human review menu
#
# Args: $1 = project directory
# Returns: 0 on success, 1 on failure or abort
run_project_synthesis() {
    local project_dir="${1:-${PROJECT_DIR:-.}}"

    header "Tekhton — Project Synthesis"
    log "Synthesizing ${DESIGN_FILE} and CLAUDE.md from project index."
    log "Model: ${SYNTHESIS_MODEL} | Max turns: ${SYNTHESIS_MAX_TURNS}"
    echo

    # Phase 1: Context assembly
    log "Phase 1: Assembling context..."
    _assemble_synthesis_context "$project_dir" || return 1

    # Phase 2: ${DESIGN_FILE} generation
    echo
    log "Phase 2: Generating ${DESIGN_FILE}..."
    _synthesize_design "$project_dir" || return 1

    # Phase 3: Completeness check
    echo
    log "Phase 3: Checking ${DESIGN_FILE} completeness..."
    _check_synthesis_completeness "$project_dir"

    # Phase 4: CLAUDE.md generation
    echo
    log "Phase 4: Generating CLAUDE.md..."
    _synthesize_claude "$project_dir" || return 1

    # Phase 5: Human review
    echo
    _synthesis_review_menu "$project_dir"
}
