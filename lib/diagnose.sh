#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose.sh — Diagnostic engine for --diagnose
#
# Sourced by tekhton.sh — do not run directly.
# Expects: lib/diagnose_rules.sh sourced first.
# Expects: PROJECT_DIR, PIPELINE_STATE_FILE, CAUSAL_LOG_FILE (set by caller)
# Expects: Color codes (RED, GREEN, YELLOW, CYAN, BOLD, NC) from common.sh
#
# Provides:
#   _read_diagnostic_context   — aggregate all diagnostic input sources
#   _compute_cause_chain       — trace backward from terminal event to root cause
#   classify_failure_diag      — apply rules, return first match
#   run_diagnose               — orchestrate full --diagnose flow
#
# Delegates to diagnose_output.sh:
#   generate_diagnosis_report, print_diagnosis_summary,
#   write_last_failure_context, print_crash_first_aid, emit_dashboard_diagnosis
# =============================================================================

# Source rule definitions
# shellcheck source=lib/diagnose_rules.sh
source "${TEKHTON_HOME:?}/lib/diagnose_rules.sh"

# Source helper functions (_collapse_cause_chain, _detect_recurring_failures,
# _collect_agent_log_tails)
# shellcheck source=lib/diagnose_helpers.sh
source "${TEKHTON_HOME:?}/lib/diagnose_helpers.sh"

# Source output/reporting functions (generate_diagnosis_report, print_diagnosis_summary,
# write_last_failure_context, print_crash_first_aid, emit_dashboard_diagnosis)
# shellcheck source=lib/diagnose_output.sh
source "${TEKHTON_HOME:?}/lib/diagnose_output.sh"

# --- Module state -----------------------------------------------------------

_DIAG_CAUSAL_EVENTS=""       # Raw causal log content
_DIAG_TERMINAL_EVENT=""      # Last event before pipeline stopped
_DIAG_ERROR_EVENTS=""        # All error-type events
_DIAG_REVIEW_CYCLES=0        # Review cycle count from causal log
_DIAG_CAUSE_CHAIN=""         # Pre-computed cause chain text
_DIAG_CAUSE_CHAIN_SHORT=""   # Collapsed cause chain (max 5 links)
_DIAG_RECURRING_COUNT=0      # Recurring failure count
_DIAG_RECURRING_NOTE=""      # Recurring failure message
_DIAG_PIPELINE_OUTCOME=""    # success/failure/timeout/stuck
_DIAG_PIPELINE_STAGE=""      # Stage where failure occurred
_DIAG_PIPELINE_TASK=""       # Task description
_DIAG_PIPELINE_MILESTONE=""  # Active milestone
_DIAG_AGENT_LOG_TAILS=""     # Last 20 lines of agent logs

# --- Context reader ----------------------------------------------------------

