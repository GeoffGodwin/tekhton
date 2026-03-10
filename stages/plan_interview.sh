#!/usr/bin/env bash
# =============================================================================
# stages/plan_interview.sh — Planning phase: interactive interview
#
# Walks the user through the selected design doc template section-by-section.
# Claude asks questions in conversational mode, the user answers in the
# terminal, and Claude writes DESIGN.md progressively.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_TEMPLATE_FILE, PLAN_PROJECT_TYPE, PLAN_INTERVIEW_MODEL,
#          PLAN_INTERVIEW_MAX_TURNS, PROJECT_DIR, TEKHTON_HOME
# Expects: log(), success(), warn(), header() from common.sh
# Expects: render_prompt() from prompts.sh
# =============================================================================

# run_plan_interview — Launch the interactive interview agent.
#
# Reads the selected template, renders the interview system prompt, and
# launches claude in conversational (non-batch) mode. The agent asks questions
# one at a time and writes DESIGN.md to disk after each answer.
#
# If the user presses Ctrl+C, any DESIGN.md written so far is preserved.
#
# Returns 0 on successful interview, 1 if interrupted or no output produced.
run_plan_interview() {
    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_plan-interview.log"

    mkdir -p "$log_dir"

    # Set template variables for prompt rendering
    export TEMPLATE_CONTENT
    TEMPLATE_CONTENT=$(cat "$PLAN_TEMPLATE_FILE")
    export PROJECT_TYPE="$PLAN_PROJECT_TYPE"

    # Render the interview system prompt
    local system_prompt
    system_prompt=$(render_prompt "plan_interview")

    header "Planning Interview — ${PLAN_PROJECT_TYPE}"
    log "Model: ${PLAN_INTERVIEW_MODEL}"
    log "Max turns: ${PLAN_INTERVIEW_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Claude will interview you about your project."
    log "Answer each question. Type 'skip' to skip optional sections."
    log "Press Ctrl+C to interrupt — partial DESIGN.md will be preserved."
    echo

    # Write session metadata to log
    {
        echo "=== Tekhton Plan Interview ==="
        echo "Date: $(date)"
        echo "Project Type: ${PLAN_PROJECT_TYPE}"
        echo "Template: ${PLAN_TEMPLATE_FILE}"
        echo "Model: ${PLAN_INTERVIEW_MODEL}"
        echo "Max Turns: ${PLAN_INTERVIEW_MAX_TURNS}"
        echo "=== System Prompt ==="
        echo "$system_prompt"
        echo "=== Session Start ==="
    } > "$log_file"

    # Trap INT to prevent bash from exiting before we print cleanup info.
    # Claude receives SIGINT independently and shuts down; we just need
    # bash to survive long enough to report DESIGN.md status.
    trap 'true' INT

    # Launch claude in conversational (interactive) mode.
    # NOT using -p (batch mode) — the user types answers directly.
    # --dangerously-skip-permissions lets the agent write DESIGN.md
    # without prompting for approval on each file write.
    local exit_code=0
    claude \
        --model "$PLAN_INTERVIEW_MODEL" \
        --dangerously-skip-permissions \
        --max-turns "$PLAN_INTERVIEW_MAX_TURNS" \
        --append-system-prompt "$system_prompt" \
        || exit_code=$?

    # Restore default INT handler
    trap - INT

    # Log session end
    {
        echo "=== Session End ==="
        echo "Exit code: ${exit_code}"
        echo "Date: $(date)"
        if [ -f "${PROJECT_DIR}/DESIGN.md" ]; then
            echo "DESIGN.md: exists ($(wc -l < "${PROJECT_DIR}/DESIGN.md" | tr -d ' ') lines)"
        else
            echo "DESIGN.md: not created"
        fi
    } >> "$log_file"

    echo

    # Report results
    if [ -f "${PROJECT_DIR}/DESIGN.md" ]; then
        local line_count
        line_count=$(wc -l < "${PROJECT_DIR}/DESIGN.md" | tr -d ' ')

        if [ "$exit_code" -ne 0 ]; then
            warn "Interview session ended early (exit code: ${exit_code})."
            success "DESIGN.md preserved (${line_count} lines)."
            log "Re-run 'tekhton --plan' to continue or start over."
        else
            success "Interview complete. DESIGN.md written (${line_count} lines)."
        fi
        log "Log saved: ${log_file}"
        return 0
    else
        if [ "$exit_code" -ne 0 ]; then
            warn "Interview interrupted before DESIGN.md was created."
        else
            warn "Interview ended but no DESIGN.md was created."
        fi
        log "Log saved: ${log_file}"
        return 1
    fi
}
