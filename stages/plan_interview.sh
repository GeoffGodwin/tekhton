#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/plan_interview.sh — Planning phase: shell-driven interview
#
# The shell presents each template section to the user, reads the user's
# answer, then calls Claude in batch mode (no --dangerously-skip-permissions)
# to synthesize a complete DESIGN.md. The shell writes the resulting file.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_TEMPLATE_FILE, PLAN_PROJECT_TYPE, PLAN_INTERVIEW_MODEL,
#          PLAN_INTERVIEW_MAX_TURNS, PROJECT_DIR, TEKHTON_HOME
# Expects: PLAN_INCOMPLETE_SECTIONS (set by check_design_completeness in plan.sh)
# Expects: log(), success(), warn(), header() from common.sh
# Expects: render_prompt(), _call_planning_batch(), _extract_template_sections()
#          from lib/plan.sh
# =============================================================================

# _read_section_answer — Read a multi-line answer from the user.
#
# Reads lines from $input_fd until a blank line is entered. Joins lines
# with spaces. Returns "skip" (with rc=0) if no content entered or EOF.
# When TEKHTON_TEST_MODE is set, reads from stdin instead of /dev/tty.
#
# Arguments:
#   $1  guidance     — Guidance text to display above the prompt
#   $2  is_required  — "true" or "false"
#   $3  input_fd     — File descriptor path for reading user input
#
# Prints the collected answer to stdout.
# All prompt/guidance display goes to stderr so it remains visible even when
# this function is called inside a command substitution: answer=$(...)
_read_section_answer() {
    local guidance="$1"
    local is_required="$2"
    local input_fd="$3"

    echo >&2
    if [[ -n "$guidance" ]]; then
        echo "  ${guidance}" >&2
    fi
    if [[ "$is_required" != "true" ]]; then
        echo "  (optional — type 'skip' to skip)" >&2
    fi
    echo >&2
    printf "  >>> " >&2

    local lines=() line=""
    while IFS= read -r line <"$input_fd"; do
        if [[ -z "$line" ]]; then
            [[ "${#lines[@]}" -gt 0 ]] && break
        else
            lines+=("$line")
            printf "  >>> " >&2
        fi
    done

    if [[ "${#lines[@]}" -eq 0 ]]; then
        echo "skip"
        return 0
    fi

    local IFS=" "
    echo "${lines[*]}"
}

# run_plan_interview — Shell-driven interview: collect answers, synthesize DESIGN.md.
#
# Presents each template section to the user, reads answers, then calls Claude
# in batch mode to synthesize a complete DESIGN.md. No --dangerously-skip-permissions.
# The shell writes DESIGN.md to PROJECT_DIR.
#
# Returns 0 if DESIGN.md was produced, 1 otherwise.
run_plan_interview() {
    local design_file="${PROJECT_DIR}/DESIGN.md"
    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_plan-interview.log"

    mkdir -p "$log_dir"

    header "Planning Interview — ${PLAN_PROJECT_TYPE}"
    log "Model: ${PLAN_INTERVIEW_MODEL}"
    log "Log: ${log_file}"
    echo
    log "Answer each question. Blank line to submit each answer."
    log "Type 'skip' for optional sections."
    echo

    # Write session metadata to log
    {
        echo "=== Tekhton Plan Interview ==="
        echo "Date: $(date)"
        echo "Project Type: ${PLAN_PROJECT_TYPE}"
        echo "Template: ${PLAN_TEMPLATE_FILE}"
        echo "Model: ${PLAN_INTERVIEW_MODEL}"
        echo "Max Turns: ${PLAN_INTERVIEW_MAX_TURNS}"
        echo "=== Session Start ==="
    } > "$log_file"

    # Save resume state before starting
    write_plan_state "interview" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

    # Determine input source: /dev/tty for interactive use, stdin for tests
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    # Parse template sections into parallel arrays
    local -a section_names=() section_required=() section_guidance=()
    while IFS='|' read -r s_name s_req s_guide; do
        section_names+=("$s_name")
        section_required+=("$s_req")
        section_guidance+=("$s_guide")
    done < <(_extract_template_sections "$PLAN_TEMPLATE_FILE")

    local total="${#section_names[@]}"
    if [[ "$total" -eq 0 ]]; then
        warn "No sections found in template: ${PLAN_TEMPLATE_FILE}"
        return 1
    fi

    # Collect user answers for each section
    local -a answers=()
    local i
    for i in "${!section_names[@]}"; do
        local num=$((i + 1))
        local name="${section_names[$i]}"
        local req="${section_required[$i]}"
        local guide="${section_guidance[$i]:-}"

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ "$req" == "true" ]]; then
            echo "  [${num}/${total}] ${name}  *required"
        else
            echo "  [${num}/${total}] ${name}  (optional)"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        local answer
        answer=$(_read_section_answer "$guide" "$req" "$input_fd")

        if [[ "$answer" == "skip" || "$answer" == "s" ]]; then
            if [[ "$req" == "true" ]]; then
                warn "  Required section skipped — will be marked TBD in DESIGN.md."
                answers+=("TBD")
            else
                log "  Skipped."
                answers+=("SKIP")
            fi
        else
            answers+=("$answer")
        fi
        echo
    done

    echo
    log "Interview complete. Synthesizing DESIGN.md..."
    echo

    # Build the answers block for the synthesis prompt
    local answers_block=""
    for i in "${!section_names[@]}"; do
        local name="${section_names[$i]}"
        local req="${section_required[$i]}"
        local ans="${answers[$i]}"
        local req_label=""
        [[ "$req" == "true" ]] && req_label=" [REQUIRED]"
        if [[ "$ans" == "SKIP" ]]; then
            answers_block+="**${name}${req_label}**: (skipped — write a placeholder)"$'\n\n'
        else
            answers_block+="**${name}${req_label}**: ${ans}"$'\n\n'
        fi
    done

    # Set template variables for prompt rendering
    export TEMPLATE_CONTENT
    TEMPLATE_CONTENT=$(cat "$PLAN_TEMPLATE_FILE")
    export PROJECT_TYPE="$PLAN_PROJECT_TYPE"
    export INTERVIEW_ANSWERS_BLOCK="$answers_block"

    local synthesis_prompt
    synthesis_prompt=$(render_prompt "plan_interview")

    # Log the synthesis prompt
    {
        echo "=== System Prompt ==="
        echo "$synthesis_prompt"
        echo "=== Synthesis Start ==="
    } >> "$log_file"

    # Call claude in batch mode — shell captures output and writes DESIGN.md
    local design_content=""
    local batch_exit=0
    design_content=$(_call_planning_batch \
        "$PLAN_INTERVIEW_MODEL" \
        "${PLAN_INTERVIEW_MAX_TURNS:-5}" \
        "$synthesis_prompt" \
        "$log_file") || batch_exit=$?

    local design_status="not created"
    if [[ -n "$design_content" ]]; then
        printf '%s\n' "$design_content" > "$design_file"
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

    if [[ -n "$design_content" ]]; then
        success "DESIGN.md written (${design_status})."
        log "Log saved: ${log_file}"
        return 0
    else
        warn "Synthesis produced no output — DESIGN.md was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        log "Log saved: ${log_file}"
        return 1
    fi
}

# run_plan_followup_interview — Re-interview for incomplete sections only.
#
# Reads PLAN_INCOMPLETE_SECTIONS and asks the user about only those sections.
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

    # Build a guidance map from the template
    declare -A section_guidance_map=()
    declare -A section_required_map=()
    while IFS='|' read -r s_name s_req s_guide; do
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
