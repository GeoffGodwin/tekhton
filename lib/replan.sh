#!/usr/bin/env bash
# =============================================================================
# replan.sh — Mid-run replanning when task scope breaks
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn(), error(), header() from common.sh
# Expects: write_pipeline_state() from state.sh
# Expects: _call_planning_batch() from plan.sh
# Expects: render_prompt() from prompts.sh
# =============================================================================

# detect_replan_required — Check if the reviewer verdict is REPLAN_REQUIRED.
#
# Returns 0 if REPLAN_REQUIRED found, 1 otherwise.
#
# Usage: detect_replan_required "REVIEWER_REPORT.md"
detect_replan_required() {
    local report_file="$1"

    if [[ "${REPLAN_ENABLED:-true}" != "true" ]]; then
        return 1
    fi

    if [[ ! -f "$report_file" ]]; then
        return 1
    fi

    if grep -qi "REPLAN_REQUIRED" "$report_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

# trigger_replan — Display replan rationale and present the replan menu.
#
# Extracts the rationale from the reviewer report, shows it to the user,
# and presents a menu: [r] Replan, [s] Split, [c] Continue, [a] Abort.
#
# Returns:
#   0 — user chose to continue (either after replan or skipping)
#   1 — user chose to abort
#
# Usage: trigger_replan "REVIEWER_REPORT.md"
trigger_replan() {
    local report_file="$1"

    # Extract replan rationale from reviewer report
    local rationale
    rationale=$(awk '/REPLAN_REQUIRED/{found=1} found && /^[-*]/{print; next} found && /^$/{exit}' \
        "$report_file" 2>/dev/null || true)
    if [[ -z "$rationale" ]]; then
        rationale=$(awk '/REPLAN_REQUIRED/{found=1; next} found && /^## /{exit} found{print}' \
            "$report_file" 2>/dev/null || true)
    fi

    echo
    header "Replan Required"
    echo "  The reviewer has determined that the current task is fundamentally"
    echo "  mis-scoped or contradicts the architecture."
    echo

    if [[ -n "$rationale" ]]; then
        echo "  Rationale:"
        # shellcheck disable=SC2001
        echo "$rationale" | sed 's/^/    /'
        echo
    fi

    echo "  Options:"
    echo "    [r] Replan  — re-generate the current milestone scope"
    echo "    [s] Split   — save state and split task manually"
    echo "    [c] Continue — ignore replan and proceed to tester"
    echo "    [a] Abort   — save state and exit"
    echo

    # Determine input source
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    printf "  Select [r/s/c/a]: "
    read -r choice < "$input_fd" || { warn "End of input"; choice="a"; }
    choice="${choice//$'\r'/}"

    case "$choice" in
        r|R)
            log "Initiating single-milestone replan..."
            _run_replan "$rationale"
            return $?
            ;;
        s|S)
            log "Saving state for manual task split..."
            write_pipeline_state \
                "review" \
                "replan_split" \
                "${MILESTONE_MODE:+--milestone }--start-at review" \
                "$TASK" \
                "Reviewer requested REPLAN_REQUIRED. User chose to split task manually. Rationale: ${rationale}"
            warn "State saved. Split the task in CLAUDE.md, then re-run."
            return 1
            ;;
        c|C)
            log "Continuing despite replan recommendation."
            return 0
            ;;
        a|A|*)
            log "Aborting on replan request."
            write_pipeline_state \
                "review" \
                "replan_abort" \
                "${MILESTONE_MODE:+--milestone }--start-at review" \
                "$TASK" \
                "Reviewer requested REPLAN_REQUIRED. User aborted. Rationale: ${rationale}"
            return 1
            ;;
    esac
}

