#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# lib/intake_verdict_handlers.sh — Intake verdict handler functions
#
# Verdict-specific logic for TWEAKED, SPLIT_RECOMMENDED, and NEEDS_CLARITY.
# Extracted from lib/intake_helpers.sh to stay within the 300-line ceiling.
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TEKHTON_SESSION_DIR, MILESTONE_DIR, MILESTONE_DAG_ENABLED,
#          MILESTONE_MODE, _CURRENT_MILESTONE, TASK, PROJECT_DIR,
#          INTAKE_CONFIRM_TWEAKS, INTAKE_AUTO_SPLIT from the pipeline environment.
# Expects: log(), warn(), success(), header() from common.sh
# Expects: write_pipeline_state() from state.sh
# Expects: _intake_parse_tweaks(), _intake_parse_questions(),
#          _intake_apply_tweak_milestone(), _intake_apply_tweak_task()
#          from intake_helpers.sh
# =============================================================================

# --- Verdict handlers ---------------------------------------------------------

# _intake_handle_tweaked — Apply tweaks and optionally confirm with user.
# Expects: report_file, MILESTONE_MODE, _CURRENT_MILESTONE, INTAKE_CONFIRM_TWEAKS,
#          TASK from caller scope.
_intake_handle_tweaked() {
    local report_file="$1"

    local tweaks
    tweaks=$(_intake_parse_tweaks "$report_file")
    export INTAKE_TWEAKS_BLOCK="$tweaks"

    if [[ "$MILESTONE_MODE" == true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        _intake_apply_tweak_milestone "$tweaks" "$_CURRENT_MILESTONE" || true
    else
        _intake_apply_tweak_task "$tweaks" || true
    fi

    if [[ "${INTAKE_CONFIRM_TWEAKS:-false}" == "true" ]]; then
        log "Intake: tweaks applied. Review required (INTAKE_CONFIRM_TWEAKS=true)."
        echo
        echo "PM Agent tweaked the task. Changes:"
        echo "────────────────────────────────────────"
        echo "$tweaks" | head -40
        echo "────────────────────────────────────────"
        echo
        log "Accept tweaks and continue? [y/n]"
        local choice
        if [[ -t 0 ]]; then
            read -r choice
        else
            read -r choice < /dev/tty 2>/dev/null || choice="y"
        fi
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            warn "Tweaks rejected by user. Saving state."
            write_pipeline_state "intake" "tweaks_rejected" \
                "--milestone --start-at coder" "$TASK" \
                "Intake tweaks rejected — edit milestone and re-run" \
                "${_CURRENT_MILESTONE:-}"
            exit 1
        fi
    fi

    success "Intake: tweaks applied. Proceeding."
}

# _intake_handle_split_recommended — Present split recommendation and handle user choice.
_intake_handle_split_recommended() {
    local report_file="$1"

    log "Intake: split recommended."

    if [[ "${INTAKE_AUTO_SPLIT:-false}" == "true" ]] \
       && [[ "$MILESTONE_MODE" == true ]] \
       && [[ -n "${_CURRENT_MILESTONE:-}" ]] \
       && declare -f split_milestone &>/dev/null; then
        log "Intake: auto-splitting milestone ${_CURRENT_MILESTONE}..."
        if split_milestone "$_CURRENT_MILESTONE" "${PROJECT_RULES_FILE:-CLAUDE.md}"; then
            success "Intake: milestone split successfully."
            # Switch to first sub-milestone
            if declare -f _switch_to_sub_milestone &>/dev/null; then
                _switch_to_sub_milestone "$_CURRENT_MILESTONE" "${PROJECT_RULES_FILE:-CLAUDE.md}"
            fi
            return 0
        else
            warn "Intake: auto-split failed. Escalating to human."
        fi
    fi

    # Present split recommendation to human
    echo
    header "Intake: Split Recommended"
    echo "The PM agent recommends splitting this milestone."
    echo
    if [[ -f "$report_file" ]]; then
        awk '/^## Split Recommendations/{found=1; next} found && /^## /{exit} found{print}' "$report_file" 2>/dev/null | head -30 || true
    fi
    echo
    log "Options: [s]plit now, [c]ontinue anyway, [q]uit"
    local choice
    if [[ -t 0 ]]; then
        read -r choice
    else
        read -r choice < /dev/tty 2>/dev/null || choice="c"
    fi
    case "$choice" in
        s|S)
            if declare -f split_milestone &>/dev/null && [[ "$MILESTONE_MODE" == true ]]; then
                split_milestone "$_CURRENT_MILESTONE" "${PROJECT_RULES_FILE:-CLAUDE.md}" || true
                if declare -f _switch_to_sub_milestone &>/dev/null; then
                    _switch_to_sub_milestone "$_CURRENT_MILESTONE" "${PROJECT_RULES_FILE:-CLAUDE.md}"
                fi
            else
                warn "Split not available (not in milestone mode or split_milestone not loaded)."
            fi
            ;;
        q|Q)
            warn "Pipeline paused by user."
            write_pipeline_state "intake" "split_declined" \
                "--milestone --start-at coder" "$TASK" \
                "Intake recommended split — user chose to quit" \
                "${_CURRENT_MILESTONE:-}"
            exit 1
            ;;
        *)
            log "Continuing without split."
            ;;
    esac
}

# _intake_handle_needs_clarity — Handle NEEDS_CLARITY verdict.
_intake_handle_needs_clarity() {
    local report_file="$1"

    log "Intake: needs clarification."
    local questions
    questions=$(_intake_parse_questions "$report_file")

    if [[ -n "$questions" ]]; then
        # Write questions to CLARIFICATIONS.md using existing protocol
        local clarify_file="${PROJECT_DIR}/CLARIFICATIONS.md"
        {
            echo ""
            echo "# Intake Clarifications — $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "$questions"
            echo ""
        } >> "$clarify_file"

        # In --complete (autonomous) mode, never attempt interactive
        # clarification — save state so the human can answer offline.
        if [[ "${COMPLETE_MODE:-false}" == "true" ]]; then
            warn "Intake: questions written to CLARIFICATIONS.md."
            warn "Cannot collect answers in --complete mode (autonomous). Saving state."
            write_pipeline_state "intake" "needs_clarity" \
                "--milestone --start-at coder" "$TASK" \
                "Intake needs human clarification — answer CLARIFICATIONS.md and re-run" \
                "${_CURRENT_MILESTONE:-}"
            exit 1
        fi

        # Interactive mode: use existing clarification handler if available
        if declare -f handle_clarifications &>/dev/null; then
            # Write questions to temp file for the handler
            echo "$questions" | sed 's/^- //' | sed '/^$/d' \
                > "${TEKHTON_SESSION_DIR}/clarify_blocking.txt"
            : > "${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"
            if ! handle_clarifications; then
                warn "Clarification aborted. Saving state."
                write_pipeline_state "intake" "needs_clarity" \
                    "--milestone --start-at coder" "$TASK" \
                    "Intake needs human clarification" \
                    "${_CURRENT_MILESTONE:-}"
                exit 1
            fi
            success "Clarifications recorded. Proceeding."
        else
            warn "Intake: questions written to CLARIFICATIONS.md."
            warn "Answer the questions and re-run the pipeline."
            write_pipeline_state "intake" "needs_clarity" \
                "--milestone --start-at coder" "$TASK" \
                "Intake needs human clarification" \
                "${_CURRENT_MILESTONE:-}"
            exit 1
        fi
    else
        warn "Intake: NEEDS_CLARITY but no questions found in report. Proceeding cautiously."
    fi
}
