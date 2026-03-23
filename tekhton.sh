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
#   --replan              Delta-based update to existing DESIGN.md + CLAUDE.md
#   --status              Print saved pipeline state and exit
#   --milestone           Milestone mode: higher turn limits, more review cycles
#   --start-at coder      Full pipeline from scratch (default)
#   --start-at security   Skip coder; requires CODER_SUMMARY.md
#   --start-at review     Skip coder + security; requires CODER_SUMMARY.md
#   --start-at tester     Resume tester from existing TESTER_REPORT.md
#   --start-at test       Skip coder + security + reviewer; requires REVIEWER_REPORT.md
#   --skip-security       Bypass security stage for a single run
#   --plan-from-index     Synthesize DESIGN.md + CLAUDE.md from PROJECT_INDEX.md
#   --rescan              Incrementally update PROJECT_INDEX.md from git changes
#   --rescan --full       Force full re-crawl regardless of change volume
#   --init --full         Run init + synthesis in one command
#   --metrics             Print run metrics dashboard and exit
#   --notes-filter X      Inject only [X] notes (BUG, FEAT, POLISH)
#   --init-notes          Create blank HUMAN_NOTES.md template
#   --skip-audit          Skip architect audit even if threshold is reached
#   --auto-advance        Auto-advance through milestones after acceptance
#   --force-audit         Force architect audit regardless of threshold
#   --add-milestone "desc" Create a scoped milestone via intake agent (no run)
#   --migrate-dag         Convert inline CLAUDE.md milestones to DAG file format
#   --setup-indexer        Set up Python virtualenv for tree-sitter indexer
#   --with-lsp            Also install Serena LSP server (use with --setup-indexer)
#   --version, -v         Print version and exit
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

        # --- Record metrics on crash (12.3) -----------------------------------
        # Ensure metrics are captured even on unexpected crashes.
        # Use error classification for VERDICT when available — avoids labeling
        # intentional state-save exits (upstream error, null-run) as "crashed".
        if command -v record_run_metrics &>/dev/null 2>&1; then
            if [[ -z "${VERDICT:-}" ]] && [[ -n "${AGENT_ERROR_CATEGORY:-}" ]]; then
                VERDICT="${AGENT_ERROR_CATEGORY}/${AGENT_ERROR_SUBCATEGORY:-unknown}"
            else
                VERDICT="${VERDICT:-crashed}"
            fi
            record_run_metrics 2>/dev/null || true
        fi

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

    # --- MCP server cleanup: stop Serena if running ----------------------------
    if command -v stop_mcp_server &>/dev/null; then
        stop_mcp_server 2>/dev/null || true
    fi

    # --- Session cleanup: remove temp directory and lock file -----------------
    if [ -n "${TEKHTON_SESSION_DIR:-}" ] && [ -d "${TEKHTON_SESSION_DIR}" ]; then
        rm -rf "${TEKHTON_SESSION_DIR}" 2>/dev/null || true
    fi
    if [ -n "${_TEKHTON_LOCK_FILE:-}" ] && [ -f "${_TEKHTON_LOCK_FILE}" ]; then
        rm -f "${_TEKHTON_LOCK_FILE}" 2>/dev/null || true
    fi
}
trap _tekhton_cleanup EXIT

# --- Version -----------------------------------------------------------------
# Format: MAJOR.MINOR.PATCH
#   MAJOR = initiative version (1, 2, 3, ...)
#   MINOR = last completed milestone within this initiative (resets each major)
#   PATCH = hotfixes between milestones
# Updated on each milestone completion.
TEKHTON_VERSION="3.5.0"
export TEKHTON_VERSION

# --- Path resolution ---------------------------------------------------------
# TEKHTON_HOME: where this script (and lib/, stages/, prompts/) lives.
# PROJECT_DIR:  the target project — always the caller's working directory.

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

export TEKHTON_HOME
export PROJECT_DIR

# --- Per-session temp directory -----------------------------------------------
# All temp files (agent FIFOs, exit codes, turn counts) are created inside this
# directory instead of predictable /tmp paths. Cleaned up by the EXIT trap.
TEKHTON_SESSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tekhton_session_XXXXXXXX")
export TEKHTON_SESSION_DIR

# --- Pipeline lock file ------------------------------------------------------
# Prevents concurrent pipeline runs on the same project directory.
_TEKHTON_LOCK_FILE="${PROJECT_DIR}/.claude/PIPELINE.lock"

_check_pipeline_lock() {
    if [ -f "$_TEKHTON_LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$_TEKHTON_LOCK_FILE" 2>/dev/null || echo "")
        # Check if the PID from the lock file is still running
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "[✗] Another tekhton pipeline is already running (PID: ${lock_pid})." >&2
            echo "    Lock file: ${_TEKHTON_LOCK_FILE}" >&2
            echo "    If this is stale, remove it: rm ${_TEKHTON_LOCK_FILE}" >&2
            _TEKHTON_CLEAN_EXIT=true
            exit 1
        else
            # Stale lock — previous run crashed without cleanup
            rm -f "$_TEKHTON_LOCK_FILE"
        fi
    fi
    # Create lock directory if needed and write our PID
    mkdir -p "$(dirname "$_TEKHTON_LOCK_FILE")" 2>/dev/null || true
    echo "$$" > "$_TEKHTON_LOCK_FILE"
}

# --- Pre-library globals -----------------------------------------------------

NOTES_FILTER=""
MILESTONE_MODE=false
AUTO_ADVANCE=false
WITH_NOTES=false
export HUMAN_MODE=false
export HUMAN_NOTES_TAG=""
COMPLETE_MODE=false
MIGRATE_DAG=false
SETUP_INDEXER=false
WITH_LSP=false
CURRENT_NOTE_LINE=""
SKIP_AUDIT=false
SKIP_SECURITY=false
FORCE_AUDIT=false
_AUTO_COMMIT_EXPLICIT=false
SKIP_FINAL_CHECKS=false
TOTAL_TURNS=0
TOTAL_TIME=0
STAGE_SUMMARY=""

# --- Early --version check (runs before config exists) ----------------------

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    echo "Tekhton ${TEKHTON_VERSION}"
    exit 0
fi

# --- Early --init / --reinit check (runs before config exists) ----------------

