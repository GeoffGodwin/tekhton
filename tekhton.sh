#!/usr/bin/env bash
# =============================================================================
# tekhton.sh — Multi-agent development pipeline
#
# Tekhton — "One intent. Many hands."
#
# Usage:
#   tekhton "Implement feature X"
#   tekhton --start-at review "Fix: edge case in module Y"
#   tekhton --start-at test "Fix: edge case in module Y"
#   tekhton --init                    # First-time setup in a new project
#   tekhton --plan                    # Interactive planning phase
#
# Flags:
#   --init                Scaffold pipeline config + agent roles for a new project
#   --plan                Interactive planning: build DESIGN.md + CLAUDE.md from scratch
#   --status              Print saved pipeline state and exit
#   --milestone           Milestone mode: higher turn limits, more review cycles
#   --start-at coder      Full pipeline from scratch (default)
#   --start-at review     Skip coder; requires CODER_SUMMARY.md
#   --start-at tester     Resume tester from existing TESTER_REPORT.md
#   --start-at test       Skip coder + reviewer; requires REVIEWER_REPORT.md
#   --notes-filter X      Inject only [X] notes (BUG, FEAT, POLISH)
#   --init-notes          Create blank HUMAN_NOTES.md template
#   --skip-audit          Skip architect audit even if threshold is reached
#   --force-audit         Force architect audit regardless of threshold
#
# Requirements:
#   - claude CLI authenticated and on PATH
#   - Run from the target project root (where your CLAUDE.md lives)
#   - .claude/pipeline.conf in the target project (created by --init)
# =============================================================================

set -euo pipefail

# --- Crash diagnostics -------------------------------------------------------
# Catch unexpected exits (from set -e, pipefail, or unset variables) and print
# a diagnostic message pointing to the source. Fires on EXIT so it catches
# everything, but only prints when exit code is non-zero.
_TEKHTON_CLEAN_EXIT=false  # set to true for expected non-zero exits (usage, abort)

_tekhton_cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ "$_TEKHTON_CLEAN_EXIT" != true ]; then
        echo >&2
        echo -e "\033[0;31m[✗] ══════════════════════════════════════\033[0m" >&2
        echo -e "\033[0;31m[✗]   PIPELINE CRASHED (exit code: ${exit_code})\033[0m" >&2
        echo -e "\033[0;31m[✗] ══════════════════════════════════════\033[0m" >&2
        echo -e "\033[0;31m[✗] Last command: ${BASH_COMMAND:-unknown}\033[0m" >&2
        echo -e "\033[0;31m[✗] Source:       ${BASH_SOURCE[1]:-unknown}:${BASH_LINENO[0]:-?}\033[0m" >&2
        echo -e "\033[0;31m[✗] Task:         ${TASK:-not set}\033[0m" >&2
        if [ -n "${LOG_FILE:-}" ]; then
            echo -e "\033[0;31m[✗] Log:          ${LOG_FILE}\033[0m" >&2
        fi
        echo -e "\033[0;31m[✗]\033[0m" >&2
        echo -e "\033[0;31m[✗] This is likely a command that returned non-zero under\033[0m" >&2
        echo -e "\033[0;31m[✗] 'set -euo pipefail'. Common causes: grep found no\033[0m" >&2
        echo -e "\033[0;31m[✗] matches, unset variable, or a pipeline component failed.\033[0m" >&2
        echo >&2

        # --- Crash cleanup: archive transient artifacts -----------------------
        # ARCHITECT_PLAN.md is a single-run artifact — archive it if it exists
        if [ -n "${LOG_DIR:-}" ] && [ -n "${TIMESTAMP:-}" ] && [ -f "ARCHITECT_PLAN.md" ]; then
            mv "ARCHITECT_PLAN.md" "${LOG_DIR}/${TIMESTAMP}_ARCHITECT_PLAN.md" 2>/dev/null || true
            echo -e "\033[0;31m[✗] Archived ARCHITECT_PLAN.md to logs before exit.\033[0m" >&2
        fi

        # Reset any in-progress [~] human notes back to [ ] so next run starts clean
        if [ -f "HUMAN_NOTES.md" ]; then
            sed -i 's/^- \[~\] /- [ ] /' HUMAN_NOTES.md 2>/dev/null || true
            echo -e "\033[0;31m[✗] Reset in-progress [~] human notes back to [ ].\033[0m" >&2
        fi
    fi
}
trap _tekhton_cleanup EXIT

