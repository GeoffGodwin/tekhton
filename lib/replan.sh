#!/usr/bin/env bash
# =============================================================================
# replan.sh — Mid-run and brownfield replanning
#
# Contains both mid-run replan (triggered by reviewer REPLAN_REQUIRED verdict)
# and brownfield replan (--replan CLI command). Sourced by tekhton.sh.
# Expects: common.sh, state.sh, plan.sh (for _call_planning_batch), prompts.sh
# =============================================================================

# --- Replan config defaults --------------------------------------------------
export REPLAN_MODEL="${REPLAN_MODEL:-${PLAN_GENERATION_MODEL:-opus}}"
export REPLAN_MAX_TURNS="${REPLAN_MAX_TURNS:-${PLAN_GENERATION_MAX_TURNS:-50}}"

# =============================================================================
# Mid-Run Replan (triggered by reviewer verdict during pipeline execution)
# =============================================================================

# detect_replan_required — Returns 0 if REPLAN_REQUIRED found, 1 otherwise.
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

# trigger_replan — Show rationale, present menu: [r] Replan [s] Split [c] Continue [a] Abort.
trigger_replan() {
    local report_file="$1"

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
            _run_midrun_replan "$rationale"
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

# _run_midrun_replan — Execute single-milestone replan via _call_planning_batch().
_run_midrun_replan() {
    local rationale="${1:-}"

    if ! declare -f _call_planning_batch &>/dev/null; then
        if [[ -f "${TEKHTON_HOME}/lib/plan.sh" ]]; then
            # shellcheck source=lib/plan.sh
            source "${TEKHTON_HOME}/lib/plan.sh"
        else
            error "Cannot replan: lib/plan.sh not found."
            return 1
        fi
    fi

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

    export DESIGN_CONTENT="$design_content"
    export CLAUDE_CONTENT="$claude_content"
    export REPLAN_RATIONALE="$rationale"
    export REPLAN_TASK="$TASK"

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

    local delta_file="${PROJECT_DIR}/REPLAN_DELTA.md"
    echo "$replan_output" > "$delta_file"
    success "Replan delta written to REPLAN_DELTA.md"

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
            _apply_midrun_delta "$delta_file"
            success "Replan applied. Continuing with updated scope."
            return 0
            ;;
        e|E)
            "${EDITOR:-nano}" "$delta_file" || warn "Editor exited with non-zero status"
            _apply_midrun_delta "$delta_file"
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

# _apply_midrun_delta — Append mid-run replan delta as a note section in CLAUDE.md.
_apply_midrun_delta() {
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

    {
        echo ""
        echo "<!-- Replan applied: $(date '+%Y-%m-%d %H:%M:%S') -->"
        echo "## Replan Note"
        echo ""
        cat "$delta_file"
    } >> "$claude_file"

    local archive_dir="${LOG_DIR:-${PROJECT_DIR}/.claude/logs}/archive"
    mkdir -p "$archive_dir" 2>/dev/null || true
    mv "$delta_file" "${archive_dir}/$(date +%Y%m%d_%H%M%S)_REPLAN_DELTA.md" 2>/dev/null || true
}

# =============================================================================
# Brownfield Replan (--replan CLI command)
# =============================================================================

# _generate_codebase_summary — Produces a bounded directory tree + recent git log.
# Output capped at ~200 lines of tree + 20 git log entries.
_generate_codebase_summary() {
    local summary=""

    if command -v tree &>/dev/null; then
        summary+="### Directory Tree (depth 3)"$'\n'
        summary+=$(tree -L 3 --noreport -I 'node_modules|.git|__pycache__|.dart_tool|build|dist|.next' \
            "$PROJECT_DIR" 2>/dev/null | head -200 || true)
        summary+=$'\n'
    else
        summary+="### Directory Listing (depth 3)"$'\n'
        summary+=$(find "$PROJECT_DIR" -maxdepth 3 \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/build/*' \
            -not -path '*/dist/*' \
            -not -path '*/.next/*' \
            -type f 2>/dev/null | sort | head -200 || true)
        summary+=$'\n'
    fi

    if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
        summary+=$'\n'"### Recent Git History (last 20 commits)"$'\n'
        summary+=$(git -C "$PROJECT_DIR" log --oneline -20 2>/dev/null || true)
        summary+=$'\n'
    else
        summary+=$'\n'"### Git History"$'\n'"(Not a git repository)"$'\n'
    fi

    printf '%s' "$summary"
}

# run_replan — Top-level --replan orchestrator.
# Validates prerequisites, assembles context, calls the replan agent,
# writes output to DESIGN_DELTA.md, and presents approval menu.
run_replan() {
    local design_file="${PROJECT_DIR}/DESIGN.md"
    local claude_file="${PROJECT_DIR}/CLAUDE.md"

    header "Tekhton — Brownfield Replan"

    if [[ ! -f "$design_file" ]] && [[ ! -f "$claude_file" ]]; then
        error "Neither DESIGN.md nor CLAUDE.md found at ${PROJECT_DIR}."
        error "The --replan command requires an existing project created with --plan."
        error "Run 'tekhton --plan' first to create these files."
        return 1
    fi

    if [[ ! -f "$claude_file" ]]; then
        error "CLAUDE.md not found at ${PROJECT_DIR}."
        error "The --replan command requires an existing CLAUDE.md."
        return 1
    fi

    log "Assembling replan context..."

    export DESIGN_CONTENT=""
    export NO_DESIGN=""
    if [[ -f "$design_file" ]]; then
        DESIGN_CONTENT=$(_safe_read_file "$design_file" "DESIGN")
    else
        NO_DESIGN="true"
        warn "No DESIGN.md found — replan will focus on CLAUDE.md only."
    fi

    export CLAUDE_CONTENT=""
    CLAUDE_CONTENT=$(_safe_read_file "$claude_file" "CLAUDE")

    export DRIFT_LOG_CONTENT=""
    export NO_DRIFT_LOG=""
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE:-DRIFT_LOG.md}"
    if [[ -f "$drift_file" ]]; then
        DRIFT_LOG_CONTENT=$(_safe_read_file "$drift_file" "DRIFT_LOG")
    else
        NO_DRIFT_LOG="true"
    fi

    export ARCHITECTURE_LOG_CONTENT=""
    export NO_ARCHITECTURE_LOG=""
    local adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE:-ARCHITECTURE_LOG.md}"
    if [[ -f "$adl_file" ]]; then
        ARCHITECTURE_LOG_CONTENT=$(_safe_read_file "$adl_file" "ARCHITECTURE_LOG")
    else
        NO_ARCHITECTURE_LOG="true"
    fi

    export HUMAN_ACTION_CONTENT=""
    export NO_HUMAN_ACTION=""
    local action_file="${PROJECT_DIR}/${HUMAN_ACTION_FILE:-HUMAN_ACTION_REQUIRED.md}"
    if [[ -f "$action_file" ]]; then
        HUMAN_ACTION_CONTENT=$(_safe_read_file "$action_file" "HUMAN_ACTION")
    else
        NO_HUMAN_ACTION="true"
    fi

    export CODEBASE_SUMMARY=""
    log "Generating codebase summary..."
    CODEBASE_SUMMARY=$(_generate_codebase_summary)

    local replan_prompt
    replan_prompt=$(render_prompt "replan")

    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_replan.log"
    mkdir -p "$log_dir"

    log "Model: ${REPLAN_MODEL}"
    log "Max turns: ${REPLAN_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Running replan agent..."

    {
        echo "=== Tekhton Brownfield Replan ==="
        echo "Date: $(date)"
        echo "Model: ${REPLAN_MODEL}"
        echo "Max Turns: ${REPLAN_MAX_TURNS}"
        echo "=== Session Start ==="
    } > "$log_file"

    local replan_output=""
    local batch_exit=0
    replan_output=$(_call_planning_batch \
        "$REPLAN_MODEL" \
        "$REPLAN_MAX_TURNS" \
        "$replan_prompt" \
        "$log_file") || batch_exit=$?

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    if [[ -z "$replan_output" ]]; then
        error "Replan agent produced no output."
        [[ "$batch_exit" -ne 0 ]] && error "Claude exited with code ${batch_exit}."
        log "Log saved: ${log_file}"
        return 1
    fi

    local delta_file="${PROJECT_DIR}/REPLAN_DELTA.md"
    printf '%s\n' "$replan_output" > "$delta_file"
    local delta_lines
    delta_lines=$(wc -l < "$delta_file")
    success "Replan delta written to REPLAN_DELTA.md (${delta_lines} lines)."
    log "Log saved: ${log_file}"

    echo
    _brownfield_approval_menu "$delta_file"
}

# _brownfield_approval_menu — Displays the delta and prompts for approval.
_brownfield_approval_menu() {
    local delta_file="$1"

    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    while true; do
        header "Replan Delta Review"
        echo "  Review the proposed changes in REPLAN_DELTA.md"
        echo
        echo "  Options:"
        echo "    [a] Apply   — merge changes into DESIGN.md and regenerate CLAUDE.md"
        echo "    [e] Edit    — open delta in \${EDITOR:-nano} before applying"
        echo "    [n] Reject  — discard delta"
        echo
        printf "  Select [a/e/n]: "
        read -r choice < "$input_fd" || { warn "End of input"; choice="n"; }
        choice="${choice//$'\r'/}"

        case "$choice" in
            a|A)
                _apply_brownfield_delta "$delta_file"
                return $?
                ;;
            e|E)
                "${EDITOR:-nano}" "$delta_file" || warn "Editor exited with non-zero status"
                log "Editor closed. Re-showing menu..."
                ;;
            n|N)
                log "Replan rejected. No changes applied."
                _archive_replan_delta "$delta_file"
                return 0
                ;;
            *)
                warn "Invalid choice '${choice}'. Please enter a, e, or n."
                ;;
        esac
    done
}

# _apply_brownfield_delta — Apply the replan delta to DESIGN.md and regenerate CLAUDE.md.
_apply_brownfield_delta() {
    local delta_file="$1"
    local design_file="${PROJECT_DIR}/DESIGN.md"
    local claude_file="${PROJECT_DIR}/CLAUDE.md"

    if [[ ! -f "$delta_file" ]]; then
        error "Delta file not found: ${delta_file}"
        return 1
    fi

    if [[ -f "$design_file" ]]; then
        {
            echo ""
            echo "<!-- Replan applied: $(date '+%Y-%m-%d %H:%M:%S') -->"
            echo "## Replan Delta"
            echo ""
            cat "$delta_file"
        } >> "$design_file"
        success "Delta appended to DESIGN.md."
    else
        warn "No DESIGN.md to update — skipping DESIGN.md merge."
    fi

    if [[ -f "$design_file" ]]; then
        echo
        log "Regenerating CLAUDE.md from updated DESIGN.md..."

        local completed_milestones=""
        if [[ -f "$claude_file" ]]; then
            completed_milestones=$(awk '
                /^####.*\[DONE\]/ { collecting=1; print; next }
                collecting && /^####/ && !/\[DONE\]/ { collecting=0; next }
                collecting && /^###[^#]/ { collecting=0; next }
                collecting && /^##[^#]/ { collecting=0; next }
                collecting { print }
            ' "$claude_file" 2>/dev/null || true)
        fi
        export COMPLETED_MILESTONES="$completed_milestones"

        if ! declare -f run_plan_generate &>/dev/null; then
            if [[ -f "${TEKHTON_HOME}/stages/plan_generate.sh" ]]; then
                # shellcheck source=stages/plan_generate.sh
                source "${TEKHTON_HOME}/stages/plan_generate.sh"
            else
                warn "Cannot regenerate CLAUDE.md: stages/plan_generate.sh not found."
                warn "Apply the CLAUDE.md delta manually from REPLAN_DELTA.md."
                _archive_replan_delta "$delta_file"
                return 0
            fi
        fi

        run_plan_generate || {
            warn "CLAUDE.md regeneration failed. Apply the delta manually."
            _archive_replan_delta "$delta_file"
            return 0
        }

        success "CLAUDE.md regenerated successfully."
    else
        {
            echo ""
            echo "<!-- Replan applied: $(date '+%Y-%m-%d %H:%M:%S') -->"
            echo "## Replan Note"
            echo ""
            cat "$delta_file"
        } >> "$claude_file"
        success "Delta appended to CLAUDE.md."
    fi

    _archive_replan_delta "$delta_file"

    echo
    success "Brownfield replan complete!"
    log "Review the updated files:"
    if [[ -f "$design_file" ]]; then
        log "  DESIGN.md — replan delta appended"
    fi
    log "  CLAUDE.md — regenerated from updated design"
    echo
}

# _archive_replan_delta — Move the delta file to the logs archive.
_archive_replan_delta() {
    local delta_file="$1"
    if [[ ! -f "$delta_file" ]]; then
        return 0
    fi
    local archive_dir="${PROJECT_DIR}/.claude/logs/archive"
    mkdir -p "$archive_dir" 2>/dev/null || true
    mv "$delta_file" "${archive_dir}/$(date +%Y%m%d_%H%M%S)_REPLAN_DELTA.md" 2>/dev/null || true
}
