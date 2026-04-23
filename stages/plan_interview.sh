#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/plan_interview.sh — Planning phase: shell-driven interview
#
# The shell presents each template section to the user in three phases,
# reads the user's answer, then calls Claude in batch mode to synthesize
# a complete ${DESIGN_FILE}. The shell writes the resulting file.
#
# Answers are persisted to .claude/plan_answers.yaml via lib/plan_answers.sh
# so that interrupted sessions can be resumed. Supports CLI mode (interactive)
# and file mode (import pre-filled YAML).
#
# Phase 1 — Concept Capture: high-level questions (overview, stack, philosophy)
# Phase 2 — System Deep-Dive: each system/feature section, with Phase 1 context
# Phase 3 — Architecture & Constraints: config, naming, open questions
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_TEMPLATE_FILE, PLAN_PROJECT_TYPE, PLAN_INTERVIEW_MODEL,
#          PLAN_INTERVIEW_MAX_TURNS, PROJECT_DIR, TEKHTON_HOME
# Expects: PLAN_INCOMPLETE_SECTIONS (set by check_design_completeness in plan.sh)
# Expects: log(), success(), warn(), header() from common.sh
# Expects: render_prompt(), _call_planning_batch(), _extract_template_sections()
#          from lib/plan.sh
# Expects: init_answer_file(), save_answer(), load_answer(), has_answer_file(),
#          build_answers_block() from lib/plan_answers.sh
# =============================================================================

# Minimum line count to consider on-disk content "substantive" (used by
# tool-write guard in both plan_interview.sh and plan_generate.sh).
_MIN_SUBSTANTIVE_LINES=20

# Phase labels for display headers
_PHASE_LABELS=("" "Phase 1: Concept Capture" "Phase 2: System Deep-Dive" "Phase 3: Architecture & Constraints")

# Source extracted helper functions (_read_section_answer, _build_phase_context,
# _select_interview_mode, _run_file_mode, _run_cli_interview).
# shellcheck source=stages/plan_interview_helpers.sh
source "${TEKHTON_HOME}/stages/plan_interview_helpers.sh"

