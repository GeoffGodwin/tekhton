#!/usr/bin/env bash
# =============================================================================
# stages/plan_generate.sh — Planning phase: CLAUDE.md generation
#
# Reads the completed DESIGN.md and generates a full CLAUDE.md with project
# rules, milestone plan, architecture guidelines, and testing strategy.
# Uses _call_planning_batch() — no --dangerously-skip-permissions.
# The shell writes CLAUDE.md to disk.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_GENERATION_MODEL, PLAN_GENERATION_MAX_TURNS, PROJECT_DIR,
#          TEKHTON_HOME
# Expects: log(), success(), warn(), error(), header() from common.sh
# Expects: render_prompt(), _call_planning_batch() from lib/plan.sh
# =============================================================================

# run_plan_generate — Generate CLAUDE.md from DESIGN.md using a batch call.
#
# Reads DESIGN.md, renders the generation prompt, calls _call_planning_batch()
# to get the CLAUDE.md content as text output, and writes it to disk.
# No --dangerously-skip-permissions is used.
#
# Returns 0 if CLAUDE.md was produced, 1 otherwise.
run_plan_generate() {
    local design_file="${PROJECT_DIR}/DESIGN.md"

    if [[ ! -f "$design_file" ]]; then
        error "DESIGN.md not found at ${design_file} — cannot generate CLAUDE.md."
        return 1
    fi

    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_plan-generate.log"

    mkdir -p "$log_dir"

    # Set template variables for prompt rendering
    export DESIGN_CONTENT
    DESIGN_CONTENT=$(cat "$design_file")

    # Render the generation prompt
    local prompt
    prompt=$(render_prompt "plan_generate")

    header "CLAUDE.md Generation"
    log "Model: ${PLAN_GENERATION_MODEL}"
    log "Max turns: ${PLAN_GENERATION_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Generating CLAUDE.md from DESIGN.md..."

    # Write session metadata to log
    {
        echo "=== Tekhton Plan Generation ==="
        echo "Date: $(date)"
        echo "Model: ${PLAN_GENERATION_MODEL}"
        echo "Max Turns: ${PLAN_GENERATION_MAX_TURNS}"
        echo "Design file: ${design_file} ($(wc -l < "$design_file" | tr -d ' ') lines)"
        echo "=== System Prompt ==="
        echo "$prompt"
        echo "=== Session Start ==="
    } > "$log_file"

    # Call claude in batch mode — shell captures output and writes CLAUDE.md.
    # No --dangerously-skip-permissions: claude outputs text only, shell writes the file.
    local claude_md_content=""
    local batch_exit=0
    claude_md_content=$(_call_planning_batch \
        "$PLAN_GENERATION_MODEL" \
        "$PLAN_GENERATION_MAX_TURNS" \
        "$prompt" \
        "$log_file") || batch_exit=$?

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "Turns used: 1"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    if [[ -n "$claude_md_content" ]]; then
        local claude_md="${PROJECT_DIR}/CLAUDE.md"
        printf '%s\n' "$claude_md_content" > "$claude_md"
        local line_count
        line_count=$(wc -l < "$claude_md" | tr -d ' ')
        success "CLAUDE.md generated (${line_count} lines)."
        log "Log saved: ${log_file}"
        return 0
    else
        warn "Generation produced no output — CLAUDE.md was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        log "Log saved: ${log_file}"
        return 1
    fi
}