# _run_replan — Execute a single-milestone replan using the planning batch call.
#
# Reads DESIGN.md and CLAUDE.md, calls _call_planning_batch() with the replan
# prompt, writes the delta to REPLAN_DELTA.md, and presents an approval menu.
#
# Returns 0 on success (user approved or continued), 1 on abort.
_run_replan() {
    local rationale="${1:-}"

    # Check that plan.sh is sourced (provides _call_planning_batch)
    if ! declare -f _call_planning_batch &>/dev/null; then
        # Source plan.sh for replan support
        if [[ -f "${TEKHTON_HOME}/lib/plan.sh" ]]; then
            # shellcheck source=lib/plan.sh
            source "${TEKHTON_HOME}/lib/plan.sh"
        else
            error "Cannot replan: lib/plan.sh not found."
            return 1
        fi
    fi

    # Build replan context
    local design_content=""
    if [[ -f "${PROJECT_DIR}/DESIGN.md" ]]; then
        design_content=$(_safe_read_file "${PROJECT_DIR}/DESIGN.md" "DESIGN")
    fi

    local claude_content=""
    if [[ -f "${PROJECT_DIR}/CLAUDE.md" ]]; then
        claude_content=$(_safe_read_file "${PROJECT_DIR}/CLAUDE.md" "CLAUDE")
    fi

    if [[ -z "$design_content" ]] && [[ -z "$claude_content" ]]; then
        error "Cannot replan: neither DESIGN.md nor CLAUDE.md found."
        return 1
    fi

    # Export variables for the replan prompt template
    export DESIGN_CONTENT="$design_content"
    export CLAUDE_CONTENT="$claude_content"
    export REPLAN_RATIONALE="$rationale"
    export REPLAN_TASK="$TASK"

    # Load drift/architecture logs if available
    export DRIFT_LOG_CONTENT=""
    if [[ -f "${DRIFT_LOG_FILE:-}" ]]; then
        DRIFT_LOG_CONTENT=$(_safe_read_file "$DRIFT_LOG_FILE" "DRIFT_LOG")
    fi
    export ARCHITECTURE_LOG_CONTENT=""
    if [[ -f "${ARCHITECTURE_LOG_FILE:-}" ]]; then
        ARCHITECTURE_LOG_CONTENT=$(_safe_read_file "$ARCHITECTURE_LOG_FILE" "ARCHITECTURE_LOG")
    fi

    local replan_model="${REPLAN_MODEL:-${PLAN_GENERATION_MODEL:-opus}}"
    local replan_turns="${REPLAN_MAX_TURNS:-${PLAN_GENERATION_MAX_TURNS:-50}}"

    # Render the replan prompt if template exists; otherwise use inline prompt
    local replan_prompt
    if [[ -f "${TEKHTON_HOME}/prompts/replan.prompt.md" ]]; then
        replan_prompt=$(render_prompt "replan")
    else
        replan_prompt="You are a project planning agent. The current task has been flagged as
needing a replan. Here is the context:

Task: ${TASK}
Rationale for replan: ${rationale}

Current DESIGN.md:
${design_content}

Current CLAUDE.md:
${claude_content}

Produce an updated milestone definition for the current task only.
Output the result as a markdown document showing what should change."
    fi

    local log_file
    log_file="${LOG_DIR:-${PROJECT_DIR}/.claude/logs}/$(date +%Y%m%d_%H%M%S)_replan.log"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

    log "Running replan agent (model: ${replan_model}, max turns: ${replan_turns})..."

    local replan_output
    local exit_code
    replan_output=$(_call_planning_batch "$replan_model" "$replan_turns" "$replan_prompt" "$log_file")
    exit_code=$?

    if [[ $exit_code -ne 0 ]] || [[ -z "$replan_output" ]]; then
        error "Replan agent produced no output."
        return 1
    fi

    # Write delta to file
    local delta_file="${PROJECT_DIR}/REPLAN_DELTA.md"
    echo "$replan_output" > "$delta_file"
    success "Replan delta written to REPLAN_DELTA.md"

    # Present approval menu
    echo
    header "Replan Delta Review"
    echo "  Review the proposed changes in REPLAN_DELTA.md"
    echo
    echo "  Options:"
    echo "    [a] Apply  — merge changes into CLAUDE.md"
    echo "    [e] Edit   — open delta in \${EDITOR:-nano} before applying"
    echo "    [n] Reject — discard delta, continue with original scope"
    echo

    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local delta_choice
    printf "  Select [a/e/n]: "
    read -r delta_choice < "$input_fd" || { warn "End of input"; delta_choice="n"; }
    delta_choice="${delta_choice//$'\r'/}"

    case "$delta_choice" in
        a|A)
            # Apply: append the delta as a note in CLAUDE.md
            _apply_replan_delta "$delta_file"
            success "Replan applied. Continuing with updated scope."
            return 0
            ;;
        e|E)
            "${EDITOR:-nano}" "$delta_file" || warn "Editor exited with non-zero status"
            _apply_replan_delta "$delta_file"
            success "Edited replan applied. Continuing with updated scope."
            return 0
            ;;
        n|N|*)
            log "Replan rejected. Continuing with original scope."
            rm -f "$delta_file"
            return 0
            ;;
    esac
}

# _apply_replan_delta — Merge the replan delta into CLAUDE.md.
#
# For single-milestone replans, this appends a "Replan Note" section to
# CLAUDE.md with the delta content, preserving the existing file.
_apply_replan_delta() {
    local delta_file="$1"
    local claude_file="${PROJECT_DIR}/CLAUDE.md"

    if [[ ! -f "$delta_file" ]]; then
        warn "Delta file not found: ${delta_file}"
        return 1
    fi

    if [[ ! -f "$claude_file" ]]; then
        warn "CLAUDE.md not found — cannot apply delta."
        return 1
    fi

    # Append replan note to CLAUDE.md
    {
        echo ""
        echo "<!-- Replan applied: $(date '+%Y-%m-%d %H:%M:%S') -->"
        echo "## Replan Note"
        echo ""
        cat "$delta_file"
    } >> "$claude_file"

    # Archive the delta
    local archive_dir="${LOG_DIR:-${PROJECT_DIR}/.claude/logs}/archive"
    mkdir -p "$archive_dir" 2>/dev/null || true
    mv "$delta_file" "${archive_dir}/$(date +%Y%m%d_%H%M%S)_REPLAN_DELTA.md" 2>/dev/null || true
}