if [ "${1:-}" = "--init" ] || [ "${1:-}" = "--reinit" ]; then
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/detect.sh"
    source "${TEKHTON_HOME}/lib/detect_commands.sh"
    source "${TEKHTON_HOME}/lib/detect_report.sh"
    # Milestone 12: Extended detection modules
    source "${TEKHTON_HOME}/lib/detect_workspaces.sh"
    source "${TEKHTON_HOME}/lib/detect_services.sh"
    source "${TEKHTON_HOME}/lib/detect_ci.sh"
    source "${TEKHTON_HOME}/lib/detect_infrastructure.sh"
    source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
    source "${TEKHTON_HOME}/lib/detect_doc_quality.sh"
    source "${TEKHTON_HOME}/lib/crawler.sh"
    source "${TEKHTON_HOME}/lib/init.sh"

    local_reinit=""
    [ "${1:-}" = "--reinit" ] && local_reinit="reinit"

    run_smart_init "$PROJECT_DIR" "$TEKHTON_HOME" "$local_reinit"

    # Warm indexer cache if available (M7)
    source "${TEKHTON_HOME}/lib/indexer.sh"
    source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
    source "${TEKHTON_HOME}/lib/indexer_history.sh"
    REPO_MAP_ENABLED="${REPO_MAP_ENABLED:-false}"
    if [[ "$REPO_MAP_ENABLED" == "true" ]] && check_indexer_available; then
        warm_index_cache || true
    fi

    # --init --full chains: init → synthesize in one invocation
    if [ "${2:-}" = "--full" ]; then
        source "${TEKHTON_HOME}/lib/prompts.sh"
        source "${TEKHTON_HOME}/lib/agent.sh"
        source "${TEKHTON_HOME}/lib/plan.sh"
        source "${TEKHTON_HOME}/lib/plan_completeness.sh"
        source "${TEKHTON_HOME}/lib/context.sh"
        source "${TEKHTON_HOME}/lib/context_compiler.sh"
        source "${TEKHTON_HOME}/stages/init_synthesize.sh"
        : "${PROJECT_NAME:=$(basename "$PROJECT_DIR")}"
        export PROJECT_NAME
        run_project_synthesis "$PROJECT_DIR" || true
    fi
    exit 0
fi

# --- Early --plan check (runs before config exists) -------------------------

if [ "${1:-}" = "--plan" ]; then
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/prompts.sh"
    source "${TEKHTON_HOME}/lib/agent.sh"      # also sources agent_monitor.sh, agent_helpers.sh
    source "${TEKHTON_HOME}/lib/plan.sh"
    source "${TEKHTON_HOME}/lib/plan_state.sh"
    source "${TEKHTON_HOME}/lib/plan_completeness.sh"
    source "${TEKHTON_HOME}/lib/milestones.sh"
    source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
    source "${TEKHTON_HOME}/lib/milestone_dag.sh"
    source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
    source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
    source "${TEKHTON_HOME}/stages/plan_interview.sh"
    source "${TEKHTON_HOME}/stages/plan_followup_interview.sh"
    source "${TEKHTON_HOME}/stages/plan_generate.sh"
    # PROJECT_NAME is needed by run_agent() for temp file naming;
    # in --plan mode config is not loaded, so derive from directory name.
    : "${PROJECT_NAME:=$(basename "$PROJECT_DIR")}"
    export PROJECT_NAME
    run_plan || true
    exit 0
fi

# --- Early --replan check (runs before execution pipeline) -------------------

if [ "${1:-}" = "--replan" ]; then
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/prompts.sh"
    source "${TEKHTON_HOME}/lib/agent.sh"      # also sources agent_monitor.sh, agent_helpers.sh
    source "${TEKHTON_HOME}/lib/plan.sh"
    source "${TEKHTON_HOME}/lib/replan.sh"     # brownfield replan functions
    source "${TEKHTON_HOME}/lib/rescan_helpers.sh"  # _extract_scan_metadata for replan_brownfield
    source "${TEKHTON_HOME}/lib/milestones.sh"
    source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
    source "${TEKHTON_HOME}/lib/milestone_dag.sh"
    source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
    source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
    source "${TEKHTON_HOME}/stages/plan_generate.sh"
    # PROJECT_NAME is needed by run_agent() for temp file naming;
    # in --replan mode config is not loaded, so derive from directory name.
    : "${PROJECT_NAME:=$(basename "$PROJECT_DIR")}"
    export PROJECT_NAME
    run_replan || true
    exit 0
fi

# --- Early --rescan check (runs before execution pipeline) ------------------

if [ "${1:-}" = "--rescan" ]; then
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/detect.sh"
    source "${TEKHTON_HOME}/lib/detect_commands.sh"
    source "${TEKHTON_HOME}/lib/detect_report.sh"
    source "${TEKHTON_HOME}/lib/detect_workspaces.sh"
    source "${TEKHTON_HOME}/lib/detect_services.sh"
    source "${TEKHTON_HOME}/lib/detect_ci.sh"
    source "${TEKHTON_HOME}/lib/detect_infrastructure.sh"
    source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
    source "${TEKHTON_HOME}/lib/detect_doc_quality.sh"
    source "${TEKHTON_HOME}/lib/crawler.sh"
    source "${TEKHTON_HOME}/lib/rescan.sh"

    local_full=""
    if [ "${2:-}" = "--full" ]; then
        local_full="full"
    fi

    rescan_project "$PROJECT_DIR" 120000 "$local_full"
    exit 0
fi

# --- Early --plan-from-index check (runs before execution pipeline) ----------

if [ "${1:-}" = "--plan-from-index" ]; then
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/detect.sh"
    source "${TEKHTON_HOME}/lib/detect_commands.sh"
    source "${TEKHTON_HOME}/lib/detect_report.sh"
    source "${TEKHTON_HOME}/lib/detect_workspaces.sh"
    source "${TEKHTON_HOME}/lib/detect_services.sh"
    source "${TEKHTON_HOME}/lib/detect_ci.sh"
    source "${TEKHTON_HOME}/lib/detect_infrastructure.sh"
    source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
    source "${TEKHTON_HOME}/lib/detect_doc_quality.sh"
    source "${TEKHTON_HOME}/lib/prompts.sh"
    source "${TEKHTON_HOME}/lib/agent.sh"
    source "${TEKHTON_HOME}/lib/plan.sh"
    source "${TEKHTON_HOME}/lib/plan_completeness.sh"
    source "${TEKHTON_HOME}/lib/context.sh"
    source "${TEKHTON_HOME}/lib/context_compiler.sh"
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"
    # PROJECT_NAME is needed by run_agent() for temp file naming;
    # in --plan-from-index mode config is not loaded, so derive from directory name.
    : "${PROJECT_NAME:=$(basename "$PROJECT_DIR")}"
    export PROJECT_NAME
    run_project_synthesis "$PROJECT_DIR" || true
    exit 0
fi

# --- Acquire pipeline lock (execution pipeline only) -------------------------
_check_pipeline_lock

