#!/usr/bin/env bash
# =============================================================================
# replan_brownfield.sh — Brownfield replanning (--replan CLI command)
#
# Delta-based updates to existing DESIGN.md and CLAUDE.md based on accumulated
# drift and codebase evolution. Sourced by tekhton.sh for the --replan path.
# Expects: common.sh, plan.sh (for _call_planning_batch), prompts.sh
# =============================================================================

# _generate_codebase_summary — Produces a bounded directory tree + recent git log.
# If PROJECT_INDEX.md exists and is recent (within 5 runs / current), use it
# instead of the ad-hoc tree+git-log generation for higher-quality replan context.
# Output capped at ~200 lines of tree + 20 git log entries (fallback path).
_generate_codebase_summary() {
    local index_file="${PROJECT_DIR}/PROJECT_INDEX.md"

    # Prefer PROJECT_INDEX.md when available and reasonably current
    if [[ -f "$index_file" ]]; then
        local index_commit
        index_commit=$(_extract_scan_metadata "$index_file" "Scan-Commit")

        local is_current=false
        if [[ -n "$index_commit" ]] && [[ "$index_commit" != "non-git" ]]; then
            # Check if the scan commit is an ancestor of HEAD (i.e., still in history)
            if git -C "$PROJECT_DIR" merge-base --is-ancestor "$index_commit" HEAD 2>/dev/null; then
                # Check distance: if <=50 commits behind, consider it current enough
                local distance
                distance=$(git -C "$PROJECT_DIR" rev-list --count "${index_commit}..HEAD" 2>/dev/null || echo "999")
                [[ "$distance" -le 50 ]] && is_current=true
            fi
        elif [[ "$index_commit" == "non-git" ]]; then
            # Non-git projects: index exists, use it
            is_current=true
        fi

        if [[ "$is_current" == true ]]; then
            log "Using PROJECT_INDEX.md for replan context (scan commit: ${index_commit:-n/a})"
            cat "$index_file"
            return 0
        else
            log "PROJECT_INDEX.md exists but is stale — falling back to ad-hoc summary"
        fi
    fi

    # Fallback: ad-hoc summary generation
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
