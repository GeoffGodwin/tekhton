#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# replan_brownfield_apply.sh — Approval menu, delta merge, archive helpers
#
# Extracted from replan_brownfield.sh to keep that file under the 300-line
# ceiling. Sourced by replan_brownfield.sh — do not run directly.
# Provides: _brownfield_approval_menu, _apply_brownfield_delta,
#           _archive_replan_delta
# Expects: common.sh (error/warn/success/log/header), _assert_design_file_usable,
#          run_plan_generate (loaded on demand), $REPLAN_DELTA_FILE, $DESIGN_FILE
# =============================================================================

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
        echo "  Review the proposed changes in ${REPLAN_DELTA_FILE}"
        echo
        echo "  Options:"
        echo "    [a] Apply   — merge changes into ${DESIGN_FILE} and regenerate CLAUDE.md"
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

# _apply_brownfield_delta — Apply the replan delta to ${DESIGN_FILE} and regenerate CLAUDE.md.
_apply_brownfield_delta() {
    _assert_design_file_usable || return $?
    local delta_file="$1"
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"
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
        success "Delta appended to ${DESIGN_FILE}."
    else
        warn "No ${DESIGN_FILE} to update — skipping ${DESIGN_FILE} merge."
    fi

    if [[ -f "$design_file" ]]; then
        echo
        log "Regenerating CLAUDE.md from updated ${DESIGN_FILE}..."

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
                warn "Apply the CLAUDE.md delta manually from ${REPLAN_DELTA_FILE}."
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
        log "  ${DESIGN_FILE} — replan delta appended"
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
    mv "$delta_file" "${archive_dir}/$(date +%Y%m%d_%H%M%S)_$(basename "${REPLAN_DELTA_FILE}")" 2>/dev/null || true
}