# --- Library sources ---------------------------------------------------------

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/notes_single.sh"
source "${TEKHTON_HOME}/lib/notes_cleanup.sh"
source "${TEKHTON_HOME}/lib/agent.sh"
source "${TEKHTON_HOME}/lib/state.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/gates.sh"
source "${TEKHTON_HOME}/lib/hooks.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"
source "${TEKHTON_HOME}/lib/drift_artifacts.sh"
source "${TEKHTON_HOME}/lib/turns.sh"
source "${TEKHTON_HOME}/lib/context.sh"
source "${TEKHTON_HOME}/lib/context_compiler.sh"
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"  # DAG-aware wrappers (extracted from milestones.sh)
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_split.sh"
source "${TEKHTON_HOME}/lib/milestone_window.sh"
source "${TEKHTON_HOME}/lib/indexer.sh"
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
source "${TEKHTON_HOME}/lib/indexer_history.sh"
source "${TEKHTON_HOME}/lib/mcp.sh"
source "${TEKHTON_HOME}/lib/clarify.sh"
source "${TEKHTON_HOME}/lib/replan.sh"
source "${TEKHTON_HOME}/lib/detect.sh"
source "${TEKHTON_HOME}/lib/detect_commands.sh"
source "${TEKHTON_HOME}/lib/detect_report.sh"
source "${TEKHTON_HOME}/lib/detect_workspaces.sh"
source "${TEKHTON_HOME}/lib/detect_services.sh"
source "${TEKHTON_HOME}/lib/detect_ci.sh"
source "${TEKHTON_HOME}/lib/detect_infrastructure.sh"
source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
source "${TEKHTON_HOME}/lib/detect_doc_quality.sh"
source "${TEKHTON_HOME}/lib/crawler.sh"       # also sources crawler_inventory.sh, crawler_content.sh, crawler_deps.sh (via crawler_content.sh)
source "${TEKHTON_HOME}/lib/rescan_helpers.sh"  # helpers only; full rescan.sh sourced in --rescan block
source "${TEKHTON_HOME}/lib/specialists.sh"
source "${TEKHTON_HOME}/lib/metrics.sh"
source "${TEKHTON_HOME}/lib/metrics_calibration.sh"
source "${TEKHTON_HOME}/lib/metrics_dashboard.sh"
source "${TEKHTON_HOME}/lib/errors.sh"
source "${TEKHTON_HOME}/lib/causality.sh"
source "${TEKHTON_HOME}/lib/dashboard.sh"
source "${TEKHTON_HOME}/lib/finalize.sh"
source "${TEKHTON_HOME}/lib/milestone_metadata.sh"
source "${TEKHTON_HOME}/lib/orchestrate.sh"

# Stage helpers and implementations
source "${TEKHTON_HOME}/lib/intake_helpers.sh"
source "${TEKHTON_HOME}/lib/intake_verdict_handlers.sh"
source "${TEKHTON_HOME}/stages/intake.sh"
source "${TEKHTON_HOME}/stages/architect.sh"
source "${TEKHTON_HOME}/stages/coder.sh"
source "${TEKHTON_HOME}/lib/security_helpers.sh"
source "${TEKHTON_HOME}/stages/security.sh"
source "${TEKHTON_HOME}/stages/review.sh"
source "${TEKHTON_HOME}/stages/tester.sh"
source "${TEKHTON_HOME}/stages/cleanup.sh"

# Load project config — populates all settings from .claude/pipeline.conf
load_config

usage() {
    local exit_code="${1:-0}"
    echo "Tekhton ${TEKHTON_VERSION} — One intent. Many hands."
    echo ""
    echo "Usage: tekhton [flags] \"<task description>\""
    echo ""
    echo "  --init                    Smart init: detect stack, generate config + agent roles"
    echo "  --reinit                  Re-initialize (destructive — overwrites existing config)"
    echo "  --plan                    Interactive planning: build DESIGN.md + CLAUDE.md"
    echo "  --replan                  Delta-based update to existing DESIGN.md + CLAUDE.md"
    echo "  --plan-from-index         Synthesize DESIGN.md + CLAUDE.md from PROJECT_INDEX.md"
    echo "  --rescan                  Incrementally update PROJECT_INDEX.md from git changes"
    echo "  --rescan --full           Force full re-crawl regardless of change volume"
    echo "  --init --full             Run init + synthesis in one command"
    echo "  --status                  Print saved pipeline state and exit (no run)"
    echo "  --metrics                 Print run metrics dashboard and exit"
    echo "  --version, -v             Print version and exit"
    echo "  --help, -h                Show this help and exit"
    echo "  --milestone               Milestone mode: higher turn limits, more review cycles,"
    echo "                            upgraded tester model"
    echo "  --auto-advance            Auto-advance through milestones after acceptance"
    echo "  --add-milestone \"desc\"     Create a scoped milestone via intake agent (no run)"
    echo "  --start-at intake         Run from intake gate (re-evaluate clarity)"
    echo "  --start-at coder          Full pipeline from scratch (default)"
    echo "  --start-at security       Skip coder; requires CODER_SUMMARY.md"
    echo "  --start-at review         Skip coder + security; requires CODER_SUMMARY.md"
    echo "  --start-at tester         Resume tester from existing TESTER_REPORT.md"
    echo "  --start-at test           Skip coder + security + reviewer; requires REVIEWER_REPORT.md"
    echo "  --skip-security           Bypass security stage for a single run"
    echo "  --notes-filter BUG        Inject only [BUG] notes this run"
    echo "  --notes-filter FEAT       Inject only [FEAT] notes this run"
    echo "  --notes-filter POLISH     Inject only [POLISH] notes this run"
    echo "  --init-notes              Create a blank HUMAN_NOTES.md template and exit"
    echo "  --seed-contracts          Seed inline system contracts in lib/ source files"
    echo "  --human [TAG]             Pick next unchecked note from HUMAN_NOTES.md as task"
    echo "                            Optional TAG: BUG, FEAT, POLISH"
    echo "  --complete                Loop mode: repeat pipeline until done or bounds hit"
    echo "  --with-notes              Force human notes injection regardless of task text"
    echo "  --usage-threshold N       Pause if session usage exceeds N% (overrides config)"
    echo "  --no-commit               Skip auto-commit for this run (prompt instead)"
    echo "  --skip-audit              Skip architect audit even if threshold is reached"
    echo "  --force-audit             Force architect audit regardless of threshold"
    echo "  --migrate-dag             Convert inline CLAUDE.md milestones to DAG file format"
    echo "  --setup-indexer           Set up Python virtualenv for tree-sitter indexer"
    echo "  --with-lsp                Also install Serena LSP server (use with --setup-indexer)"
    echo ""
    echo "Examples:"
    echo "  tekhton --init                           # First-time setup"
    echo "  tekhton --plan                           # Interactive planning phase"
    echo "  tekhton --replan                         # Update existing plan from drift/changes"
    echo "  tekhton --plan-from-index                # Synthesize docs from project index"
    echo "  tekhton --init --full                    # Init + crawl + synthesize in one step"
    echo "  tekhton --rescan                         # Update PROJECT_INDEX.md incrementally"
    echo "  tekhton \"Implement user authentication\"   # Run full pipeline"
    echo "  tekhton --notes-filter BUG \"Fix: login bugs\""
    echo "  tekhton --milestone \"Feat: payment system\""
    echo "  tekhton --human                             # Pick next note and run"
    echo "  tekhton --human BUG                         # Pick next BUG note"
    echo "  tekhton --human --complete                  # Process all notes in loop"
    echo ""
    echo "Documentation:"
    echo "  man tekhton                              # Full man page (if installed)"
    echo "  man -M \"${TEKHTON_HOME}/man\" tekhton   # Man page from source directory"
    _TEKHTON_CLEAN_EXIT=true
    exit "$exit_code"
}

# --- Resume detection (no-argument invocation) -------------------------------

