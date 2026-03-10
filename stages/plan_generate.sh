#!/usr/bin/env bash
# =============================================================================
# stages/plan_generate.sh — Planning phase: CLAUDE.md generation
#
# Reads the completed DESIGN.md and generates a full CLAUDE.md with project
# rules, milestone plan, architecture guidelines, and testing strategy.
# Uses batch mode (run_agent) — not conversational.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_GENERATION_MODEL, PLAN_GENERATION_MAX_TURNS, PROJECT_DIR,
#          TEKHTON_HOME
# Expects: log(), success(), warn(), header() from common.sh
# Expects: render_prompt() from prompts.sh
# Expects: run_agent() from agent.sh
# =============================================================================

# run_plan_generate — Generate CLAUDE.md from DESIGN.md using a batch agent.
#
# Reads DESIGN.md, renders the generation prompt, invokes run_agent() in batch
# mode, and reports results. The agent writes CLAUDE.md to the project directory.
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

    # Run the generation agent in batch mode
    run_agent "Plan Generate" "$PLAN_GENERATION_MODEL" "$PLAN_GENERATION_MAX_TURNS" \
        "$prompt" "$log_file"

    # Log session end
    {
        echo "=== Session End ==="
        echo "Exit code: ${LAST_AGENT_EXIT_CODE}"
        echo "Turns used: ${LAST_AGENT_TURNS}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    # Report results
    local claude_md="${PROJECT_DIR}/CLAUDE.md"
    if [[ -f "$claude_md" ]]; then
        local line_count
        line_count=$(wc -l < "$claude_md" | tr -d ' ')
        success "CLAUDE.md generated (${line_count} lines)."
        log "Log saved: ${log_file}"
        return 0
    else
        warn "Generation agent completed but CLAUDE.md was not created."
        log "Log saved: ${log_file}"
        return 1
    fi
}