# _read_diagnostic_context
# Reads all state files and populates _DIAG_* module state.
_read_diagnostic_context() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    local causal_log="${CAUSAL_LOG_FILE:-${PROJECT_DIR:-.}/.claude/logs/CAUSAL_LOG.jsonl}"
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"

    # Reset state
    _DIAG_CAUSAL_EVENTS=""
    _DIAG_TERMINAL_EVENT=""
    _DIAG_ERROR_EVENTS=""
    _DIAG_REVIEW_CYCLES=0
    _DIAG_CAUSE_CHAIN=""
    _DIAG_CAUSE_CHAIN_SHORT=""
    _DIAG_RECURRING_COUNT=0
    _DIAG_RECURRING_NOTE=""
    _DIAG_PIPELINE_OUTCOME=""
    _DIAG_PIPELINE_STAGE=""
    _DIAG_PIPELINE_TASK=""
    _DIAG_PIPELINE_MILESTONE=""
    _DIAG_AGENT_LOG_TAILS=""

    # --- Pipeline state -------------------------------------------------------
    if [[ -f "$state_file" ]]; then
        _DIAG_PIPELINE_STAGE=$(awk '/^## Exit Stage$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
        _DIAG_PIPELINE_TASK=$(awk '/^## Task$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
    fi

    # --- RUN_SUMMARY.json -----------------------------------------------------
    if [[ -f "$summary_file" ]]; then
        _DIAG_PIPELINE_OUTCOME=$(grep -oP '"outcome"\s*:\s*"\K[^"]+' "$summary_file" 2>/dev/null || true)
        _DIAG_PIPELINE_MILESTONE=$(grep -oP '"milestone"\s*:\s*"\K[^"]+' "$summary_file" 2>/dev/null || true)
        local rework
        rework=$(grep -oP '"rework_cycles"\s*:\s*\K[0-9]+' "$summary_file" 2>/dev/null || true)
        _DIAG_REVIEW_CYCLES="${rework:-0}"
    fi

    # --- LAST_FAILURE_CONTEXT.json (fast path) --------------------------------
    if [[ -f "$failure_ctx" ]]; then
        # Fill gaps from cached context
        if [[ -z "$_DIAG_PIPELINE_OUTCOME" ]]; then
            _DIAG_PIPELINE_OUTCOME=$(grep -oP '"outcome"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
        fi
        if [[ -z "$_DIAG_PIPELINE_STAGE" ]]; then
            _DIAG_PIPELINE_STAGE=$(grep -oP '"stage"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
        fi
    fi

    # --- Causal log -----------------------------------------------------------
    if [[ -f "$causal_log" ]] && [[ -s "$causal_log" ]]; then
        _DIAG_CAUSAL_EVENTS=$(cat "$causal_log" 2>/dev/null || true)

        # Terminal event: last line of the log
        _DIAG_TERMINAL_EVENT=$(tail -1 "$causal_log" 2>/dev/null || true)

        # Error events
        _DIAG_ERROR_EVENTS=$(grep '"type":"error"' "$causal_log" 2>/dev/null || true)

        # Review cycles from verdict events
        local review_verdicts
        review_verdicts=$(grep -c '"type":"verdict".*"stage":"reviewer"' "$causal_log" 2>/dev/null || echo "0")
        review_verdicts="${review_verdicts//[!0-9]/}"
        : "${review_verdicts:=0}"
        if [[ "$review_verdicts" -gt "$_DIAG_REVIEW_CYCLES" ]]; then
            _DIAG_REVIEW_CYCLES="$review_verdicts"
        fi

        # Cause chain from terminal error event
        _compute_cause_chain "$causal_log"

    fi

    # --- Agent log tails ------------------------------------------------------
    _collect_agent_log_tails
}

# _compute_cause_chain CAUSAL_LOG_FILE
# Traces backward from the terminal event to find the root cause.
_compute_cause_chain() {
    local causal_log="$1"

    # Find the last error or failure event
    local terminal_id=""
    terminal_id=$(printf '%s' "$_DIAG_TERMINAL_EVENT" | grep -oP '"id"\s*:\s*"\K[^"]+' 2>/dev/null || true)
    [[ -n "$terminal_id" ]] || return 0

    # Use cause_chain_summary if available
    if command -v cause_chain_summary &>/dev/null; then
        _DIAG_CAUSE_CHAIN=$(cause_chain_summary "$terminal_id" 2>/dev/null || true)
    fi

    # Build collapsed chain for terminal display (max 5 links)
    _collapse_cause_chain
}

# --- Failure classifier -------------------------------------------------------

# classify_failure_diag
# Applies rules in priority order, returns the first match.
# Sets DIAG_CLASSIFICATION, DIAG_CONFIDENCE, DIAG_SUGGESTIONS.
classify_failure_diag() {
    # Classification variables are declared in diagnose_rules.sh
    # and set by each rule or the fallback below.
    DIAG_SUGGESTIONS=()

    # Check for success first
    if [[ "$_DIAG_PIPELINE_OUTCOME" = "success" ]]; then
        DIAG_CLASSIFICATION="SUCCESS"
        DIAG_CONFIDENCE="high"
        DIAG_SUGGESTIONS=("Last run completed successfully. No issues found.")
        return 0
    fi

    for rule_fn in "${DIAGNOSE_RULES[@]}"; do
        if "$rule_fn" 2>/dev/null; then
            # Rule matched — trigger recurring failure detection now that
            # DIAG_CLASSIFICATION is set
            _detect_recurring_failures
            return 0
        fi
    done

    # Should never reach here (_rule_unknown always matches)
    DIAG_CLASSIFICATION="UNKNOWN"
    DIAG_CONFIDENCE="low"
    DIAG_SUGGESTIONS=("No specific failure pattern identified.")
}

# --- Orchestrator -------------------------------------------------------------

# run_diagnose
# Full --diagnose flow: read context, classify, report, print summary.
run_diagnose() {
    # Check if any pipeline has run
    local has_state=false
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"
    local causal_log="${CAUSAL_LOG_FILE:-${PROJECT_DIR:-.}/.claude/logs/CAUSAL_LOG.jsonl}"
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"

    if [[ -f "$state_file" ]] || [[ -f "$summary_file" ]] || [[ -f "$causal_log" ]] || [[ -f "$failure_ctx" ]]; then
        has_state=true
    fi

    # Also detect migration failures via backup directories
    if [[ "$has_state" != true ]]; then
        local backup_base="${PROJECT_DIR:-.}/${MIGRATION_BACKUP_DIR:-.claude/migration-backups}"
        if compgen -G "${backup_base}/pre-*" >/dev/null 2>&1; then
            has_state=true
        fi
    fi

    if [[ "$has_state" != true ]]; then
        echo -e "${YELLOW}No pipeline runs found. Nothing to diagnose.${NC}"
        echo "Run 'tekhton \"your task\"' to start a pipeline."
        return 0
    fi

    _read_diagnostic_context
    classify_failure_diag
    generate_diagnosis_report
    print_diagnosis_summary
}
