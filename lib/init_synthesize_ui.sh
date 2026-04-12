#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2153
# =============================================================================
# init_synthesize_ui.sh — UI functions for project synthesis review
#
# Extracted from lib/init_synthesize_helpers.sh to keep both files under
# the 300-line ceiling. Sourced by init_synthesize_helpers.sh (which is
# transitively loaded by stages/init_synthesize.sh) — do not run directly.
#
# Expects: log(), warn(), success(), header() from common.sh
#
# Provides:
#   _synthesis_review_menu       — interactive review menu [a/e/d/r/n]
#   _print_synthesis_next_steps  — post-synthesis instructions
# =============================================================================

# _synthesis_review_menu — Displays [a]ccept / [e]dit / [r]egenerate menu.
#
# Args: $1 = project directory
# Returns: 0 on accept, 1 on abort
_synthesis_review_menu() {
    local project_dir="$1"
    local design_file="${project_dir}/${DESIGN_FILE}"
    local claude_file="${project_dir}/CLAUDE.md"

    # Use /dev/tty for interactive input when stdin is not a terminal
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    while true; do
        echo
        header "Project Synthesis — Review"

        if [[ -f "$design_file" ]]; then
            local design_lines
            design_lines=$(wc -l < "$design_file" | tr -d '[:space:]')
            log "${DESIGN_FILE}: ${design_lines} lines"
        fi

        if [[ -f "$claude_file" ]]; then
            local claude_lines milestones
            claude_lines=$(wc -l < "$claude_file" | tr -d '[:space:]')
            milestones=$(grep -c -E '^#{2,3} Milestone [0-9]+' "$claude_file" || true)
            log "CLAUDE.md: ${claude_lines} lines, ${milestones} milestones"
        fi

        echo
        echo "  [a] Accept — keep generated files"
        echo "  [e] Edit — open CLAUDE.md in \${EDITOR:-nano}"
        echo "  [d] Edit ${DESIGN_FILE} — open ${DESIGN_FILE} in \${EDITOR:-nano}"
        echo "  [r] Regenerate — re-run CLAUDE.md synthesis from ${DESIGN_FILE}"
        echo "  [n] Abort — discard generated files"
        echo
        printf "  Select [a/e/d/r/n]: "
        read -r choice < "$input_fd" || { warn "End of input — accepting files."; choice="a"; }
        choice="${choice//$'\r'/}"

        case "$choice" in
            a|A)
                success "Files accepted at ${project_dir}:"
                log "  ${DESIGN_FILE}"
                log "  CLAUDE.md"
                _print_synthesis_next_steps
                return 0
                ;;
            e|E)
                if [[ -f "$claude_file" ]]; then
                    log "Opening CLAUDE.md in editor..."
                    "${EDITOR:-nano}" "$claude_file" || warn "Editor exited with non-zero status"
                else
                    warn "CLAUDE.md not found."
                fi
                ;;
            d|D)
                if [[ -f "$design_file" ]]; then
                    log "Opening ${DESIGN_FILE} in editor..."
                    "${EDITOR:-nano}" "$design_file" || warn "Editor exited with non-zero status"
                else
                    warn "${DESIGN_FILE} not found."
                fi
                ;;
            r|R)
                log "Re-generating CLAUDE.md from ${DESIGN_FILE}..."
                _synthesize_claude "$project_dir" || warn "Re-generation failed."
                ;;
            n|N)
                warn "Aborted."
                if [[ -f "$design_file" ]]; then
                    warn "${DESIGN_FILE} preserved at: ${design_file}"
                fi
                if [[ -f "$claude_file" ]]; then
                    warn "CLAUDE.md preserved at: ${claude_file}"
                fi
                return 1
                ;;
            *)
                warn "Invalid choice '${choice}'. Please enter a, e, d, r, or n."
                ;;
        esac
    done
}

# _print_synthesis_next_steps — Instructions after successful synthesis.
_print_synthesis_next_steps() {
    echo
    success "Project synthesis complete!"
    echo
    log "Your files:"
    log "  ${DESIGN_FILE}  — project design document (synthesized from codebase)"
    log "  CLAUDE.md  — project rules and improvement plan"
    echo
    log "Next steps:"
    log "  1. Review the generated files and make any manual edits"
    log "  2. Add feature milestones to CLAUDE.md as needed"
    log "  3. Run: tekhton \"Implement Milestone 1: <title>\""
    echo
}