# run_plan_interview — Shell-driven interview: collect answers, synthesize ${DESIGN_FILE}.
#
# Presents each template section in three phases, reads answers (persisting
# each to plan_answers.yaml), then calls Claude in batch mode to synthesize
# a complete ${DESIGN_FILE}. The shell writes
# ${DESIGN_FILE} to PROJECT_DIR.
#
# Returns 0 if ${DESIGN_FILE} was produced, 1 otherwise.
run_plan_interview() {
    _assert_design_file_usable || return $?
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"
    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_plan-interview.log"

    mkdir -p "$log_dir"

    header "Planning Interview — ${PLAN_PROJECT_TYPE}"
    log "Model: ${PLAN_INTERVIEW_MODEL}"
    log "Log: ${log_file}"
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

    # Open input source on a dedicated fd for reliable position sharing
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        exec 3< /dev/tty
    else
        exec 3<&0
    fi
    local input_fd=3

    # Initialize or resume answer file (skip init when answers were imported)
    if [[ -n "${PLAN_ANSWERS_IMPORT:-}" ]]; then
        # Answers were imported by import_answer_file() — never overwrite
        if [[ -f "$PLAN_ANSWER_FILE" ]]; then
            log "Using imported answers from: ${PLAN_ANSWERS_IMPORT}"
        else
            error "Answer file missing after import — expected ${PLAN_ANSWER_FILE}"
            exec 3<&-
            return 1
        fi
    elif has_answer_file; then
        log "Resuming from saved answers in ${PLAN_ANSWER_FILE}"
    else
        init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
    fi

    # Mode selection (skip when answers were imported via --answers)
    if [[ -n "${PLAN_ANSWERS_IMPORT:-}" ]]; then
        : # Already logged above — skip mode selection
    else
        local mode
        if [[ -n "${PLAN_BROWSER_MODE:-}" ]]; then
            mode="browser"
        else
            mode=$(_select_interview_mode "$input_fd")
        fi
        case "$mode" in
            file)
                _run_file_mode
                exec 3<&-
                return 1
                ;;
            browser)
                exec 3<&-
                run_browser_interview || return 1
                # Browser mode writes answers directly — skip CLI interview
                ;;
            cli)
                log "Answer each question. Blank line to submit each answer."
                log "Type 'skip' for optional sections."
                echo

                # Parse template sections and collect answers in CLI mode
                _run_cli_interview "$input_fd"
                ;;
        esac
    fi

    echo
    log "Interview complete. Synthesizing ${DESIGN_FILE}..."
    echo

    # Build the answers block from the YAML file
    local answers_block
    answers_block=$(build_answers_block)

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

    # Call claude in batch mode — shell captures output and writes ${DESIGN_FILE}
    local design_content=""
    local batch_exit=0
    design_content=$(_call_planning_batch \
        "$PLAN_INTERVIEW_MODEL" \
        "${PLAN_INTERVIEW_MAX_TURNS:-5}" \
        "$synthesis_prompt" \
        "$log_file") || batch_exit=$?

    # Guard against tool-write overwrite: if Claude used the Write tool to create
    # ${DESIGN_FILE} (substantive content on disk) and returned only a summary as text
    # output, the captured text won't start with a markdown heading. Detect this
    # and preserve the on-disk version.
    local _disk_rescued=false
    if [[ -n "$design_content" ]] && [[ -f "$design_file" ]]; then
        local _captured_first
        _captured_first=$(printf '%s\n' "$design_content" | head -1)
        if [[ "$_captured_first" != "#"* ]]; then
            local _disk_lines _disk_first
            _disk_first=$(head -1 "$design_file")
            _disk_lines=$(count_lines < "$design_file")
            if [[ "$_disk_first" == "#"* ]] && [[ "$_disk_lines" -gt "$_MIN_SUBSTANTIVE_LINES" ]]; then
                log "Detected tool-written ${DESIGN_FILE} (${_disk_lines} lines on disk) — using on-disk version."
                design_content=$(cat "$design_file")
                _disk_rescued=true
            fi
        fi
    fi

    # Trim preamble lines before the first top-level heading, unless we
    # already rescued the on-disk version.
    if [[ -n "$design_content" ]] && [[ "$_disk_rescued" == "false" ]]; then
        design_content=$(printf '%s' "$design_content" | _trim_document_preamble)
    fi

    local design_status="not created"
    if [[ -n "$design_content" ]]; then
        if [[ "$_disk_rescued" == "false" ]]; then
            if ! printf '%s\n' "$design_content" > "$design_file" 2>/dev/null; then
                error "Failed to write ${DESIGN_FILE} to ${design_file}."
                error "Check that the path is a file (not a directory) and the parent directory is writable."
                exec 3<&- 2>/dev/null || true
                return 1
            fi
        fi
        if [[ ! -s "$design_file" ]]; then
            error "${DESIGN_FILE} write appeared to succeed but the file is empty or missing at ${design_file}."
            exec 3<&- 2>/dev/null || true
            return 1
        fi
        local line_count
        line_count=$(count_lines < "$design_file")
        design_status="exists (${line_count} lines)"
    fi

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "${DESIGN_FILE}: ${design_status}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    if [[ -n "$design_content" ]]; then
        if [[ "$_disk_rescued" == "true" ]]; then
            success "${DESIGN_FILE} preserved from tool-written version (${design_status})."
        else
            success "${DESIGN_FILE} written (${design_status})."
        fi
        log "Log saved: ${log_file}"
        exec 3<&-
        return 0
    else
        warn "Synthesis produced no output — ${DESIGN_FILE} was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        log "Log saved: ${log_file}"
        exec 3<&-
        return 1
    fi
}
