#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_answers_flow.sh — Answer file import/export flows for planning phase
#
# Handles --export-questions, --answers file import, and answer file resume.
# These are alternate entry paths into the planning pipeline that bypass or
# modify the standard interview flow.
#
# Extracted from plan.sh for size management. Sourced by plan.sh — do not
# run directly.
#
# Expects: select_project_type() from plan.sh
# Expects: export_question_template(), import_answer_file(), has_answer_file(),
#          answer_file_complete() from plan_answers.sh
# Expects: show_draft_review() from plan_review.sh
# Expects: run_plan_interview() from stages/plan_interview.sh
# Expects: run_plan_completeness_loop() from plan_completeness.sh
# Expects: run_plan_generate() from stages/plan_generate.sh
# Expects: run_plan_review() from plan_milestone_review.sh
# Expects: write_plan_state(), clear_plan_state() from plan_state.sh
# Expects: rename_answer_file_done() from plan_answers.sh
# Expects: log(), warn(), success(), error() from common.sh
# =============================================================================

# _run_plan_export_questions — Handle --export-questions flag.
# Prompts for project type, then exports question template to stdout.
_run_plan_export_questions() {
    select_project_type || return 1
    export_question_template "$PLAN_TEMPLATE_FILE"
    return 0
}

# _run_plan_with_answers_file — Handle --answers flag.
# Imports answers, prompts for project type if needed, then proceeds
# through draft review → completeness → generation → milestone review.
_run_plan_with_answers_file() {
    local answers_file="$PLAN_ANSWERS_IMPORT"

    if [[ ! -f "$answers_file" ]]; then
        error "Answer file not found: ${answers_file}"
        return 1
    fi

    # Extract template from the answer file header if possible
    local template_from_file
    template_from_file=$(grep '^# Template:' "$answers_file" 2>/dev/null | head -1 | sed 's/^# Template: *//')

    if [[ -n "$template_from_file" ]]; then
        PLAN_PROJECT_TYPE="$template_from_file"
        PLAN_TEMPLATE_FILE="${PLAN_TEMPLATES_DIR}/${PLAN_PROJECT_TYPE}.md"
        if [[ ! -f "$PLAN_TEMPLATE_FILE" ]]; then
            warn "Template '${PLAN_PROJECT_TYPE}' from answer file not found."
            select_project_type || return 1
        else
            log "Using project type from answer file: ${PLAN_PROJECT_TYPE}"
        fi
    else
        select_project_type || return 1
    fi

    # Import the answer file
    import_answer_file "$answers_file" || {
        warn "Answer file imported with incomplete required sections."
        log "You can edit sections in the draft review."
    }

    # Show draft review
    echo
    show_draft_review || return 1

    # Synthesize ${DESIGN_FILE}
    echo
    log "Synthesizing ${DESIGN_FILE} from imported answers..."
    echo
    run_plan_interview || return 1

    write_plan_state "completeness" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

    # Completeness check
    echo
    run_plan_completeness_loop || return 1
    write_plan_state "generation" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

    # CLAUDE.md generation
    echo
    run_plan_generate || return 1
    write_plan_state "review" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

    # Milestone review
    echo
    run_plan_review || return 1

    clear_plan_state
    rename_answer_file_done
}

# _offer_answer_file_resume — Check for existing answer file and offer to resume.
# Returns 0 to resume from draft_review, 1 to start fresh, 2 to abort.
_offer_answer_file_resume() {
    echo
    log "Found existing planning answers: ${PLAN_ANSWER_FILE}"

    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    log "  [r] Resume — review and complete existing answers"
    log "  [f] Start fresh (discard saved answers)"
    log "  [n] Abort"
    printf "  Select [r/f/n]: "

    local choice
    read -r choice < "$input_fd" || return 2
    choice="${choice//$'\r'/}"

    case "$choice" in
        r|R)
            # Extract project type from answer file
            local saved_template
            saved_template=$(grep '^# Template:' "$PLAN_ANSWER_FILE" 2>/dev/null | head -1 | sed 's/^# Template: *//')
            if [[ -n "$saved_template" ]]; then
                PLAN_PROJECT_TYPE="$saved_template"
                PLAN_TEMPLATE_FILE="${PLAN_TEMPLATES_DIR}/${PLAN_PROJECT_TYPE}.md"
                if [[ ! -f "$PLAN_TEMPLATE_FILE" ]]; then
                    warn "Saved template '${PLAN_PROJECT_TYPE}' not found."
                    select_project_type || return 2
                fi
            else
                select_project_type || return 2
            fi
            # shellcheck disable=SC2034
            PLAN_RESUME_STAGE="draft_review"
            write_plan_state "draft_review" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
            success "Resuming with existing answers."
            return 0
            ;;
        f|F)
            rm -f "$PLAN_ANSWER_FILE"
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}
