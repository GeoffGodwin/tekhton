#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_state.sh — Planning phase state persistence for resume support
#
# Provides save/restore/clear functions for interrupted --plan sessions,
# plus the resume offer UI. Extracted from lib/plan.sh to keep files
# under 300 lines.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_STATE_FILE, PROJECT_DIR from plan.sh
# Expects: PLAN_PROJECT_TYPE, PLAN_TEMPLATE_FILE (set during planning flow)
# Expects: log(), success(), warn(), error(), header() from common.sh
# Expects: select_project_type() from plan.sh
# =============================================================================

# --- Planning State Persistence ----------------------------------------------

# write_plan_state — Save planning session state for resume.
# Args: stage, project_type, template_file
write_plan_state() {
    local stage="$1"
    local project_type="${2:-}"
    local template_file="${3:-}"

    local state_dir
    state_dir="$(dirname "$PLAN_STATE_FILE")"
    mkdir -p "$state_dir" 2>/dev/null || true

    local tmp_state
    tmp_state="$(mktemp "${state_dir}/plan_state.XXXXXX" 2>/dev/null || mktemp /tmp/plan_state.XXXXXX)"

    # Unquoted heredoc — ${PROJECT_DIR} and subshells are expanded by the
    # outer shell at write time, not written literally into the state file.
    cat > "$tmp_state" << EOF
# Planning State — $(date '+%Y-%m-%d %H:%M:%S')
## Stage
${stage}

## Project Type
${project_type}

## Template File
${template_file}

## Files Present
$([ -f "${PROJECT_DIR}/DESIGN.md" ] && echo "- DESIGN.md ($(wc -l < "${PROJECT_DIR}/DESIGN.md" | tr -d '[:space:]') lines)" || echo "- DESIGN.md (missing)")
$([ -f "${PROJECT_DIR}/CLAUDE.md" ] && echo "- CLAUDE.md ($(wc -l < "${PROJECT_DIR}/CLAUDE.md" | tr -d '[:space:]') lines)" || echo "- CLAUDE.md (missing)")
EOF

    if mv -f "$tmp_state" "$PLAN_STATE_FILE" 2>/dev/null; then
        log "Planning state saved → ${PLAN_STATE_FILE}"
    else
        warn "Could not save planning state to ${PLAN_STATE_FILE}"
        rm -f "$tmp_state" 2>/dev/null || true
    fi
}

# read_plan_state — Load saved planning state. Sets PLAN_SAVED_STAGE,
# PLAN_SAVED_PROJECT_TYPE, PLAN_SAVED_TEMPLATE_FILE.
# Returns 0 if state file exists and was read, 1 otherwise.
read_plan_state() {
    PLAN_SAVED_STAGE=""
    PLAN_SAVED_PROJECT_TYPE=""
    PLAN_SAVED_TEMPLATE_FILE=""

    if [[ ! -f "$PLAN_STATE_FILE" ]]; then
        return 1
    fi

    PLAN_SAVED_STAGE=$(awk '/^## Stage$/{getline; print; exit}' "$PLAN_STATE_FILE")
    PLAN_SAVED_PROJECT_TYPE=$(awk '/^## Project Type$/{getline; print; exit}' "$PLAN_STATE_FILE")
    PLAN_SAVED_TEMPLATE_FILE=$(awk '/^## Template File$/{getline; print; exit}' "$PLAN_STATE_FILE")
    return 0
}

# clear_plan_state — Remove the planning state file.
clear_plan_state() {
    if [[ -f "$PLAN_STATE_FILE" ]]; then
        rm -f "$PLAN_STATE_FILE"
        log "Planning state cleared."
    fi
}

# _offer_plan_resume — Check for saved state and prompt the user.
# Sets PLAN_RESUME_STAGE on resume, or clears state on restart.
# Returns 0 if resuming (caller should skip to saved stage),
# returns 1 if starting fresh, returns 2 if user aborted.
_offer_plan_resume() {
    PLAN_RESUME_STAGE=""

    if ! read_plan_state; then
        # No state file — also check for existing DESIGN.md without state
        if [[ -f "${PROJECT_DIR}/DESIGN.md" ]]; then
            echo
            warn "Found existing DESIGN.md but no saved planning state."
            log "  [r] Resume from completeness check (use existing DESIGN.md)"
            log "  [f] Start fresh (existing DESIGN.md will be overwritten)"
            log "  [n] Abort"
            printf "  Select [r/f/n]: "

            local input_fd="/dev/stdin"
            if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
                input_fd="/dev/tty"
            fi

            local choice
            read -r choice < "$input_fd"
            case "$choice" in
                r|R)
                    # Need project type to resume — ask for it
                    select_project_type || return 2
                    PLAN_RESUME_STAGE="completeness"
                    return 0
                    ;;
                f|F) return 1 ;;
                *)   return 2 ;;
            esac
        fi
        return 1
    fi

    # State file exists — show it and offer resume
    echo
    warn "Found interrupted planning session:"
    echo "────────────────────────────────────────"
    cat "$PLAN_STATE_FILE"
    echo "────────────────────────────────────────"
    echo
    log "  [y] Resume from ${PLAN_SAVED_STAGE} stage"
    log "  [f] Start fresh (discard saved state)"
    log "  [n] Abort"
    printf "  Select [y/f/n]: "

    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    read -r choice < "$input_fd"
    case "$choice" in
        y|Y)
            # Restore saved state
            PLAN_PROJECT_TYPE="$PLAN_SAVED_PROJECT_TYPE"
            PLAN_TEMPLATE_FILE="$PLAN_SAVED_TEMPLATE_FILE"
            PLAN_RESUME_STAGE="$PLAN_SAVED_STAGE"

            # Validate template still exists
            if [[ -n "$PLAN_TEMPLATE_FILE" ]] && [[ ! -f "$PLAN_TEMPLATE_FILE" ]]; then
                error "Saved template no longer exists: ${PLAN_TEMPLATE_FILE}"
                clear_plan_state
                return 1
            fi

            success "Resuming from ${PLAN_RESUME_STAGE} stage (${PLAN_PROJECT_TYPE})"
            return 0
            ;;
        f|F)
            clear_plan_state
            return 1
            ;;
        *)
            log "Aborted. Planning state preserved for next time."
            return 2
            ;;
    esac
}