if [ $# -eq 0 ] && [ -z "${TASK:-}" ]; then
    if [ ! -f "$PIPELINE_STATE_FILE" ]; then
        error "No task given and no saved pipeline state found."
        usage 1
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
            # Remove lock before exec — exec replaces the process (same PID),
            # so the EXIT trap never fires. The resumed invocation recreates it.
            rm -f "$_TEKHTON_LOCK_FILE" 2>/dev/null || true
            exec bash "$0" "${SAVED_RESUME_FLAGS[@]}" "$SAVED_TASK"
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
        --metrics)
            summarize_metrics "$@"
            exit 0
            ;;
        --start-at)
            shift
            case "$1" in
                intake|coder|security|review|tester|test) START_AT="$1" ;;
                *) error "Invalid --start-at value: '$1'. Must be intake, coder, security, review, tester, or test."; usage 1 ;;
            esac
            shift
            ;;
        --notes-filter)
            shift
            if echo "$1" | grep -qE "^(${NOTES_FILTER_CATEGORIES})$"; then
                NOTES_FILTER="$1"
            else
                error "Invalid --notes-filter value: '$1'. Must be one of: ${NOTES_FILTER_CATEGORIES//|/, }."
                usage 1
            fi
            shift
            ;;
        --milestone)
            MILESTONE_MODE=true
            apply_milestone_overrides
            shift
            ;;
        --auto-advance)
            AUTO_ADVANCE=true
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
                "${LOG_DIR}/$(date +%Y%m%d_%H%M%S)_seed-contracts.log" \
                "$AGENT_TOOLS_SEED"

            print_run_summary
            success "Contract seeding complete. Review with: grep -rn 'System:' lib/"
            exit 0
            ;;
        --help|-h) usage 0 ;;
        --with-notes) WITH_NOTES=true; shift ;;
        --human)
            HUMAN_MODE=true
            shift
            # Consume optional tag argument (BUG, FEAT, POLISH) if present
            if [[ "${1:-}" =~ ^(BUG|FEAT|POLISH)$ ]]; then
                HUMAN_NOTES_TAG="$1"
                shift
            fi
            export HUMAN_MODE HUMAN_NOTES_TAG
            ;;

        --usage-threshold)
            shift
            USAGE_THRESHOLD_PCT="$1"
            shift
            ;;
        --complete) COMPLETE_MODE=true; shift ;;
        --no-commit) AUTO_COMMIT=false; _AUTO_COMMIT_EXPLICIT=true; shift ;;
        --skip-audit) SKIP_AUDIT=true; shift ;;
        --skip-security) SKIP_SECURITY=true; shift ;;
        --force-audit) FORCE_AUDIT=true; shift ;;
        --migrate-dag) MIGRATE_DAG=true; shift ;;
        --add-milestone)
            shift
            if [[ -z "${1:-}" ]]; then
                error "--add-milestone requires a description string."
                usage 1
            fi
            run_intake_create "$1"
            _TEKHTON_CLEAN_EXIT=true
            exit 0
            ;;
        --setup-indexer) SETUP_INDEXER=true; shift ;;
        --with-lsp) WITH_LSP=true; shift ;;
        --) shift; break ;;
        -*) error "Unknown flag: $1"; usage 1 ;;
        *) break ;;
    esac
done

# --- Early --migrate-dag: convert inline milestones to DAG format and exit ----
if [ "$MIGRATE_DAG" = true ]; then
    if ! [ -f "CLAUDE.md" ]; then
        error "CLAUDE.md not found in the current directory."
        _TEKHTON_CLEAN_EXIT=true
        exit 1
    fi
    if has_milestone_manifest; then
        warn "Milestone manifest already exists at $(_dag_manifest_path)"
        warn "Remove it first if you want to re-migrate."
        _TEKHTON_CLEAN_EXIT=true
        exit 0
    fi
    if ! parse_milestones "CLAUDE.md" >/dev/null 2>&1; then
        error "No inline milestones found in CLAUDE.md."
        _TEKHTON_CLEAN_EXIT=true
        exit 1
    fi
    log "Migrating inline milestones to DAG file format..."
    milestone_dir="$(_dag_milestone_dir)"
    if migrate_inline_milestones "CLAUDE.md" "$milestone_dir"; then
        _insert_milestone_pointer "CLAUDE.md" "$milestone_dir"
        success "Migration complete. Milestones written to ${milestone_dir}/"
        success "Manifest: $(_dag_manifest_path)"
    else
        error "Migration failed."
        _TEKHTON_CLEAN_EXIT=true
        exit 1
    fi
    _TEKHTON_CLEAN_EXIT=true
    exit 0
fi

# --- Early --setup-indexer: install Python dependencies and exit ---------------
if [ "$SETUP_INDEXER" = true ]; then
    local_setup_script="${TEKHTON_HOME}/tools/setup_indexer.sh"
    if [ ! -f "$local_setup_script" ]; then
        error "setup_indexer.sh not found at ${local_setup_script}"
        _TEKHTON_CLEAN_EXIT=true
        exit 1
    fi
    bash "$local_setup_script" "$PROJECT_DIR" "${REPO_MAP_VENV_DIR:-.claude/indexer-venv}"

    # If --with-lsp was also passed, install Serena after the indexer
    if [ "$WITH_LSP" = true ]; then
        local_serena_script="${TEKHTON_HOME}/tools/setup_serena.sh"
        if [ ! -f "$local_serena_script" ]; then
            error "setup_serena.sh not found at ${local_serena_script}"
            _TEKHTON_CLEAN_EXIT=true
            exit 1
        fi
        bash "$local_serena_script" "$PROJECT_DIR" "${SERENA_PATH:-.claude/serena}"
    fi

    # Warm cache after setup (M7)
    REPO_MAP_ENABLED=true
    if check_indexer_available; then
        warm_index_cache || true
    fi

    _TEKHTON_CLEAN_EXIT=true
    exit $?
fi

# AUTO_COMMIT conditional default: true in milestone mode, false otherwise.
# config_defaults.sh sets the non-milestone default (false). Here we override
# to true for milestone mode, but only if the user didn't explicitly set it
# in pipeline.conf (tracked by _CONF_KEYS_SET) or via --no-commit flag.
if [ "$MILESTONE_MODE" = true ] \
   && [[ " ${_CONF_KEYS_SET:-} " != *" AUTO_COMMIT "* ]] \
   && [ "${_AUTO_COMMIT_EXPLICIT:-false}" != true ]; then
    AUTO_COMMIT=true
fi

# Milestone mode implies --complete: retry on acceptance failure instead of
# exiting with "Fix issues and re-run". COMPLETE_MODE_ENABLED in pipeline.conf
# still allows opt-out.
if [ "$MILESTONE_MODE" = true ] && [ "$COMPLETE_MODE" != true ]; then
    COMPLETE_MODE=true
fi

# --- Human mode: flag validation and note derivation --------------------------

if [[ "$HUMAN_MODE" = true ]]; then
    if [[ "$MILESTONE_MODE" = true ]]; then
        error "Cannot combine --human with --milestone"
        _TEKHTON_CLEAN_EXIT=true
        exit 1
    fi
    if [[ "$WITH_NOTES" = true ]]; then
        warn "--with-notes is redundant with --human (notes are already active)"
    fi
    # Sync NOTES_FILTER from HUMAN_NOTES_TAG for pre-flight display
    if [[ -n "$HUMAN_NOTES_TAG" ]] && [[ -z "$NOTES_FILTER" ]]; then
        NOTES_FILTER="$HUMAN_NOTES_TAG"
    fi
fi