# --- Path resolution ---------------------------------------------------------
# TEKHTON_HOME: where this script (and lib/, stages/, prompts/) lives.
# PROJECT_DIR:  the target project — always the caller's working directory.

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

export TEKHTON_HOME
export PROJECT_DIR

# --- Pre-library globals -----------------------------------------------------

NOTES_FILTER=""
MILESTONE_MODE=false
SKIP_AUDIT=false
FORCE_AUDIT=false
SKIP_FINAL_CHECKS=false
TOTAL_TURNS=0
TOTAL_TIME=0
STAGE_SUMMARY=""

# --- Early --init check (runs before config exists) --------------------------

if [ "${1:-}" = "--init" ]; then
    source "${TEKHTON_HOME}/lib/common.sh"

    CONF_DIR="${PROJECT_DIR}/.claude"
    CONF_FILE="${CONF_DIR}/pipeline.conf"

    if [ -f "$CONF_FILE" ]; then
        warn "pipeline.conf already exists at ${CONF_FILE}"
        warn "To reinitialize, delete it first."
        exit 1
    fi

    header "Tekhton Init — Scaffolding project structure"

    # Create directories — only what the project needs
    mkdir -p "${CONF_DIR}/agents"
    mkdir -p "${CONF_DIR}/logs/archive"

    # Copy config template
    cp "${TEKHTON_HOME}/templates/pipeline.conf.example" "$CONF_FILE"

    # Auto-set DESIGN_FILE if DESIGN.md exists (e.g., from a prior --plan run)
    if [[ -f "${PROJECT_DIR}/DESIGN.md" ]]; then
        sed -i 's/^DESIGN_FILE=""$/DESIGN_FILE="DESIGN.md"/' "$CONF_FILE"
        success "Created ${CONF_FILE} (DESIGN_FILE set to DESIGN.md)"
    else
        success "Created ${CONF_FILE}"
    fi

    # Install agent role templates (only if they don't already exist)
    for role in coder reviewer tester jr-coder architect; do
        TARGET="${CONF_DIR}/agents/${role}.md"
        if [ ! -f "$TARGET" ] && [ -f "${TEKHTON_HOME}/templates/${role}.md" ]; then
            cp "${TEKHTON_HOME}/templates/${role}.md" "$TARGET"
            success "Created agent role file: .claude/agents/${role}.md"
        else
            log "Skipped .claude/agents/${role}.md (already exists)"
        fi
    done

    # Create stub CLAUDE.md if it doesn't exist
    if [ ! -f "${PROJECT_DIR}/CLAUDE.md" ]; then
        cat > "${PROJECT_DIR}/CLAUDE.md" << 'RULES_EOF'
# Project Rules

This file contains the non-negotiable rules for this project.
All agents read this file. Keep it authoritative and concise.

## Architecture Rules
<!-- Add your architecture rules here -->

## Code Style
<!-- Add your code style rules here -->

## Testing Requirements
<!-- Add your testing requirements here -->
RULES_EOF
        success "Created CLAUDE.md (project rules stub)"
    fi

    echo
    header "Init Complete"
    echo "  Tekhton home: ${TEKHTON_HOME}"
    echo "  Project:      ${PROJECT_DIR}"
    echo
    echo "  Next steps:"
    echo "  1. Edit .claude/pipeline.conf — set PROJECT_NAME, REQUIRED_TOOLS,"
    echo "     ANALYZE_CMD, TEST_CMD, and model preferences"
    echo "  2. Edit .claude/agents/*.md — customize agent role definitions"
    echo "  3. Edit CLAUDE.md — add your project's non-negotiable rules"
    echo "  4. Run: tekhton \"Your first task description\""
    echo
    exit 0
