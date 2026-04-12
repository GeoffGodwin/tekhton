#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan.sh — Planning phase orchestration
#
# Provides the interactive planning flow: project type selection, template
# resolution, interactive interview, completeness check, and generation.
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
#
# Sub-modules (sourced below):
#   plan_batch.sh           — _call_planning_batch(), _extract_template_sections()
#   plan_milestone_review.sh — run_plan_review(), _display_milestone_summary()
#   plan_answers_flow.sh    — _run_plan_export_questions(), _run_plan_with_answers_file(),
#                             _offer_answer_file_resume()
# =============================================================================

# --- Constants ---------------------------------------------------------------

PLAN_TEMPLATES_DIR="${TEKHTON_HOME}/templates/plans"
# Used by lib/plan_state.sh (sourced separately)
# shellcheck disable=SC2034
PLAN_STATE_FILE="${PROJECT_DIR:-}/.claude/PLAN_STATE.md"

# --- Planning config loader --------------------------------------------------
# Reads planning-specific keys from pipeline.conf if it exists. Called before
# applying defaults so pipeline.conf values take precedence over env vars.

load_plan_config() {
    local conf_file="${PROJECT_DIR:-}/.claude/pipeline.conf"
    if [[ -f "$conf_file" ]]; then
        # Use the safe config parser from config.sh if available (execution pipeline),
        # otherwise use a minimal inline parser (--plan mode, config.sh not sourced).
        if declare -f _parse_config_file &>/dev/null; then
            _parse_config_file "$conf_file"
        else
            # Minimal safe parser for --plan mode: reads key=value lines,
            # rejects command substitution ($( and backticks).
            local _line_num=0
            while IFS= read -r _line || [[ -n "$_line" ]]; do
                _line_num=$((_line_num + 1))
                _line="${_line//$'\r'/}"
                [[ -z "$_line" ]] && continue
                [[ "$_line" =~ ^[[:space:]]*# ]] && continue
                if ! [[ "$_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
                    continue
                fi
                local _key="${BASH_REMATCH[1]}"
                local _val="${BASH_REMATCH[2]}"
                _val="${_val#"${_val%%[![:space:]]*}"}"
                _val="${_val%"${_val##*[![:space:]]}"}"
                if [[ "$_val" =~ ^\"(.*)\"$ ]]; then
                    _val="${BASH_REMATCH[1]}"
                elif [[ "$_val" =~ ^\'(.*)\'$ ]]; then
                    _val="${BASH_REMATCH[1]}"
                fi
                if [[ "$_val" == *"\$("* ]] || [[ "$_val" == *"\`"* ]]; then
                    echo "[✗] pipeline.conf:${_line_num}: REJECTED — value for '${_key}' contains command substitution." >&2
                    exit 1
                fi
                declare -gx "$_key=$_val"
            done < "$conf_file"
        fi
    fi
}

# Load config if available, then apply defaults for anything not set.
load_plan_config

# --- Planning config defaults ------------------------------------------------
# Overridable via environment variables or pipeline.conf.

export PLAN_INTERVIEW_MODEL="${PLAN_INTERVIEW_MODEL:-${CLAUDE_PLAN_MODEL:-opus}}"
export PLAN_INTERVIEW_MAX_TURNS="${PLAN_INTERVIEW_MAX_TURNS:-50}"
export PLAN_GENERATION_MODEL="${PLAN_GENERATION_MODEL:-${CLAUDE_PLAN_MODEL:-opus}}"
export PLAN_GENERATION_MAX_TURNS="${PLAN_GENERATION_MAX_TURNS:-50}"

# Project types — order matches the menu display
PLAN_PROJECT_TYPES=(
    "web-app"
    "web-game"
    "cli-tool"
    "api-service"
    "mobile-app"
    "library"
    "custom"
)

PLAN_PROJECT_LABELS=(
    "Web Application      (React, Next.js, Django, Rails, etc.)"
    "Web Game              (browser-based game with HTML5/Canvas/WebGL)"
    "CLI Tool              (command-line utility or developer tool)"
    "API Service           (REST/GraphQL backend, microservice)"
    "Mobile App            (iOS, Android, React Native, Flutter)"
    "Library / Package     (reusable module published to a registry)"
    "Custom                (anything else — minimal template)"
)

# --- Source extracted sub-modules --------------------------------------------

source "${TEKHTON_HOME}/lib/plan_batch.sh"
source "${TEKHTON_HOME}/lib/plan_milestone_review.sh"
source "${TEKHTON_HOME}/lib/plan_answers_flow.sh"

# --- Project Type Selection --------------------------------------------------

# Displays the project type menu and reads the user's choice.
# Sets PLAN_PROJECT_TYPE and PLAN_TEMPLATE_FILE on success.
select_project_type() {
    echo
    header "Tekhton Plan — Project Type Selection"
    echo "  What kind of project are you building?"
    echo

    local i
    for i in "${!PLAN_PROJECT_TYPES[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${PLAN_PROJECT_LABELS[$i]}"
    done
    echo

    # Use /dev/tty when stdin is not a terminal (e.g., piped input from scripts).
    # TEKHTON_TEST_MODE disables this so tests can pipe input via stdin.
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    while true; do
        printf "  Select [1-%d]: " "${#PLAN_PROJECT_TYPES[@]}"
        read -r choice < "$input_fd" || { error "Unexpected end of input."; return 1; }
        choice="${choice//$'\r'/}"

        # Validate: must be a number in range
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [ "$choice" -ge 1 ] && \
           [ "$choice" -le "${#PLAN_PROJECT_TYPES[@]}" ]; then
            PLAN_PROJECT_TYPE="${PLAN_PROJECT_TYPES[$((choice - 1))]}"
            PLAN_TEMPLATE_FILE="${PLAN_TEMPLATES_DIR}/${PLAN_PROJECT_TYPE}.md"

            if [ ! -f "$PLAN_TEMPLATE_FILE" ]; then
                error "Template not found: ${PLAN_TEMPLATE_FILE}"
                error "This is a bug in Tekhton — the template should exist."
                return 1
            fi

            success "Selected: ${PLAN_PROJECT_TYPE}"
            log "Template: ${PLAN_TEMPLATE_FILE}"
            return 0
        else
            warn "Invalid choice '${choice}'. Please enter a number between 1 and ${#PLAN_PROJECT_TYPES[@]}."
        fi
    done
}

# --- Completeness Check ------------------------------------------------------
# Extracted to lib/plan_completeness.sh — sourced separately by tekhton.sh.

# --- Planning State Persistence ----------------------------------------------
# Extracted to lib/plan_state.sh — sourced separately by tekhton.sh.

# --- Brownfield Replan --------------------------------------------------------
# Extracted to lib/replan.sh — sourced separately by tekhton.sh.

# --- Main Entry Point --------------------------------------------------------

# run_plan — Top-level planning phase orchestrator.
# Supports resume from interrupted sessions via PLAN_STATE_FILE.
# Checks for --export-questions and --answers flags via globals.
run_plan() {
    # Handle --export-questions early exit
    if [[ -n "${PLAN_EXPORT_QUESTIONS:-}" ]]; then
        _run_plan_export_questions
        return $?
    fi

    header "Tekhton — Planning Phase"
    log "This will guide you through creating ${DESIGN_FILE} and CLAUDE.md for your project."
    echo

    # Handle --answers: import file mode
    if [[ -n "${PLAN_ANSWERS_IMPORT:-}" ]]; then
        _run_plan_with_answers_file
        return $?
    fi

    # Check for interrupted session and offer resume
    local resume_rc=0
    _offer_plan_resume || resume_rc=$?

    if [[ "$resume_rc" -eq 2 ]]; then
        # User aborted
        return 1
    fi

    local skip_to="${PLAN_RESUME_STAGE:-}"

    # Step 1: Project type selection (skip if resuming past this stage)
    if [[ -z "$skip_to" ]]; then
        # Check for existing answer file before project type selection
        if has_answer_file; then
            _offer_answer_file_resume || {
                local rc=$?
                if [[ "$rc" -eq 2 ]]; then return 1; fi
                # rc=1 means start fresh — continue to project type selection
            }
            if [[ -n "${PLAN_RESUME_STAGE:-}" ]]; then
                skip_to="$PLAN_RESUME_STAGE"
            fi
        fi
    fi

    if [[ -z "$skip_to" ]]; then
        select_project_type || return 1
        write_plan_state "interview" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
    fi

    # Step 2: Interactive interview (skip if resuming past this stage)
    if [[ -z "$skip_to" ]] || [[ "$skip_to" == "interview" ]]; then
        echo
        run_plan_interview || return 1
        write_plan_state "draft_review" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
        skip_to=""
    fi

    # Step 2.5: Draft review before synthesis
    if [[ -z "$skip_to" ]] || [[ "$skip_to" == "draft_review" ]]; then
        echo
        show_draft_review || return 1
        write_plan_state "completeness" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
        skip_to=""
    fi

    # Step 3: Completeness check + follow-up loop
    if [[ -z "$skip_to" ]] || [[ "$skip_to" == "completeness" ]]; then
        echo
        run_plan_completeness_loop || return 1
        write_plan_state "generation" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
        skip_to=""
    fi

    # Step 4: CLAUDE.md generation
    if [[ -z "$skip_to" ]] || [[ "$skip_to" == "generation" ]]; then
        echo
        run_plan_generate || return 1
        write_plan_state "review" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
        skip_to=""
    fi

    # Step 5: Milestone review + file output
    # No skip_to guard — review is always the final step after generation,
    # so we always run it regardless of resume state.
    echo
    run_plan_review || return 1

    # Success — clear state and rename answer file
    clear_plan_state
    rename_answer_file_done
}
