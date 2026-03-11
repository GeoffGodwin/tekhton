#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/plan_followup_interview.sh — Planning phase: follow-up interview
#
# Re-interviews the user for incomplete sections only. Shows existing section
# content before each question so the user can see what was already written
# and add what's missing. Calls Claude in batch mode to produce an updated
# complete DESIGN.md. The shell writes the file.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_TEMPLATE_FILE, PLAN_PROJECT_TYPE, PLAN_INTERVIEW_MODEL,
#          PLAN_INTERVIEW_MAX_TURNS, PROJECT_DIR, TEKHTON_HOME
# Expects: PLAN_INCOMPLETE_SECTIONS (set by check_design_completeness in plan.sh)
# Expects: log(), success(), warn(), header() from common.sh
# Expects: render_prompt(), _call_planning_batch(), _extract_template_sections()
#          from lib/plan.sh
# Expects: _get_section_content() from lib/plan_completeness.sh
# Expects: _read_section_answer() from stages/plan_interview.sh
# =============================================================================

# run_plan_followup_interview — Re-interview for incomplete sections only.
#
# Reads PLAN_INCOMPLETE_SECTIONS and asks the user about only those sections.
# Shows existing section content before each question so the user can see
# what was already written and add what's missing.
# Calls Claude in batch mode to produce an updated complete DESIGN.md.
# The shell writes the file. No --dangerously-skip-permissions.
#
# Returns 0 if DESIGN.md was updated, 1 otherwise.
run_plan_followup_interview() {
    local design_file="${PROJECT_DIR}/DESIGN.md"
    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_plan-interview-followup.log"

    mkdir -p "$log_dir"

    # Parse the list of incomplete section names
    local -a incomplete_list=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && incomplete_list+=("$s")
    done <<< "$PLAN_INCOMPLETE_SECTIONS"

    local total="${#incomplete_list[@]}"
    header "Follow-Up Interview — ${total} Incomplete Section(s)"
    log "Model: ${PLAN_INTERVIEW_MODEL}"
    log "Log: ${log_file}"
    echo
    log "Only the sections listed below need more detail."
    log "Blank line to submit each answer."
    echo

    # Write session metadata to log
    {
        echo "=== Tekhton Plan Follow-Up Interview ==="
        echo "Date: $(date)"
        echo "Project Type: ${PLAN_PROJECT_TYPE}"
        echo "Incomplete sections: ${incomplete_list[*]}"
        echo "Model: ${PLAN_INTERVIEW_MODEL}"
        echo "Max Turns: ${PLAN_INTERVIEW_MAX_TURNS}"
        echo "=== Session Start ==="
    } > "$log_file"

    # Save resume state
    write_plan_state "completeness" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    # Build a guidance map from the template (handles 4-field format)
    declare -A section_guidance_map=()
    declare -A section_required_map=()
    while IFS='|' read -r s_name s_req s_guide _s_phase; do
        section_guidance_map["$s_name"]="${s_guide:-}"
        section_required_map["$s_name"]="${s_req:-true}"
    done < <(_extract_template_sections "$PLAN_TEMPLATE_FILE")

    # Collect answers for the incomplete sections
    local answers_block=""
    local i=0
    for section_name in "${incomplete_list[@]}"; do
        i=$((i + 1))
        local guide="${section_guidance_map[$section_name]:-}"
        local req="${section_required_map[$section_name]:-true}"

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  [${i}/${total}] ${section_name}  *required"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Show existing section content as context
        if [[ -f "$design_file" ]]; then
            local existing_content
            existing_content=$(_get_section_content "$design_file" "$section_name")
            if [[ -n "$existing_content" ]]; then
                echo
                log "  Current content:"
                echo "$existing_content" | head -10 | while IFS= read -r eline; do
                    echo "    ${eline}"
                done
            fi
        fi

        local answer
        answer=$(_read_section_answer "$guide" "$req" "$input_fd")

        if [[ "$answer" == "skip" || "$answer" == "s" ]]; then
            warn "  Skipping required section — will remain TBD."
            answers_block+="**${section_name}** [REQUIRED]: (user skipped — leave as TBD)"$'\n\n'
        else
            answers_block+="**${section_name}** [REQUIRED]: ${answer}"$'\n\n'
        fi
        echo
    done

    log "Updating DESIGN.md with follow-up answers..."
    echo

    # Set template variables for prompt rendering
    export DESIGN_CONTENT
    DESIGN_CONTENT=$(cat "$design_file")
    export PROJECT_TYPE="$PLAN_PROJECT_TYPE"
    export INCOMPLETE_SECTIONS="$PLAN_INCOMPLETE_SECTIONS"
    export INTERVIEW_ANSWERS_BLOCK="$answers_block"

    local followup_prompt
    followup_prompt=$(render_prompt "plan_interview_followup")

    {
        echo "=== Follow-Up Prompt ==="
        echo "$followup_prompt"
        echo "=== Synthesis Start ==="
    } >> "$log_file"

    # Call claude in batch mode — shell writes the updated file
    local updated_content=""
    local batch_exit=0
    updated_content=$(_call_planning_batch \
        "$PLAN_INTERVIEW_MODEL" \
        "${PLAN_INTERVIEW_MAX_TURNS:-5}" \
        "$followup_prompt" \
        "$log_file") || batch_exit=$?

    local design_status="not created"
    if [[ -n "$updated_content" ]]; then
        printf '%s\n' "$updated_content" > "$design_file"
        local line_count
        line_count=$(wc -l < "$design_file" | tr -d ' ')
        design_status="exists (${line_count} lines)"
    fi

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "DESIGN.md: ${design_status}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    if [[ -n "$updated_content" ]]; then
        success "DESIGN.md updated (${design_status})."
        log "Log saved: ${log_file}"
        return 0
    else
        warn "Update produced no output — DESIGN.md was not changed."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        log "Log saved: ${log_file}"
        return 1
    fi
}