fi

# --- Early --plan check (runs before config exists) -------------------------

if [ "${1:-}" = "--plan" ]; then
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/prompts.sh"
    source "${TEKHTON_HOME}/lib/agent.sh"
    source "${TEKHTON_HOME}/lib/plan.sh"
    source "${TEKHTON_HOME}/lib/plan_state.sh"
    source "${TEKHTON_HOME}/lib/plan_completeness.sh"
    source "${TEKHTON_HOME}/stages/plan_interview.sh"
    source "${TEKHTON_HOME}/stages/plan_generate.sh"
    # PROJECT_NAME is needed by run_agent() for temp file naming;
    # in --plan mode config is not loaded, so derive from directory name.
    : "${PROJECT_NAME:=$(basename "$PROJECT_DIR")}"
    export PROJECT_NAME
    run_plan || true
    exit 0
fi

# --- Library sources ---------------------------------------------------------

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/agent.sh"
source "${TEKHTON_HOME}/lib/state.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/gates.sh"
source "${TEKHTON_HOME}/lib/hooks.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/turns.sh"

# Stage implementations
source "${TEKHTON_HOME}/stages/architect.sh"
source "${TEKHTON_HOME}/stages/coder.sh"
source "${TEKHTON_HOME}/stages/review.sh"
source "${TEKHTON_HOME}/stages/tester.sh"

# Load project config — populates all settings from .claude/pipeline.conf
load_config

usage() {
    echo "Tekhton — One intent. Many hands."
    echo ""
    echo "Usage: tekhton [flags] \"<task description>\""
    echo ""
    echo "  --init                    Scaffold pipeline config + agent roles for a new project"
    echo "  --plan                    Interactive planning: build DESIGN.md + CLAUDE.md"
    echo "  --status                  Print saved pipeline state and exit (no run)"
    echo "  --milestone               Milestone mode: higher turn limits, more review cycles,"
    echo "                            upgraded tester model"
    echo "  --start-at coder          Full pipeline from scratch (default)"
    echo "  --start-at review         Skip coder; requires CODER_SUMMARY.md"
    echo "  --start-at tester         Resume tester from existing TESTER_REPORT.md"
    echo "  --start-at test           Skip coder + reviewer; requires REVIEWER_REPORT.md"
    echo "  --notes-filter BUG        Inject only [BUG] notes this run"
    echo "  --notes-filter FEAT       Inject only [FEAT] notes this run"
    echo "  --notes-filter POLISH     Inject only [POLISH] notes this run"
    echo "  --init-notes              Create a blank HUMAN_NOTES.md template and exit"
    echo "  --seed-contracts          Seed inline system contracts in lib/ source files"
    echo "  --skip-audit              Skip architect audit even if threshold is reached"
    echo "  --force-audit             Force architect audit regardless of threshold"
    echo ""
    echo "Examples:"
    echo "  tekhton --init                           # First-time setup"
    echo "  tekhton --plan                           # Interactive planning phase"
    echo "  tekhton \"Implement user authentication\"   # Run full pipeline"
    echo "  tekhton --notes-filter BUG \"Fix: login bugs\""
    echo "  tekhton --milestone \"Feat: payment system\""
    _TEKHTON_CLEAN_EXIT=true
    exit 1
}

# --- Resume detection (no-argument invocation) -------------------------------

