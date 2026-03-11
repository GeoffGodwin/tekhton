#!/usr/bin/env bash
# =============================================================================
# plan.sh — Planning phase orchestration
#
# Provides the interactive planning flow: project type selection, template
# resolution, interactive interview, completeness check, and generation.
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
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
        # Intentionally sources the entire pipeline.conf, which imports all
        # pipeline keys (ANALYZE_CMD, BUILD_CHECK_CMD, etc.) into the planning
        # environment. This is harmless — all planning keys have safe defaults
        # and execution-only keys are unused during --plan.
        # shellcheck source=/dev/null
        source <(sed 's/\r$//' "$conf_file")
    fi
}

# Load config if available, then apply defaults for anything not set.
load_plan_config

# --- Planning config defaults ------------------------------------------------
# Overridable via environment variables or pipeline.conf.

export PLAN_INTERVIEW_MODEL="${PLAN_INTERVIEW_MODEL:-${CLAUDE_PLAN_MODEL:-sonnet}}"
export PLAN_INTERVIEW_MAX_TURNS="${PLAN_INTERVIEW_MAX_TURNS:-50}"
export PLAN_GENERATION_MODEL="${PLAN_GENERATION_MODEL:-${CLAUDE_PLAN_MODEL:-sonnet}}"
export PLAN_GENERATION_MAX_TURNS="${PLAN_GENERATION_MAX_TURNS:-30}"

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

    # Use /dev/tty when stdin is not a terminal (e.g., piped input from scripts).
    # TEKHTON_TEST_MODE disables this so tests can pipe input via stdin.
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    while true; do
        printf "  Select [1-%d]: " "${#PLAN_PROJECT_TYPES[@]}"
        read -r choice < "$input_fd"

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

# --- Batch Planning Call Helper ----------------------------------------------

# _call_planning_batch — Call claude in batch mode and print text content to stdout.
#
# Uses --output-format text so the response is plain text with no JSON parsing.
# Does NOT use --dangerously-skip-permissions — planning agents generate text
# only; the caller (shell) is responsible for writing any files.
#
# The response is tee'd to the log file and also passed through to stdout so
# the caller can capture it with output=$(_call_planning_batch ...).
#
# Usage:
#   output=$(_call_planning_batch model max_turns prompt log_file)
#   rc=$?   # claude's exit code
#
# Prints the full text response to stdout. Returns claude's exit code.
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    set +o pipefail
    claude \
        --model "$model" \
        --max-turns "$max_turns" \
        --output-format text \
        -p "$prompt" \
        < /dev/null \
        2>>"$log_file" | tee -a "$log_file"
    local -a _pst=("${PIPESTATUS[@]}")
    set -o pipefail
    return "${_pst[0]}"
}

# _extract_template_sections — Parse a template file and print section data.
#
# Output format (one line per section):   NAME|REQUIRED|GUIDANCE
#   NAME     — section heading (without "## " prefix)
#   REQUIRED — "true" or "false"
#   GUIDANCE — single-line concatenation of <!-- ... --> guidance comments
#
# Usage:
#   while IFS='|' read -r name required guidance; do
#       ...
#   done < <(_extract_template_sections "$template_file")
_extract_template_sections() {
    local template="$1"
    awk '
    BEGIN { section = ""; required = "false"; guidance = "" }
    /^## / {
        if (section != "") {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", guidance)
            print section "|" required "|" guidance
        }
        section = $0
        sub(/^## /, "", section)
        required = "false"
        guidance = ""
        if (section ~ /<!-- REQUIRED -->/) {
            required = "true"
            gsub(/[[:space:]]*<!-- REQUIRED -->[[:space:]]*/, "", section)
        }
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
        next
    }
    section != "" && /^<!-- REQUIRED -->/ { required = "true"; next }
    section != "" && /^<!--/ {
        line = $0
        gsub(/^<!--[[:space:]]*/, "", line)
        gsub(/[[:space:]]*-->$/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (length(line) > 0 && line != "REQUIRED") {
            guidance = (guidance == "") ? line : guidance " " line
        }
        next
    }
    END {
        if (section != "") {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", guidance)
            print section "|" required "|" guidance
        }
    }
    ' "$template"
}

# --- Main Entry Point --------------------------------------------------------

# run_plan — Top-level planning phase orchestrator.
# Supports resume from interrupted sessions via PLAN_STATE_FILE.
run_plan() {
    header "Tekhton — Planning Phase"
    log "This will guide you through creating DESIGN.md and CLAUDE.md for your project."
    echo

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
        select_project_type || return 1
        write_plan_state "interview" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
    fi

    # Step 2: Interactive interview (skip if resuming past this stage)
    if [[ -z "$skip_to" ]] || [[ "$skip_to" == "interview" ]]; then
        echo
        run_plan_interview || return 1
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

    # Success — clear state
    clear_plan_state
}

# --- Milestone Review UI ----------------------------------------------------

# _display_milestone_summary — Show the milestone review screen.
# Reads the file once and extracts both project name and milestones.
_display_milestone_summary() {
    local claude_file="$1"
    local file_content
    file_content=$(cat "$claude_file" 2>/dev/null || true)

    local project_name
    project_name=$(echo "$file_content" | grep -m 1 '^# ' | sed 's/^# //')
    if [[ -z "$project_name" ]]; then
        project_name=$(basename "$PROJECT_DIR")
    fi

    local milestones
    milestones=$(echo "$file_content" | grep -E '^#{2,3} Milestone [0-9]+' | sed 's/^#* //' || true)
    local milestone_count
    milestone_count=$(echo "$milestones" | grep -c '.' || true)

    header "Tekhton Plan — Milestone Summary"
    echo "  Project: ${project_name}"
    echo "  Milestones: ${milestone_count}"
    echo

    if [[ -n "$milestones" ]]; then
        echo "$milestones" | while IFS= read -r line; do
            echo "  ${line}"
        done
    else
        warn "  No milestone headings found in CLAUDE.md."
        warn "  The file may use a different heading format."
    fi

    echo
    echo "  [y] Accept and write files"
    echo "  [e] Edit CLAUDE.md in \${EDITOR:-nano}"
    echo "  [r] Re-generate with same DESIGN.md"
    echo "  [n] Abort without writing files"
    echo
}

# _print_next_steps — Instructions printed after successful file write.
_print_next_steps() {
    echo
    success "Planning phase complete!"
    echo
    log "Your files:"
    log "  DESIGN.md  — project design document"
    log "  CLAUDE.md  — project rules and milestone plan"
    echo
    log "Next steps:"
    log "  1. Review the generated files and make any manual edits"
    log "  2. Run: tekhton --init    (scaffold pipeline config)"
    log "  3. Run: tekhton \"Implement Milestone 1: <title>\""
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
    local design_file="${PROJECT_DIR}/DESIGN.md"

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
        read -r choice < "$input_fd"

        case "$choice" in
            y|Y)
                success "Files confirmed at ${PROJECT_DIR}:"
                log "  DESIGN.md"
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
                log "Re-generating CLAUDE.md from DESIGN.md..."
                echo
                run_plan_generate || return 1
                ;;
            n|N)
                warn "Aborted. DESIGN.md is preserved at: ${design_file}"
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
