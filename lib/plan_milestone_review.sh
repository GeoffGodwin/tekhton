#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2153
# =============================================================================
# plan_milestone_review.sh — Milestone review UI for planning phase
#
# Displays milestone summary from generated CLAUDE.md and provides interactive
# accept/edit/regenerate/abort flow. Also provides _print_next_steps().
#
# Extracted from plan.sh for size management. Sourced by plan.sh — do not
# run directly.
#
# Expects: run_plan_generate() from stages/plan_generate.sh
# Expects: log(), warn(), success(), header(), error() from common.sh
# =============================================================================

# _display_milestone_summary — Show the milestone review screen.
# Checks DAG milestone directory first (when MILESTONE_DAG_ENABLED=true),
# then falls back to reading inline milestone headings from CLAUDE.md.
_display_milestone_summary() {
    local claude_file="$1"
    local file_content
    file_content=$(cat "$claude_file" 2>/dev/null || true)

    local project_name
    project_name=$(echo "$file_content" | grep -m 1 '^# ' | sed 's/^# //')
    if [[ -z "$project_name" ]]; then
        project_name=$(basename "$PROJECT_DIR")
    fi

    local milestones=""
    local milestone_count=0

    # Try DAG directory first when enabled
    if [[ "${MILESTONE_DAG_ENABLED:-false}" == "true" ]] \
        && has_milestone_manifest 2>/dev/null; then
        load_manifest || true
        milestone_count=$(dag_get_count)
        if [[ "$milestone_count" -gt 0 ]]; then
            local i
            for (( i = 0; i < milestone_count; i++ )); do
                local id
                id=$(dag_get_id_at_index "$i")
                local title
                title=$(dag_get_title "$id")
                if [[ -n "$milestones" ]]; then
                    milestones="${milestones}"$'\n'"Milestone ${id}: ${title}"
                else
                    milestones="Milestone ${id}: ${title}"
                fi
            done
        fi
    fi

    # Fall back to inline CLAUDE.md headings
    if [[ "$milestone_count" -eq 0 ]]; then
        milestones=$(echo "$file_content" | grep -E '^#{2,4} Milestone [0-9]+' | sed 's/^#* //' || true)
        milestone_count=$(echo "$milestones" | grep -c '.' || true)
    fi

    header "Tekhton Plan — Milestone Summary"
    echo "  Project: ${project_name}"
    echo "  Milestones: ${milestone_count}"
    echo

    if [[ -n "$milestones" ]]; then
        echo "$milestones" | while IFS= read -r line; do
            echo "  ${line}"
        done
    else
        warn "  No milestones found in milestone directory or CLAUDE.md."
        warn "  The file may use a different heading format."
    fi

    echo
    echo "  [y] Accept and write files"
    echo "  [e] Edit CLAUDE.md in \${EDITOR:-nano}"
    echo "  [r] Re-generate with same ${DESIGN_FILE}"
    echo "  [n] Abort without writing files"
    echo
}

# _print_next_steps — Instructions printed after successful file write.
_print_next_steps() {
    echo
    success "Planning phase complete!"
    echo
    log "Your files:"
    log "  ${DESIGN_FILE}  — project design document"
    log "  CLAUDE.md  — project rules and milestone plan"
    echo
    log "Next steps:"
    log "  1. Review the generated files and make any manual edits"
    if [[ -f "${PROJECT_DIR}/.claude/pipeline.conf" ]]; then
        log "  2. Run: tekhton \"Implement Milestone 1: <title>\""
    else
        log "  2. Run: tekhton --init    (generate pipeline config & agent roles)"
        log "  3. Run: tekhton \"Implement Milestone 1: <title>\""
    fi
    echo
}

# run_plan_review — Interactive milestone review loop.
#
# Displays the milestone summary and prompts the user to accept, edit,
# re-generate, or abort. Loops until the user accepts or aborts.
#
# Returns 0 on accept, 1 on abort.
run_plan_review() {
    local claude_file="${PROJECT_DIR}/CLAUDE.md"
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"

    if [[ ! -f "$claude_file" ]]; then
        error "CLAUDE.md not found — nothing to review."
        return 1
    fi

    # Use /dev/tty for interactive input when stdin is not a terminal,
    # unless running in test mode.
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    while true; do
        _display_milestone_summary "$claude_file"
        printf "  Select [y/e/r/n]: "
        read -r choice < "$input_fd" || { warn "End of input — accepting files."; choice="y"; }
        choice="${choice//$'\r'/}"

        case "$choice" in
            y|Y)
                success "Files confirmed at ${PROJECT_DIR}:"
                log "  ${DESIGN_FILE}"
                log "  CLAUDE.md"
                _print_next_steps
                return 0
                ;;
            e|E)
                log "Opening CLAUDE.md in editor..."
                "${EDITOR:-nano}" "$claude_file" || warn "Editor exited with non-zero status"
                log "Editor closed. Refreshing milestone summary..."
                ;;
            r|R)
                log "Re-generating CLAUDE.md from ${DESIGN_FILE}..."
                echo
                run_plan_generate || return 1
                ;;
            n|N)
                warn "Aborted. ${DESIGN_FILE} is preserved at: ${design_file}"
                warn "CLAUDE.md is preserved at: ${claude_file}"
                log "Re-run 'tekhton --plan' to try again."
                return 1
                ;;
            *)
                warn "Invalid choice '${choice}'. Please enter y, e, r, or n."
                ;;
        esac
    done
}
