#!/usr/bin/env bash
# =============================================================================
# plan.sh — Planning phase orchestration
#
# Provides the interactive planning flow: project type selection, template
# resolution, and (in later milestones) interview, completeness check,
# CLAUDE.md generation, and milestone review.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# =============================================================================

# --- Constants ---------------------------------------------------------------

PLAN_TEMPLATES_DIR="${TEKHTON_HOME}/templates/plans"

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

    local choice
    while true; do
        printf "  Select [1-%d]: " "${#PLAN_PROJECT_TYPES[@]}"
        read -r choice

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

# --- Main Entry Point --------------------------------------------------------

# run_plan — Top-level planning phase orchestrator.
# Called from the --plan early-exit block in tekhton.sh.
run_plan() {
    header "Tekhton — Planning Phase"
    log "This will guide you through creating DESIGN.md and CLAUDE.md for your project."
    echo

    # Step 1: Project type selection
    select_project_type || return 1

    # Future milestones will add:
    # Step 2: Interactive interview (Milestone 2)
    # Step 3: Completeness check (Milestone 3)
    # Step 4: CLAUDE.md generation (Milestone 4)
    # Step 5: Milestone review + file output (Milestone 5)

    echo
    success "Project type '${PLAN_PROJECT_TYPE}' selected."
    log "Template resolved: ${PLAN_TEMPLATE_FILE}"
    echo
    log "Next milestone will add the interactive interview stage."
}
