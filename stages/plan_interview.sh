#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/plan_interview.sh — Planning phase: shell-driven interview
#
# The shell presents each template section to the user in three phases,
# reads the user's answer, then calls Claude in batch mode (no
# --dangerously-skip-permissions) to synthesize a complete DESIGN.md.
# The shell writes the resulting file.
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
# =============================================================================

# Phase labels for display headers
_PHASE_LABELS=("" "Phase 1: Concept Capture" "Phase 2: System Deep-Dive" "Phase 3: Architecture & Constraints")

# _read_section_answer — Read a multi-line answer from the user.
#
# If VISUAL or EDITOR is set, opens the editor with a temp file containing
# guidance as comments. The user writes their answer, saves, and exits.
# Otherwise, reads lines from the given fd until a blank line.
# Returns "skip" (with rc=0) if no content entered or EOF.
# When TEKHTON_TEST_MODE is set, uses the line-by-line fallback via stdin.
#
# Arguments:
#   $1  guidance     — Guidance text to display above the prompt
#   $2  is_required  — "true" or "false"
#   $3  input_fd     — Numeric file descriptor to read from (e.g., 3)
#
# Callers must open their input source on this fd before calling.
# Using fd numbers (read -u N) instead of path re-opening (< /dev/stdin)
# guarantees correct position sharing across subshell calls ($()),
# regardless of whether the input is a pipe or regular file.
#
# Prints the collected answer to stdout.
# All prompt/guidance display goes to stderr so it remains visible even when
# this function is called inside a command substitution: answer=$(...)
_read_section_answer() {
    local guidance="$1"
    local is_required="$2"
    local input_fd="$3"

    local editor="${VISUAL:-${EDITOR:-}}"

    # Use editor when available and on a real terminal (not test mode)
    if [[ -n "$editor" ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ -e /dev/tty ]]; then
        _read_section_answer_editor "$guidance" "$is_required" "$editor"
        return $?
    fi

    # Fallback: line-by-line read from the given fd
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
    while IFS= read -r -u "$input_fd" line; do
        line="${line//$'\r'/}"
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

# _read_section_answer_editor — Read answer via $EDITOR.
#
# Creates a temp file with guidance as comments, opens the editor, and reads
# the non-comment content when the user saves and exits.
#
# Arguments:
#   $1  guidance     — Guidance text
#   $2  is_required  — "true" or "false"
#   $3  editor       — Editor command to invoke
_read_section_answer_editor() {
    local guidance="$1"
    local is_required="$2"
    local editor="$3"

    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/tekhton_answer.XXXXXX.md")

    # Write guidance as comments the user can read while editing
    {
        echo "# Write your answer below. Lines starting with # are ignored."
        echo "# Save and exit the editor to submit. Empty file = skip."
        if [[ -n "$guidance" ]]; then
            echo "#"
            echo "# Guidance: ${guidance}"
        fi
        if [[ "$is_required" != "true" ]]; then
            echo "# (This section is optional)"
        fi
        echo ""
    } > "$tmpfile"

    echo "  Opening editor for your answer..." >&2

    # Open the editor on the terminal — /dev/tty handles the case where
    # stdout is captured by $()
    "$editor" "$tmpfile" < /dev/tty > /dev/tty 2>&1

    # Read back the answer, stripping comment lines
    local answer=""
    while IFS= read -r line; do
        [[ "$line" == "#"* ]] && continue
        answer+="${line} "
    done < "$tmpfile"

    rm -f "$tmpfile"

    # Trim trailing whitespace
    answer="${answer%"${answer##*[![:space:]]}"}"

    if [[ -z "$answer" ]]; then
        echo "skip"
        return 0
    fi

    echo "$answer"
}

# _build_phase_context — Build a summary of prior phase answers.
#
# Arguments:
#   $1  names_ref     — nameref to section_names array
#   $2  answers_ref   — nameref to answers array
#   $3  phases_ref    — nameref to section_phases array
#   $4  max_phase     — include answers from phases < this value
#
# Prints a formatted summary to stdout.
_build_phase_context() {
    local -n _bpc_names=$1
    local -n _bpc_answers=$2
    local -n _bpc_phases=$3
    local max_phase="$4"

    local context="" i
    for i in "${!_bpc_names[@]}"; do
        local phase="${_bpc_phases[$i]}"
        local ans="${_bpc_answers[$i]:-}"
        if [[ "$phase" -lt "$max_phase" ]] && [[ -n "$ans" ]] && \
           [[ "$ans" != "SKIP" ]] && [[ "$ans" != "TBD" ]]; then
            context+="- **${_bpc_names[$i]}**: ${ans}"$'\n'
        fi
    done
    echo "$context"
}

# run_plan_interview — Shell-driven interview: collect answers, synthesize DESIGN.md.
#
# Presents each template section in three phases, reads answers, then calls
# Claude in batch mode to synthesize a complete DESIGN.md.
# No --dangerously-skip-permissions. The shell writes DESIGN.md to PROJECT_DIR.
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

    # Open input source on a dedicated fd for reliable position sharing
    # across subshell calls ($()). Using fd duplication (<&0) instead of
    # re-opening /dev/stdin avoids WSL/regular-file position-reset issues.
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        exec 3< /dev/tty
    else
        exec 3<&0
    fi
    local input_fd=3

    # Parse template sections into parallel arrays (4-field format)
    local -a section_names=() section_required=() section_guidance=() section_phases=()
    while IFS='|' read -r s_name s_req s_guide s_phase; do
        section_names+=("$s_name")
        section_required+=("$s_req")
        section_guidance+=("$s_guide")
        section_phases+=("${s_phase:-1}")
    done < <(_extract_template_sections "$PLAN_TEMPLATE_FILE")

    local total="${#section_names[@]}"
    if [[ "$total" -eq 0 ]]; then
        warn "No sections found in template: ${PLAN_TEMPLATE_FILE}"
        exec 3<&-
        return 1
    fi

    # Collect user answers for each section, organized by phase
    local -a answers=()
    # Pre-fill answers array with empty strings (one per section)
    local _i
    for _i in "${!section_names[@]}"; do
        # shellcheck disable=SC2034
        answers[$_i]=""
    done

    local current_phase=0
    local section_num=0
    local i
    for i in "${!section_names[@]}"; do
        local name="${section_names[$i]}"
        local req="${section_required[$i]}"
        local guide="${section_guidance[$i]:-}"
        local phase="${section_phases[$i]}"

        # Display phase header on phase transition
        if [[ "$phase" -ne "$current_phase" ]]; then
            current_phase="$phase"
            echo
            echo "╔══════════════════════════════════════════════════╗"
            echo "║  ${_PHASE_LABELS[$phase]}"
            echo "╚══════════════════════════════════════════════════╝"
            echo

            # Show Phase 1 context at the start of Phase 2+
            if [[ "$phase" -ge 2 ]]; then
                local context
                context=$(_build_phase_context section_names answers section_phases "$phase")
                if [[ -n "$context" ]]; then
                    log "Your answers so far:"
                    echo "$context" | while IFS= read -r ctx_line; do
                        [[ -n "$ctx_line" ]] && echo "  ${ctx_line}"
                    done
                    echo
                fi
            fi
        fi

        section_num=$((section_num + 1))
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ "$req" == "true" ]]; then
            echo "  [${section_num}/${total}] ${name}  *required"
        else
            echo "  [${section_num}/${total}] ${name}  (optional)"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        local answer
        answer=$(_read_section_answer "$guide" "$req" "$input_fd")

        if [[ "$answer" == "skip" || "$answer" == "s" ]]; then
            if [[ "$req" == "true" ]]; then
                warn "  Required section skipped — will be marked TBD in DESIGN.md."
                answers[$i]="TBD"
            else
                log "  Skipped."
                answers[$i]="SKIP"
            fi
        else
            answers[$i]="$answer"
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
        exec 3<&-
        return 0
    else
        warn "Synthesis produced no output — DESIGN.md was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        log "Log saved: ${log_file}"
        exec 3<&-
        return 1
    fi
}