if [ $# -eq 0 ] && [ -z "${TASK:-}" ]; then
    if [ ! -f "$PIPELINE_STATE_FILE" ]; then
        error "No task given and no saved pipeline state found."
        usage
    fi

    echo
    warn "No task given — found saved pipeline state:"
    echo "────────────────────────────────────────"
    cat "$PIPELINE_STATE_FILE"
    echo "────────────────────────────────────────"
    echo
    SAVED_RESUME_FLAG=$(awk '/^## Resume Command$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
    SAVED_TASK=$(awk '/^## Task$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
    SAVED_REASON=$(awk '/^## Exit Reason$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
    # Split the saved flag string into an array so multi-word flags
    # (e.g. "--milestone --start-at tester") are passed as separate arguments
    read -ra SAVED_RESUME_FLAGS <<< "$SAVED_RESUME_FLAG"

    warn "Exit reason: ${SAVED_REASON}"
    warn "Will resume with: $0 ${SAVED_RESUME_FLAG} \"${SAVED_TASK}\""
    echo
    log "Continue? [y/n/fresh]"
    echo "  y     = resume as shown above"
    echo "  n     = abort (state file preserved)"
    echo "  fresh = discard state and start a new run (prompts for task)"
    read -r RESUME_CHOICE

    case "$RESUME_CHOICE" in
        y|Y)
            exec "$0" "${SAVED_RESUME_FLAGS[@]}" "$SAVED_TASK"
            ;;
        fresh)
            clear_pipeline_state
            error "State cleared. Re-run with a task description."
            exit 0
            ;;
        *)
            log "Aborted. State file preserved for next time."
            exit 0
            ;;
    esac
fi

# --- Argument parsing --------------------------------------------------------

START_AT="coder"  # default

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)
            if [ ! -f "$PIPELINE_STATE_FILE" ]; then
                echo "No saved pipeline state found."
                exit 0
            fi
            echo
            echo "════════════════════════════════════════"
            echo "  ${PROJECT_NAME} Pipeline — Saved State"
            echo "════════════════════════════════════════"
            cat "$PIPELINE_STATE_FILE"
            echo "════════════════════════════════════════"
            echo
            SAVED_RESUME_FLAG=$(awk '/^## Resume Command$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
            SAVED_TASK=$(awk '/^## Task$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
            echo "Resume with:"
            echo "  $0 ${SAVED_RESUME_FLAG} \"${SAVED_TASK}\""
            echo "  — or —"
            echo "  $0   (interactive resume prompt)"
            echo
            exit 0
            ;;
        --start-at)
            shift
            case "$1" in
                coder|review|tester|test) START_AT="$1" ;;
                *) error "Invalid --start-at value: '$1'. Must be coder, review, tester, or test."; usage ;;
            esac
            shift
            ;;
        --notes-filter)
            shift
            if echo "$1" | grep -qE "^(${NOTES_FILTER_CATEGORIES})$"; then
                NOTES_FILTER="$1"
            else
                error "Invalid --notes-filter value: '$1'. Must be one of: ${NOTES_FILTER_CATEGORIES//|/, }."
                usage
            fi
            shift
            ;;
        --milestone)
            MILESTONE_MODE=true
            apply_milestone_overrides
            shift
            ;;
        --init-notes)
            if [ -f "HUMAN_NOTES.md" ]; then
                warn "HUMAN_NOTES.md already exists. Edit it directly."
            else
                cat > HUMAN_NOTES.md << EOF