if [[ "$HUMAN_MODE" = true ]]; then
    if [[ $# -gt 0 ]]; then
        error "Cannot combine --human with an explicit task"
        _TEKHTON_CLEAN_EXIT=true
        exit 1
    fi
    if [[ "$COMPLETE_MODE" = true ]]; then
        # Task is set per-iteration in the human-complete loop
        TASK="--human --complete"
        # Auto-commit each note independently (used by finalize.sh)
        # shellcheck disable=SC2034
        AUTO_COMMIT=true
    else
        # Single-note mode: pick the highest-priority unchecked note
        CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
        if [[ -z "$CURRENT_NOTE_LINE" ]]; then
            if [[ -n "$HUMAN_NOTES_TAG" ]]; then
                log "No unchecked [${HUMAN_NOTES_TAG}] notes in HUMAN_NOTES.md"
            else
                log "No unchecked notes in HUMAN_NOTES.md"
            fi
            _TEKHTON_CLEAN_EXIT=true
            exit 0
        fi
        TASK=$(extract_note_text "$CURRENT_NOTE_LINE")
        claim_single_note "$CURRENT_NOTE_LINE"
        export CURRENT_NOTE_LINE
        log "Human mode: picked note — ${TASK}"
    fi
elif [ $# -eq 0 ]; then
    # No task argument — try to pull from saved pipeline state
    if [ "$START_AT" != "coder" ] && [ -f "$PIPELINE_STATE_FILE" ]; then
        TASK=$(awk '/^## Task$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
        if [ -n "$TASK" ]; then
            log "Task pulled from saved pipeline state: ${TASK}"
        else
            error "Pipeline state exists but has no task. Provide a task description."
            usage 1
        fi
    else
        error "Task description is required."
        usage 1
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
if [ "$START_AT" = "security" ] && [ ! -f "CODER_SUMMARY.md" ]; then
    error "--start-at security requires CODER_SUMMARY.md to exist in the repo root."
    error "Run the full pipeline or ensure the coder has already produced this file."
    exit 1
fi

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

# --- Causal event log + dashboard initialization (Milestone 13) ---------------
init_causal_log

# Stage tracking arrays for dashboard run_state emission
declare -A _STAGE_STATUS=()
declare -A _STAGE_TURNS=()
declare -A _STAGE_BUDGET=()
declare -A _STAGE_DURATION=()
PIPELINE_STATUS="running"
CURRENT_STAGE="initializing"
START_AT_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
WAITING_FOR=""

# Dashboard lifecycle: create if enabled + missing, cleanup if disabled + exists
if is_dashboard_enabled; then
    local_dash_dir="${PROJECT_DIR}/${DASHBOARD_DIR:-.claude/dashboard}"
    if [[ ! -d "$local_dash_dir" ]]; then
        init_dashboard "$PROJECT_DIR"
    fi
else
    local_dash_dir="${PROJECT_DIR}/${DASHBOARD_DIR:-.claude/dashboard}"
    if [[ -d "$local_dash_dir" ]]; then
        cleanup_dashboard "$PROJECT_DIR"
    fi
fi

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

if [ "$AUTO_ADVANCE" = true ]; then
    warn "AUTO-ADVANCE — Will advance through milestones (limit: ${AUTO_ADVANCE_LIMIT}, confirm: ${AUTO_ADVANCE_CONFIRM})"
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

# Pre-flight: indexer availability check
if [[ "${REPO_MAP_ENABLED:-false}" == "true" ]]; then
    if ! validate_indexer_config; then
        error "Invalid indexer configuration. Fix the values in pipeline.conf."
        exit 1
    fi
    if check_indexer_available; then
        log "Indexer: available (repo map enabled)"
    else
        warn "REPO_MAP_ENABLED=true but indexer not available — falling back to 2.0 behavior."
        warn "Run 'tekhton --setup-indexer' to install dependencies."
    fi
fi

# Pre-flight: Serena MCP server startup (when enabled)
if [[ "${SERENA_ENABLED:-false}" == "true" ]]; then
    if start_mcp_server; then
        log "Serena: MCP integration active"
    else
        warn "SERENA_ENABLED=true but Serena not available — continuing without LSP tools."
    fi
fi

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
if [ "$START_AT" = "coder" ] || [ "$START_AT" = "intake" ]; then
    for f in CODER_SUMMARY.md REVIEWER_REPORT.md JR_CODER_SUMMARY.md TESTER_REPORT.md INTAKE_REPORT.md; do
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

# --- Milestone number parsing ------------------------------------------------
# Parse milestone number from task for both --milestone and --auto-advance modes.
# This enables commit signatures in single-run --milestone mode, not just auto-advance.
#
# First tries regex extraction from the task string (e.g. "Milestone 3: ...").
# If that fails and a DAG manifest exists, falls back to the DAG frontier —
# the first pending milestone whose dependencies are all satisfied.

_CURRENT_MILESTONE=""
if [ "$MILESTONE_MODE" = true ]; then
    if [[ "$TASK" =~ [Mm]ilestone[[:space:]]+([0-9]+([.][0-9]+)*) ]]; then
        _CURRENT_MILESTONE="${BASH_REMATCH[1]}"
    fi

    # DAG fallback: if task string didn't contain a milestone number,
    # load the manifest and resolve the next actionable milestone.
    if [ -z "$_CURRENT_MILESTONE" ] && has_milestone_manifest; then
        load_manifest "$(_dag_manifest_path)" || true
        _dag_next_id=$(dag_find_next "") || true
        if [ -n "${_dag_next_id:-}" ]; then
            _CURRENT_MILESTONE=$(dag_id_to_number "$_dag_next_id")
            log "Resolved milestone ${_CURRENT_MILESTONE} from DAG frontier (${_dag_next_id})"
        fi
        unset _dag_next_id
    fi
fi

# --- Auto-advance: initialize milestone state if needed ----------------------

if [ "$AUTO_ADVANCE" = true ]; then
    # The --auto-advance CLI flag activates AUTO_ADVANCE_ENABLED so that
    # should_auto_advance() in milestone_ops.sh allows the loop to run.
    # Without this, the config default of false blocks the while loop.
    AUTO_ADVANCE_ENABLED=true
    export AUTO_ADVANCE_ENABLED
    if [ -n "$_CURRENT_MILESTONE" ]; then
        _total_milestones=$(get_milestone_count "CLAUDE.md")
        init_milestone_state "$_CURRENT_MILESTONE" "$_total_milestones"
        log "Auto-advance starting at milestone ${_CURRENT_MILESTONE} of ${_total_milestones}"
    else
        warn "Auto-advance enabled but task does not reference a milestone number."
        warn "Expected task like: 'Implement Milestone 3: ...'"
        warn "Or ensure a DAG manifest exists with pending milestones."
        warn "Falling back to single-run mode."
        AUTO_ADVANCE=false
    fi
elif [ "$MILESTONE_MODE" = true ] && [ -n "$_CURRENT_MILESTONE" ]; then
    # Single-run milestone mode: initialize state for commit signatures
    # and acceptance checking (no auto-advance loop)
    _total_milestones=$(get_milestone_count "CLAUDE.md")
    init_milestone_state "$_CURRENT_MILESTONE" "$_total_milestones"
    log "Milestone mode: targeting milestone ${_CURRENT_MILESTONE}"
fi

# --- DAG auto-migration: convert inline milestones to file-based DAG --------
# If MILESTONE_DAG_ENABLED and MILESTONE_AUTO_MIGRATE, and no manifest exists
# but inline milestones are detected, run migration automatically.
if [ "$MILESTONE_MODE" = true ] && [ -f "CLAUDE.md" ]; then
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && [[ "${MILESTONE_AUTO_MIGRATE:-true}" == "true" ]] \
       && ! has_milestone_manifest; then
        # Check if there are inline milestones to migrate
        if parse_milestones "CLAUDE.md" >/dev/null 2>&1; then
            log "Auto-migrating inline milestones to DAG file format..."
            milestone_dir="$(_dag_milestone_dir)"
            if migrate_inline_milestones "CLAUDE.md" "$milestone_dir"; then
                # Insert pointer comment in CLAUDE.md after successful migration
                _insert_milestone_pointer "CLAUDE.md" "$milestone_dir"
            else
                warn "Milestone migration failed — continuing with inline mode"
            fi
        fi
    fi

    # Load manifest if it exists (either from migration or pre-existing)
    if has_milestone_manifest; then
        load_manifest "$(_dag_manifest_path)" || warn "Failed to load milestone manifest"
    fi
fi

# --- Startup archival: clean up completed milestones from previous runs ------
# Archive [DONE] milestones that still have full definitions in CLAUDE.md.
# This handles cases where the previous run completed a milestone but crashed
# before archival, or where milestones were manually marked [DONE].
if [ "$MILESTONE_MODE" = true ] && [ -f "CLAUDE.md" ]; then
    archive_all_completed_milestones "CLAUDE.md"
fi

# --- Startup cleanup: clear completed items from logs -----------------------
# Remove [x] items from NON_BLOCKING_LOG.md and [RESOLVED] items from DRIFT_LOG.md
# so only the current run's completions appear. The commit message at the end of
# the run captures what was resolved; these logs don't need to keep them forever.
clear_completed_nonblocking_notes
clear_resolved_drift_observations

# --- Ctrl+C handler for auto-advance state preservation ---------------------

_tekhton_sigint_handler() {
    echo
    warn "Interrupted (Ctrl+C)"
    if [ "$AUTO_ADVANCE" = true ] && [ -n "$_CURRENT_MILESTONE" ]; then
        write_pipeline_state \
            "${START_AT}" \
            "interrupted_during_milestone_${_CURRENT_MILESTONE}" \
            "--auto-advance --start-at ${START_AT}" \
            "$TASK" \
            "Auto-advance interrupted at milestone ${_CURRENT_MILESTONE}" \
            "$_CURRENT_MILESTONE"
        log "Milestone state preserved. Resume with: $0 --auto-advance \"${TASK}\""
    fi
    # Record metrics on interruption so partial run data is captured
    VERDICT="${VERDICT:-interrupted}"
    record_run_metrics
    _TEKHTON_CLEAN_EXIT=true
    exit 130
}
trap _tekhton_sigint_handler INT

# --- Pipeline execution (with auto-advance loop) ----------------------------

_run_pipeline_stages() {
    # Emit pipeline_start event (root event, no caused_by)
    _PIPELINE_START_EVT=$(emit_event "pipeline_start" "pipeline" "$TASK" "" "" "")
    _LAST_STAGE_EVT="$_PIPELINE_START_EVT"

    # Stage 0a: Intake gate (pre-stage clarity evaluation)
    # Runs once per milestone/task before any other stage. Skipped when
    # START_AT is past coder (resuming from review/test).
    if [ "$START_AT" = "intake" ] || [ "$START_AT" = "coder" ]; then
        CURRENT_STAGE="intake"
        local _intake_start_evt
        _intake_start_evt=$(emit_event "stage_start" "intake" "" "$_LAST_STAGE_EVT" "" "")
        run_stage_intake
        _LAST_STAGE_EVT=$(emit_event "stage_end" "intake" "${INTAKE_VERDICT:-pass}" "$_intake_start_evt" "" \
            "{\"confidence\":${INTAKE_CONFIDENCE:-0}}")
        _STAGE_STATUS[intake]="complete"
        _STAGE_TURNS[intake]="${LAST_AGENT_TURNS:-0}"
        _STAGE_DURATION[intake]="${LAST_AGENT_ELAPSED:-0}"
        emit_dashboard_run_state 2>/dev/null || true
        # If START_AT was "intake", advance to "coder" for subsequent stages
        if [ "$START_AT" = "intake" ]; then
            START_AT="coder"
        fi
    fi

    # Stage 0b: Architect Audit (conditional)
    # Architect audit runs on its own turn/time budget. Save and restore
    # the pipeline accumulators so architect turns do not inflate coder
    # metrics or affect adaptive calibration.
    if [ "$START_AT" = "coder" ] && [ "$SKIP_AUDIT" = false ]; then
        if [ "$FORCE_AUDIT" = true ] || should_trigger_audit 2>/dev/null; then
            local _pre_audit_turns="$TOTAL_TURNS"
            local _pre_audit_time="$TOTAL_TIME"
            local _pre_audit_summary="$STAGE_SUMMARY"

            run_stage_architect

            # Record architect totals separately, then restore pipeline accumulators
            export ARCHITECT_AUDIT_TURNS=$(( TOTAL_TURNS - _pre_audit_turns ))
            export ARCHITECT_AUDIT_TIME=$(( TOTAL_TIME - _pre_audit_time ))
            TOTAL_TURNS="$_pre_audit_turns"
            TOTAL_TIME="$_pre_audit_time"
            STAGE_SUMMARY="$_pre_audit_summary"
            log "Architect audit used ${ARCHITECT_AUDIT_TURNS} turns (${ARCHITECT_AUDIT_TIME}s) — not counted against coder budget."
        fi
    fi

    # Stage 1: Coder
    if [ "$START_AT" = "coder" ]; then
        CURRENT_STAGE="coder"
        local _coder_start_evt
        _coder_start_evt=$(emit_event "stage_start" "coder" "$TASK" "$_LAST_STAGE_EVT" "" "")
        _STAGE_STATUS[coder]="running"
        _STAGE_BUDGET[coder]="${CODER_MAX_TURNS:-50}"
        emit_dashboard_run_state 2>/dev/null || true
        run_stage_coder
        local _coder_files_changed
        _coder_files_changed=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
        _LAST_STAGE_EVT=$(emit_event "stage_end" "coder" "${_coder_files_changed} files modified" "$_coder_start_evt" "" \
            "{\"files_changed\":${_coder_files_changed},\"turns_used\":${LAST_AGENT_TURNS:-0}}")
        _STAGE_STATUS[coder]="complete"
        _STAGE_TURNS[coder]="${ACTUAL_CODER_TURNS:-${LAST_AGENT_TURNS:-0}}"
        _STAGE_DURATION[coder]="${LAST_AGENT_ELAPSED:-0}"
        emit_dashboard_reports 2>/dev/null || true
        emit_dashboard_run_state 2>/dev/null || true
    else
        header "Stage 1 / 4 — Coder (skipped)"
        log "Using existing CODER_SUMMARY.md"
        if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
            warn "HUMAN_NOTES.md has unchecked items but coder stage was skipped."
            warn "Notes will NOT be injected this run. Include them in your next full run."
        fi
    fi

    # Stage 2: Security
    if [ "$START_AT" = "coder" ] || [ "$START_AT" = "security" ]; then
        CURRENT_STAGE="security"
        local _sec_start_evt
        _sec_start_evt=$(emit_event "stage_start" "security" "" "$_LAST_STAGE_EVT" "" "")
        _STAGE_STATUS[security]="running"
        _STAGE_BUDGET[security]="${SECURITY_MAX_TURNS:-15}"
        emit_dashboard_run_state 2>/dev/null || true
        run_stage_security
        _LAST_STAGE_EVT=$(emit_event "stage_end" "security" "" "$_sec_start_evt" "" \
            "{\"turns_used\":${LAST_AGENT_TURNS:-0}}")
        _STAGE_STATUS[security]="complete"
        _STAGE_TURNS[security]="${LAST_AGENT_TURNS:-0}"
        _STAGE_DURATION[security]="${LAST_AGENT_ELAPSED:-0}"
        emit_dashboard_security 2>/dev/null || true
        emit_dashboard_run_state 2>/dev/null || true
    else
        header "Stage 2 / 4 — Security (skipped)"
    fi

    # Stage 3: Review loop
    if [ "$START_AT" = "coder" ] || [ "$START_AT" = "security" ] || [ "$START_AT" = "review" ]; then
        CURRENT_STAGE="reviewer"
        local _review_start_evt
        _review_start_evt=$(emit_event "stage_start" "reviewer" "" "$_LAST_STAGE_EVT" "" "")
        _STAGE_STATUS[reviewer]="running"
        _STAGE_BUDGET[reviewer]="${REVIEWER_MAX_TURNS:-15}"
        emit_dashboard_run_state 2>/dev/null || true
        run_stage_review
        local _review_verdict_json="null"
        if [[ -n "${VERDICT:-}" ]]; then
            _review_verdict_json="{\"result\":\"$(_json_escape "${VERDICT}")\"}"
        fi
        _LAST_STAGE_EVT=$(emit_event "stage_end" "reviewer" "verdict: ${VERDICT:-unknown}" "$_review_start_evt" \
            "$_review_verdict_json" "{\"cycles\":${REVIEW_CYCLE:-0}}")
        _STAGE_STATUS[reviewer]="complete"
        _STAGE_TURNS[reviewer]="${LAST_AGENT_TURNS:-0}"
        _STAGE_DURATION[reviewer]="${LAST_AGENT_ELAPSED:-0}"
        emit_dashboard_reports 2>/dev/null || true
        emit_dashboard_run_state 2>/dev/null || true
    else
        header "Stage 3 / 4 — Reviewer (skipped)"
        log "Using existing REVIEWER_REPORT.md"
        VERDICT=$(grep -m1 "^## Verdict" -A1 REVIEWER_REPORT.md 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
        log "Existing verdict: ${VERDICT}"
    fi

    # Stage 4: Tester
    if [ "$START_AT" = "coder" ] || [ "$START_AT" = "security" ] || [ "$START_AT" = "review" ] || [ "$START_AT" = "test" ] || [ "$START_AT" = "tester" ]; then
        CURRENT_STAGE="tester"
        local _tester_start_evt
        _tester_start_evt=$(emit_event "stage_start" "tester" "" "$_LAST_STAGE_EVT" "" "")
        _STAGE_STATUS[tester]="running"
        _STAGE_BUDGET[tester]="${TESTER_MAX_TURNS:-30}"
        emit_dashboard_run_state 2>/dev/null || true
        run_stage_tester
        _LAST_STAGE_EVT=$(emit_event "stage_end" "tester" "" "$_tester_start_evt" "" \
            "{\"turns_used\":${LAST_AGENT_TURNS:-0}}")
        _STAGE_STATUS[tester]="complete"
        _STAGE_TURNS[tester]="${LAST_AGENT_TURNS:-0}"
        _STAGE_DURATION[tester]="${LAST_AGENT_ELAPSED:-0}"
        emit_dashboard_reports 2>/dev/null || true
        emit_dashboard_run_state 2>/dev/null || true
    fi

    if [ ! -f "TESTER_REPORT.md" ]; then
        warn "Tester did not produce TESTER_REPORT.md. Tests may have been written but report is missing."
    fi
}

# --- Usage threshold check (before pipeline execution) ----------------------
if ! check_usage_threshold; then
    warn "Pipeline paused — session usage exceeds USAGE_THRESHOLD_PCT (${USAGE_THRESHOLD_PCT}%)."
    warn "Wait for the usage window to reset, or raise the threshold in pipeline.conf."
    _TEKHTON_CLEAN_EXIT=true
    exit 0
fi

# --- Human-complete loop function --------------------------------------------
# Processes notes one at a time in a loop. Each note gets its own pipeline run
# and commit. Stage failures exit the script (crash handler resets [~] → [ ]).
# Graceful per-note failure recovery is M16 scope (outer loop restructuring).

_run_human_complete_loop() {
    : "${MAX_PIPELINE_ATTEMPTS:=5}"
    : "${AUTONOMOUS_TIMEOUT:=7200}"
    local human_attempt=0
    local start_time
    start_time=$(date +%s)

    while true; do
        human_attempt=$((human_attempt + 1))

        # Safety bound: max attempts
        if [[ "$human_attempt" -gt "$MAX_PIPELINE_ATTEMPTS" ]]; then
            warn "Reached MAX_PIPELINE_ATTEMPTS (${MAX_PIPELINE_ATTEMPTS}). Stopping."
            break
        fi

        # Safety bound: wall-clock timeout
        local elapsed
        elapsed=$(( $(date +%s) - start_time ))
        if [[ "$elapsed" -ge "$AUTONOMOUS_TIMEOUT" ]]; then
            warn "Reached AUTONOMOUS_TIMEOUT (${AUTONOMOUS_TIMEOUT}s). Stopping."
            break
        fi

        # Pick next note
        CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
        if [[ -z "$CURRENT_NOTE_LINE" ]]; then
            if [[ -n "$HUMAN_NOTES_TAG" ]]; then
                log "No more unchecked [${HUMAN_NOTES_TAG}] notes. Done."
            else
                log "No more unchecked notes. Done."
            fi
            break
        fi

        TASK=$(extract_note_text "$CURRENT_NOTE_LINE")
        export CURRENT_NOTE_LINE

        log "Human note ${human_attempt}: ${TASK}"
        claim_single_note "$CURRENT_NOTE_LINE"

        # Archive reports from previous iteration
        if [[ "$human_attempt" -gt 1 ]]; then
            for f in CODER_SUMMARY.md REVIEWER_REPORT.md JR_CODER_SUMMARY.md TESTER_REPORT.md; do
                if [[ -f "$f" ]]; then
                    mkdir -p "${LOG_DIR}/archive"
                    mv "$f" "${LOG_DIR}/archive/$(date +%Y%m%d_%H%M%S)_human${human_attempt}_${f}"
                fi
            done
        fi

        # Update log file for this note
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        TASK_SLUG=$(echo "$TASK" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
        LOG_FILE="${LOG_DIR}/${TIMESTAMP}_${TASK_SLUG}.log"

        # Reset start-at for each note (always full pipeline)
        START_AT="coder"

        # Check usage threshold before each note
        if ! check_usage_threshold; then
            warn "Usage threshold reached. Pausing human-complete loop."
            # Reset the claimed note back to [ ]
            resolve_single_note "$CURRENT_NOTE_LINE" 1
            break
        fi

        # Run full pipeline — if a stage calls exit 1, the script exits and
        # the crash handler resets [~] → [ ]. This satisfies "stop on failure".
        _run_pipeline_stages

        # Pipeline succeeded — finalize (includes commit for this note).
        # _hook_resolve_notes detects HUMAN_MODE and calls resolve_single_note
        # for CURRENT_NOTE_LINE, marking it [x] on success.
        finalize_run 0

        log "Note completed: ${TASK}"
    done
}

# --- Pipeline execution (mode dispatch) --------------------------------------

if [[ "$HUMAN_MODE" = true ]] && [[ "$COMPLETE_MODE" = true ]]; then
    # Human-complete mode: process notes one at a time in a loop
    _run_human_complete_loop
elif [[ "$COMPLETE_MODE" = true ]] && [[ "$HUMAN_MODE" != true ]]; then
    # Outer orchestration loop (M16): retry pipeline until acceptance or bounds exhausted.
    # Handles milestone and non-milestone tasks. Auto-advance is wired into the loop.
    if [[ "${COMPLETE_MODE_ENABLED:-true}" != "true" ]]; then
        warn "--complete is disabled (COMPLETE_MODE_ENABLED=false). Running single pipeline."
        _run_pipeline_stages
        finalize_run 0
    else
        run_complete_loop || true
    fi
    echo
else
    # Standard single-run pipeline execution
    _run_pipeline_stages

    # --- Auto-advance loop ---------------------------------------------------

    if [ "$AUTO_ADVANCE" = true ] && [ -n "$_CURRENT_MILESTONE" ]; then
        # Check acceptance for current milestone
        _acceptance_pass=true
        check_milestone_acceptance "$_CURRENT_MILESTONE" "CLAUDE.md" || _acceptance_pass=false

        if [ "$_acceptance_pass" = true ]; then
            # Find next milestone
            _next_milestone=$(find_next_milestone "$_CURRENT_MILESTONE" "CLAUDE.md")

            if [ -n "$_next_milestone" ]; then
                write_milestone_disposition "COMPLETE_AND_CONTINUE"

                # Auto-advance loop
                while should_auto_advance; do
                    _next_milestone=$(find_next_milestone "$_CURRENT_MILESTONE" "CLAUDE.md")
                    if [ -z "$_next_milestone" ]; then
                        log "No more milestones to advance to."
                        write_milestone_disposition "COMPLETE_AND_WAIT"
                        break
                    fi

                    _next_title=$(get_milestone_title "$_next_milestone")

                    # Confirm if configured
                    if [ "${AUTO_ADVANCE_CONFIRM}" = "true" ]; then
                        if ! prompt_auto_advance_confirm "$_next_milestone" "$_next_title"; then
                            log "Auto-advance declined by user."
                            write_milestone_disposition "COMPLETE_AND_WAIT"
                            break
                        fi
                    fi

                    advance_milestone "$_CURRENT_MILESTONE" "$_next_milestone"
                    _CURRENT_MILESTONE="$_next_milestone"

                    # Update task for the new milestone
                    TASK="Implement Milestone ${_CURRENT_MILESTONE}: ${_next_title}"
                    log "Task updated: ${TASK}"

                    # Reset START_AT to coder for subsequent milestones
                    START_AT="coder"

                    # Archive reports from previous milestone
                    for f in CODER_SUMMARY.md REVIEWER_REPORT.md JR_CODER_SUMMARY.md TESTER_REPORT.md; do
                        if [ -f "$f" ]; then
                            ARCHIVE_NAME="${LOG_DIR}/archive/$(date +%Y%m%d_%H%M%S)_milestone${_CURRENT_MILESTONE}_${f}"
                            mkdir -p "${LOG_DIR}/archive"
                            mv "$f" "$ARCHIVE_NAME"
                        fi
                    done

                    # Check usage threshold before starting next milestone
                    if ! check_usage_threshold; then
                        warn "Usage threshold reached before milestone ${_CURRENT_MILESTONE}. Pausing auto-advance."
                        write_milestone_disposition "COMPLETE_AND_WAIT"
                        break
                    fi

                    # Update log file for new milestone
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    TASK_SLUG=$(echo "$TASK" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
                    LOG_FILE="${LOG_DIR}/${TIMESTAMP}_${TASK_SLUG}.log"

                    # Run pipeline stages for new milestone
                    _run_pipeline_stages

                    # Check acceptance for new milestone
                    _acceptance_pass=true
                    check_milestone_acceptance "$_CURRENT_MILESTONE" "CLAUDE.md" || _acceptance_pass=false

                    if [ "$_acceptance_pass" = true ]; then
                        _next_check=$(find_next_milestone "$_CURRENT_MILESTONE" "CLAUDE.md")
                        if [ -n "$_next_check" ]; then
                            write_milestone_disposition "COMPLETE_AND_CONTINUE"
                        else
                            write_milestone_disposition "COMPLETE_AND_WAIT"
                            log "All milestones complete."
                            break
                        fi
                    else
                        write_milestone_disposition "INCOMPLETE_REWORK"
                        warn "Milestone ${_CURRENT_MILESTONE} acceptance failed. Stopping auto-advance."
                        break
                    fi
                done
            else
                write_milestone_disposition "COMPLETE_AND_WAIT"
                log "No more milestones — this was the last one."
            fi
        else
            write_milestone_disposition "INCOMPLETE_REWORK"
            warn "Milestone ${_CURRENT_MILESTONE} acceptance failed. Fix issues and re-run."
        fi
    elif [ "$MILESTONE_MODE" = true ] && [ -n "$_CURRENT_MILESTONE" ] && [ "${SKIP_FINAL_CHECKS:-false}" != true ]; then
        # Non-auto-advance milestone run: check acceptance and set disposition
        _acceptance_pass=true
        check_milestone_acceptance "$_CURRENT_MILESTONE" "CLAUDE.md" || _acceptance_pass=false

        if [ "$_acceptance_pass" = true ]; then
            write_milestone_disposition "COMPLETE_AND_WAIT"
        else
            write_milestone_disposition "INCOMPLETE_REWORK"
        fi
    fi

    # --- Autonomous debt sweep (post-success only) ----------------------------
    # Runs after the primary pipeline completes. Never runs during rework cycles.
    # Build gate failure in cleanup logs a warning but does not fail the pipeline.

    if [ "${SKIP_FINAL_CHECKS:-false}" != true ] && should_run_cleanup; then
        run_stage_cleanup
    fi

    # --- Finalize pipeline ---------------------------------------------------
    # All post-pipeline bookkeeping is consolidated in finalize_run() (lib/finalize.sh).
    # The hook sequence handles: final checks, drift artifacts, metrics, resolved
    # notes cleanup, human notes resolution, report archiving, milestone marking,
    # commit, milestone archival, and state clearing — in deterministic order.
    #
    # Pipeline exit code: 0 if we reached this point (stages completed).
    # SKIP_FINAL_CHECKS signals a null-run stage — finalize_run handles it via
    # the _hook_final_checks guard.

    finalize_run 0
    echo
fi