# Human Notes — ${PROJECT_NAME}

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use \`- [ ]\` for new notes. Use \`- [x]\` to mark items you want to defer/skip.
Tag with [BUG], [FEAT], or [POLISH] to use --notes-filter.

## Bugs
<!-- - [ ] [BUG] Example: describe a bug you found -->

## Features
<!-- - [ ] [FEAT] Example: describe a feature request -->

## Polish
<!-- - [ ] [POLISH] Example: describe a UX improvement -->
EOF
                print_run_summary
                success "Created HUMAN_NOTES.md — edit it, then run the pipeline normally."
            fi
            exit 0
            ;;
        --seed-contracts)
            log "Running inline contract seeding pass..."
            if [ ! -f "${ARCHITECTURE_FILE}" ]; then
                print_run_summary
                error "${ARCHITECTURE_FILE} not found. Create it first."
                exit 1
            fi

            export ARCHITECTURE_SYSTEMS
            ARCHITECTURE_SYSTEMS=$(grep -E "^### " "${ARCHITECTURE_FILE}" | sed 's/^### /- /')
            export ARCHITECTURE_CONTENT
            ARCHITECTURE_CONTENT=$(cat "${ARCHITECTURE_FILE}")
            SEED_PROMPT=$(render_prompt "seed_contracts")

            run_agent \
                "Seed Contracts" \
                "$CLAUDE_JR_CODER_MODEL" \
                "20" \
                "$SEED_PROMPT" \
                "${LOG_DIR}/$(date +%Y%m%d_%H%M%S)_seed-contracts.log"

            print_run_summary
            success "Contract seeding complete. Review with: grep -rn 'System:' lib/"
            exit 0
            ;;
        --help|-h) usage ;;
        --skip-audit) SKIP_AUDIT=true; shift ;;
        --force-audit) FORCE_AUDIT=true; shift ;;
        --) shift; break ;;
        -*) error "Unknown flag: $1"; usage ;;
        *) break ;;
    esac
done

if [ $# -eq 0 ]; then
    # No task argument — try to pull from saved pipeline state
    if [ "$START_AT" != "coder" ] && [ -f "$PIPELINE_STATE_FILE" ]; then
        TASK=$(awk '/^## Task$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
        if [ -n "$TASK" ]; then
            log "Task pulled from saved pipeline state: ${TASK}"
        else
            error "Pipeline state exists but has no task. Provide a task description."
            usage
        fi
    else
        error "Task description is required."
        usage
    fi
else
    TASK="$1"
fi

# Warn on vague task descriptions
if echo "$TASK" | grep -qiE "^(continue|do|run|execute|process|handle|fix|update|improve)\s+(the\s+)?(human_notes|notes|things|stuff|features|bugs|tasks)\s*$"; then
    warn "Task description '${TASK}' is very vague."
    warn "The coder will waste turns trying to interpret it."
    warn "Consider a specific description, e.g.:"
    warn "  'Implement per-floor undo system with configurable count'"
    warn "  'Fix search results not updating after filter change'"
    echo
    log "Continue with this task anyway? [y/n]"
    read -r CONTINUE_CHOICE
    if [[ ! "$CONTINUE_CHOICE" =~ ^[Yy]$ ]]; then
        log "Aborted. Re-run with a more specific task description."
        exit 0
    fi
fi

# --- Validation --------------------------------------------------------------

for _tool in $REQUIRED_TOOLS; do
    require_cmd "$_tool"
done

if [ ! -f "$PROJECT_RULES_FILE" ]; then
    error "${PROJECT_RULES_FILE} not found. Run this script from the project root."
    exit 1
fi

# Validate required files exist when skipping stages
if [ "$START_AT" = "review" ] && [ ! -f "CODER_SUMMARY.md" ]; then
    error "--start-at review requires CODER_SUMMARY.md to exist in the repo root."
    error "Run the full pipeline or ensure the coder has already produced this file."
    exit 1
fi

if [ "$START_AT" = "test" ] && [ ! -f "REVIEWER_REPORT.md" ]; then
    error "--start-at test requires REVIEWER_REPORT.md to exist in the repo root."
    error "Run the full pipeline or at least the review stage first."
    exit 1
fi

if [ "$START_AT" = "tester" ] && [ ! -f "TESTER_REPORT.md" ]; then
    error "--start-at tester requires TESTER_REPORT.md to exist in the repo root."
    error "Run --start-at test first to generate the planned tests list."
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TASK_SLUG=$(echo "$TASK" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_${TASK_SLUG}.log"

mkdir -p "$LOG_DIR"

# --- Pre-flight --------------------------------------------------------------

header "Tekhton — ${PROJECT_NAME} — Starting at: ${START_AT}"
log "Task: ${BOLD}${TASK}${NC}"
log "Log:  ${LOG_FILE}"
log "Senior Coder Model: ${CLAUDE_CODER_MODEL}"
log "Jr Coder Model: ${CLAUDE_JR_CODER_MODEL}"
log "Reviewer Model: ${CLAUDE_STANDARD_MODEL}"
log "Tester Model: ${CLAUDE_TESTER_MODEL}"

if [ "$MILESTONE_MODE" = true ]; then
    warn "MILESTONE MODE — Review cycles: ${MAX_REVIEW_CYCLES}, Coder turns: ${CODER_MAX_TURNS}, Tester turns: ${TESTER_MAX_TURNS}"
fi

# Pre-flight: show only the notes that will actually be injected
HUMAN_NOTE_COUNT=$(count_human_notes)
if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
    echo
    if [ -n "$NOTES_FILTER" ]; then
        warn "HUMAN_NOTES.md has ${HUMAN_NOTE_COUNT} unchecked [${NOTES_FILTER}] item(s) — will be injected into coder prompt."
    else
        warn "HUMAN_NOTES.md has ${HUMAN_NOTE_COUNT} unchecked item(s) — will be injected into coder prompt."
    fi
    extract_human_notes | sed 's/^/  /'
    REMAINING_UNFILTERED=$(grep -c "^- \[ \]" HUMAN_NOTES.md || true)
    REMAINING_UNFILTERED=$(echo "$REMAINING_UNFILTERED" | tr -d '[:space:]')
    if [ -n "$NOTES_FILTER" ] && [ "$REMAINING_UNFILTERED" -gt "$HUMAN_NOTE_COUNT" ]; then
        log "  ($(( REMAINING_UNFILTERED - HUMAN_NOTE_COUNT )) note(s) with other tags deferred to future runs)"
    fi
fi
echo

# Pre-flight drift threshold check
if should_trigger_audit 2>/dev/null; then
    obs_count=$(count_drift_observations)
    runs_count=$(get_runs_since_audit)
    echo
    warn "╔══════════════════════════════════════════════════════════════╗"
    warn "║  DRIFT THRESHOLD REACHED — ARCHITECT AUDIT WILL RUN          ║"
    warn "║  Observations: ${obs_count} (threshold: ${DRIFT_OBSERVATION_THRESHOLD}) ║"
    warn "║  Runs since audit: ${runs_count} (threshold: ${DRIFT_RUNS_SINCE_AUDIT_THRESHOLD}) ║"
    if [ "$SKIP_AUDIT" = true ]; then
    warn "║  --skip-audit: audit will be SKIPPED this run                ║"
    fi
    warn "╚══════════════════════════════════════════════════════════════╝"
    echo
fi

if ! git diff --quiet; then
    warn "Uncommitted changes detected. The coder will work on top of these."
fi

# Only archive prior reports when starting fresh from the coder stage
if [ "$START_AT" = "coder" ]; then
    for f in CODER_SUMMARY.md REVIEWER_REPORT.md JR_CODER_SUMMARY.md TESTER_REPORT.md; do
        if [ -f "$f" ]; then
            ARCHIVE_NAME="${LOG_DIR}/archive/$(date +%Y%m%d_%H%M%S)_${f}"
            mkdir -p "${LOG_DIR}/archive"
            mv "$f" "$ARCHIVE_NAME"
            log "Archived previous ${f}"
        fi
    done
elif [ "$START_AT" = "review" ]; then
    for f in REVIEWER_REPORT.md TESTER_REPORT.md JR_CODER_SUMMARY.md; do
        if [ -f "$f" ]; then
            mv "$f" "${LOG_DIR}/${TIMESTAMP}_prev_${f}"
            log "Archived previous $f"
        fi
    done
    log "Resuming with existing CODER_SUMMARY.md"
elif [ "$START_AT" = "test" ]; then
    if [ -f "TESTER_REPORT.md" ]; then
        mv "TESTER_REPORT.md" "${LOG_DIR}/${TIMESTAMP}_prev_TESTER_REPORT.md"
        log "Archived previous TESTER_REPORT.md"
    fi
    log "Resuming with existing CODER_SUMMARY.md and REVIEWER_REPORT.md"
elif [ "$START_AT" = "tester" ]; then
    log "Resuming tester from existing TESTER_REPORT.md"
    log "Planned tests remaining:"
    grep "^- \[ \]" TESTER_REPORT.md || log "(none found — may already be complete)"
else
    log "Resuming at ${START_AT} — prior reports preserved for agent context"
fi

# --- Stage 0: Architect Audit (conditional) ----------------------------------

if [ "$START_AT" = "coder" ] && [ "$SKIP_AUDIT" = false ]; then
    if [ "$FORCE_AUDIT" = true ] || should_trigger_audit 2>/dev/null; then
        run_stage_architect
    fi
fi

# --- Stage 1: Coder ----------------------------------------------------------

if [ "$START_AT" = "coder" ]; then
    run_stage_coder
else
    header "Stage 1 / 3 — Coder (skipped)"
    log "Using existing CODER_SUMMARY.md"
    if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        warn "HUMAN_NOTES.md has unchecked items but coder stage was skipped."
        warn "Notes will NOT be injected this run. Include them in your next full run."
    fi
fi

# --- Stage 2: Review loop ----------------------------------------------------

if [ "$START_AT" = "coder" ] || [ "$START_AT" = "review" ]; then
    run_stage_review
else
    header "Stage 2 / 3 — Reviewer (skipped)"
    log "Using existing REVIEWER_REPORT.md"
    VERDICT=$(grep -m1 "^## Verdict" -A1 REVIEWER_REPORT.md 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
    log "Existing verdict: ${VERDICT}"
fi

# --- Stage 3: Tester ---------------------------------------------------------

if [ "$START_AT" = "coder" ] || [ "$START_AT" = "review" ] || [ "$START_AT" = "test" ] || [ "$START_AT" = "tester" ]; then
    run_stage_tester
fi

if [ ! -f "TESTER_REPORT.md" ]; then
    warn "Tester did not produce TESTER_REPORT.md. Tests may have been written but report is missing."
fi

# --- Final checks ------------------------------------------------------------
# run_final_checks returns non-zero when analyze/tests fail — capture it so
# set -e doesn't kill the pipeline before we archive reports and commit.
# Skip entirely if a stage null-ran (no point burning tokens on cleanup agents).

FINAL_CHECK_RESULT=0
if [ "${SKIP_FINAL_CHECKS:-false}" = true ]; then
    warn "Skipping final checks — a stage had a null run (agent died without doing work)."
    warn "Fix the underlying issue and re-run before running analyze/test."

    # Archive whatever reports exist so they aren't lost
    archive_reports "$LOG_DIR" "$TIMESTAMP"
    print_run_summary
    warn "Pipeline exiting early due to null run. Re-run to resume."
    _TEKHTON_CLEAN_EXIT=true
    exit 0
else
    run_final_checks "$LOG_FILE" || FINAL_CHECK_RESULT=$?

    if [ "$FINAL_CHECK_RESULT" -ne 0 ]; then
        warn "Final checks had failures (exit ${FINAL_CHECK_RESULT}). Pipeline will continue to archiving and commit prompt."
    fi
fi

# --- Drift artifact processing -----------------------------------------------

process_drift_artifacts

# --- Archive reports ---------------------------------------------------------

archive_reports "$LOG_DIR" "$TIMESTAMP"

# --- Generate commit message -------------------------------------------------

COMMIT_MSG=$(generate_commit_message "$TASK" || echo "feat: ${TASK}")

# --- Done --------------------------------------------------------------------

header "Tekhton — Pipeline Complete"
echo -e "  Task:      ${BOLD}${TASK}${NC}"
echo -e "  Started:   ${BOLD}${START_AT}${NC}"
echo -e "  Verdict:   ${GREEN}${BOLD}${VERDICT}${NC}"
echo -e "  Log:       ${LOG_FILE}"
echo

# --- Action Items summary ----------------------------------------------------
# Consolidated block showing everything the human should review before moving on.

ACTION_ITEMS=()

# Check for tester bugs
# "None" at the start of the section (with optional period/whitespace) means no bugs,
# even if the tester added explanatory bullet points after it.
if [ -f "TESTER_REPORT.md" ] && \
   awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^[Nn]one/{exit 1} f && /^- /{found=1} END{exit !found}' TESTER_REPORT.md 2>/dev/null; then
    _bug_count=$(awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^[Nn]one/{print 0; exit} f && /^- /{c++} END{print c+0}' TESTER_REPORT.md)
    ACTION_ITEMS+=("$(echo -e "${YELLOW}  ⚠ TESTER_REPORT.md — ${_bug_count} bug(s) found (see ## Bugs Found)${NC}")")
fi

# Check for test failures from final checks
if [ "$FINAL_CHECK_RESULT" -ne 0 ]; then
    ACTION_ITEMS+=("$(echo -e "${YELLOW}  ⚠ Test suite — final checks failed (see output above)${NC}")")
fi

# Check for human action items
if has_human_actions 2>/dev/null; then
    _ha_count=$(count_human_actions)
    ACTION_ITEMS+=("$(echo -e "${YELLOW}  ⚠ ${HUMAN_ACTION_FILE} — ${_ha_count} item(s) needing manual work${NC}")")
fi

# Check for non-blocking notes (info only)
if [ -f "${NON_BLOCKING_LOG_FILE:-}" ] && [ -s "${NON_BLOCKING_LOG_FILE:-}" ]; then
    _nb_count=$(count_open_nonblocking_notes 2>/dev/null || echo 0)
    if [ "$_nb_count" -gt 0 ]; then
        ACTION_ITEMS+=("$(echo -e "${CYAN}  ℹ ${NON_BLOCKING_LOG_FILE} — ${_nb_count} accumulated observation(s)${NC}")")
    fi
fi

# Check for drift observations (info only)
if [ -f "${DRIFT_LOG_FILE:-}" ] && [ -s "${DRIFT_LOG_FILE:-}" ]; then
    _drift_count=$(count_drift_observations 2>/dev/null || echo 0)
    if [ "$_drift_count" -gt 0 ]; then
        ACTION_ITEMS+=("$(echo -e "${CYAN}  ℹ ${DRIFT_LOG_FILE} — ${_drift_count} unresolved drift observation(s)${NC}")")
    fi
fi

if [ ${#ACTION_ITEMS[@]} -gt 0 ]; then
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  Action Items${NC}"
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    for item in "${ACTION_ITEMS[@]}"; do
        echo -e "$item"
    done
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo
else
    success "No action items — clean run."
    echo
fi

log "Suggested commit message:"
echo "────────────────────────────────────────"
echo "$COMMIT_MSG"
echo "────────────────────────────────────────"
echo

log "Commit with suggested message? [y/e/n]"
echo "  y = commit now with this message"
echo "  e = open message in \$EDITOR first"
echo "  n = skip (commit manually later)"

# Read from /dev/tty when stdin is piped, so `yes | tekhton` doesn't
# silently auto-answer the commit prompt after consuming the resume prompt.
if [ -t 0 ]; then
    read -r COMMIT_CHOICE
else
    read -r COMMIT_CHOICE < /dev/tty 2>/dev/null || COMMIT_CHOICE="y"
    log "(read from /dev/tty — stdin was piped)"
fi

# Helper: stage, commit, and log output without printing verbose git details
_do_git_commit() {
    local msg="$1"
    git add -A > /dev/null 2>&1
    local git_output
    git_output=$(git commit -m "$msg" 2>&1) || true
    echo "$git_output" >> "$LOG_FILE"
    # Show only the summary line (e.g. "[branch abc1234] feat: message")
    local summary
    summary=$(echo "$git_output" | head -1)
    log "$summary"
}

case "$COMMIT_CHOICE" in
    y|Y)
        _do_git_commit "$COMMIT_MSG"
        print_run_summary
        success "Committed. Open a PR and squash-merge to main when ready."
        ;;
    e|E)
        TMPFILE=$(mktemp /tmp/tekhton-commit-XXXXXX.txt)
        echo "$COMMIT_MSG" > "$TMPFILE"
        ${EDITOR:-nano} "$TMPFILE"
        EDITED_MSG=$(cat "$TMPFILE")
        rm "$TMPFILE"
        _do_git_commit "$EDITED_MSG"
        print_run_summary
        success "Committed. Open a PR and squash-merge to main when ready."
        ;;
    *)
        log "Skipped commit. When ready:"
        echo "  git add -A && git commit -m '${COMMIT_MSG%%$'\n'*}'"
        ;;
esac
echo
