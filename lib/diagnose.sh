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
#   classify_failure_diag      — apply rules, return first match
#   generate_diagnosis_report  — write DIAGNOSIS.md
#   print_diagnosis_summary    — terminal output with box formatting
#   write_last_failure_context — write LAST_FAILURE_CONTEXT.json atomically
#   run_diagnose               — orchestrate full --diagnose flow
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
    DIAG_CLASSIFICATION=""
    DIAG_CONFIDENCE=""
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

# --- Report generator --------------------------------------------------------

# generate_diagnosis_report
# Produces DIAGNOSIS.md with causal chain, classification, suggestions.
generate_diagnosis_report() {
    local report_file="${PROJECT_DIR:-.}/DIAGNOSIS.md"
    local tmpfile="${report_file}.tmp.$$"

    {
        echo "# Diagnosis Report"
        echo ""
        echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Classification:** ${DIAG_CLASSIFICATION}"
        echo "**Confidence:** ${DIAG_CONFIDENCE}"
        echo ""

        # Pipeline state summary
        echo "## Pipeline State"
        echo ""
        if [[ -n "$_DIAG_PIPELINE_TASK" ]]; then
            echo "- **Task:** ${_DIAG_PIPELINE_TASK}"
        fi
        if [[ -n "$_DIAG_PIPELINE_MILESTONE" ]] && [[ "$_DIAG_PIPELINE_MILESTONE" != "none" ]]; then
            echo "- **Milestone:** ${_DIAG_PIPELINE_MILESTONE}"
        fi
        if [[ -n "$_DIAG_PIPELINE_STAGE" ]]; then
            echo "- **Failed at:** ${_DIAG_PIPELINE_STAGE}"
        fi
        if [[ -n "$_DIAG_PIPELINE_OUTCOME" ]]; then
            echo "- **Outcome:** ${_DIAG_PIPELINE_OUTCOME}"
        fi
        echo ""

        # Causal chain
        if [[ -n "$_DIAG_CAUSE_CHAIN" ]]; then
            echo "## Cause Chain"
            echo ""
            echo '```'
            echo "$_DIAG_CAUSE_CHAIN"
            echo '```'
            echo ""
        fi

        # Suggestions
        echo "## Recovery Suggestions"
        echo ""
        local idx=1
        for suggestion in "${DIAG_SUGGESTIONS[@]}"; do
            if [[ "$suggestion" =~ ^[[:space:]] ]]; then
                echo "$suggestion"
            else
                echo "${idx}. ${suggestion}"
                idx=$(( idx + 1 ))
            fi
        done
        echo ""

        # Recurring failure note
        if [[ -n "$_DIAG_RECURRING_NOTE" ]]; then
            echo "## Recurring Pattern"
            echo ""
            echo "**Warning:** ${_DIAG_RECURRING_NOTE}"
            echo ""
        fi

        # Relevant files
        echo "## Relevant Files"
        echo ""
        _list_relevant_files
        echo ""

        # Agent log tails (full report only)
        if [[ -n "$_DIAG_AGENT_LOG_TAILS" ]]; then
            echo "## Agent Log Excerpts"
            echo ""
            echo '```'
            echo "$_DIAG_AGENT_LOG_TAILS"
            echo '```'
        fi
    } > "$tmpfile"

    mv "$tmpfile" "$report_file"
}

# _list_relevant_files
# Lists files relevant to the diagnosis.
_list_relevant_files() {
    local files=(
        "BUILD_ERRORS.md"
        "REVIEWER_REPORT.md"
        "CODER_SUMMARY.md"
        "TESTER_REPORT.md"
        "SECURITY_REPORT.md"
        "CLARIFICATIONS.md"
        "HUMAN_ACTION_REQUIRED.md"
        ".claude/PIPELINE_STATE.md"
        ".claude/logs/RUN_SUMMARY.json"
        ".claude/logs/CAUSAL_LOG.jsonl"
    )

    for f in "${files[@]}"; do
        local full_path="${PROJECT_DIR:-.}/${f}"
        if [[ -f "$full_path" ]] && [[ -s "$full_path" ]]; then
            echo "- \`${f}\` — $(wc -l < "$full_path" | tr -d '[:space:]') lines"
        fi
    done
}

# --- Terminal summary --------------------------------------------------------

# print_diagnosis_summary
# Prints a colored terminal-friendly summary.
print_diagnosis_summary() {
    local class_color="$RED"
    case "$DIAG_CLASSIFICATION" in
        SUCCESS)        class_color="$GREEN" ;;
        QUOTA_EXHAUSTED) class_color="$YELLOW" ;;
        TRANSIENT_ERROR) class_color="$YELLOW" ;;
        UNKNOWN)        class_color="$YELLOW" ;;
    esac

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${NC}  ${class_color}DIAGNOSIS: ${DIAG_CLASSIFICATION}${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"

    # First suggestion as description
    if [[ ${#DIAG_SUGGESTIONS[@]} -gt 0 ]]; then
        echo -e "${BOLD}║${NC}  ${DIAG_SUGGESTIONS[0]}"
    fi

    # Cause chain (short)
    if [[ -n "$_DIAG_CAUSE_CHAIN_SHORT" ]]; then
        echo -e "${BOLD}║${NC}"
        echo -e "${BOLD}║${NC}  ${CYAN}Cause chain:${NC}"
        echo -e "${BOLD}║${NC}  ${_DIAG_CAUSE_CHAIN_SHORT}"
    fi

    # Suggestions
    if [[ ${#DIAG_SUGGESTIONS[@]} -gt 1 ]]; then
        echo -e "${BOLD}║${NC}"
        echo -e "${BOLD}║${NC}  ${BOLD}Suggestions:${NC}"
        local idx=1
        for suggestion in "${DIAG_SUGGESTIONS[@]:1}"; do
            if [[ "$suggestion" =~ ^[[:space:]] ]]; then
                echo -e "${BOLD}║${NC}  ${suggestion}"
            else
                echo -e "${BOLD}║${NC}  ${idx}. ${suggestion}"
                idx=$(( idx + 1 ))
            fi
        done
    fi

    # Recurring note
    if [[ -n "$_DIAG_RECURRING_NOTE" ]]; then
        echo -e "${BOLD}║${NC}"
        echo -e "${BOLD}║${NC}  ${YELLOW}${_DIAG_RECURRING_NOTE}${NC}"
    fi

    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Full report: DIAGNOSIS.md"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Failure context persistence ----------------------------------------------

# write_last_failure_context CLASSIFICATION STAGE OUTCOME
# Writes LAST_FAILURE_CONTEXT.json atomically for fast --diagnose startup.
write_last_failure_context() {
    local classification="${1:-UNKNOWN}"
    local stage="${2:-unknown}"
    local outcome="${3:-failure}"

    local ctx_file="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    local ctx_dir
    ctx_dir=$(dirname "$ctx_file")
    mkdir -p "$ctx_dir" 2>/dev/null || true

    local tmpfile="${ctx_file}.tmp.$$"
    local timestamp_iso
    timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Read previous consecutive count
    local prev_count=0
    if [[ -f "$ctx_file" ]]; then
        local prev_class
        prev_class=$(grep -oP '"classification"\s*:\s*"\K[^"]+' "$ctx_file" 2>/dev/null || true)
        if [[ "$prev_class" = "$classification" ]]; then
            prev_count=$(grep -oP '"consecutive_count"\s*:\s*\K[0-9]+' "$ctx_file" 2>/dev/null || true)
            prev_count="${prev_count//[!0-9]/}"
            : "${prev_count:=0}"
        fi
    fi
    local new_count=$(( prev_count + 1 ))

    # Escape task string
    local safe_task=""
    if [[ -n "${TASK:-}" ]]; then
        safe_task=$(printf '%s' "$TASK" | sed 's/\\/\\\\/g; s/"/\\"/g')
    fi

    printf '{\n  "classification": "%s",\n  "stage": "%s",\n  "outcome": "%s",\n  "task": "%s",\n  "consecutive_count": %d,\n  "timestamp": "%s"\n}\n' \
        "$classification" \
        "$stage" \
        "$outcome" \
        "$safe_task" \
        "$new_count" \
        "$timestamp_iso" \
        > "$tmpfile"

    mv "$tmpfile" "$ctx_file"
}

# --- Smart crash first-aid ---------------------------------------------------

# print_crash_first_aid
# Quick checks for common failure modes. Called from crash handler.
# No agent calls — pure shell checks. Must be fast.
print_crash_first_aid() {
    # Quota pause
    if [[ -f "${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED" ]]; then
        echo -e "\033[1;33m[!] Looks like a quota issue — the pipeline is paused and will resume\033[0m" >&2
        echo -e "\033[1;33m[!] when quota refreshes. Or run 'tekhton' to resume manually.\033[0m" >&2
        return 0
    fi

    # Build failure
    if [[ -f "${PROJECT_DIR:-.}/BUILD_ERRORS.md" ]] && [[ -s "${PROJECT_DIR:-.}/BUILD_ERRORS.md" ]]; then
        echo -e "\033[1;33m[!] Build failure detected — run 'tekhton --diagnose' for detailed\033[0m" >&2
        echo -e "\033[1;33m[!] analysis, or fix BUILD_ERRORS.md manually.\033[0m" >&2
        return 0
    fi

    # Resumable state
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    if [[ -f "$state_file" ]]; then
        local stage
        stage=$(awk '/^## Exit Stage$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
        echo -e "\033[1;33m[!] Crash during ${stage:-unknown} stage — your code is safe (checkpoint saved).\033[0m" >&2
        echo -e "\033[1;33m[!] Run 'tekhton' to resume from where it left off.\033[0m" >&2
        return 0
    fi

    # Transient error check in recent log
    local latest_log
    latest_log=$(find "${PROJECT_DIR:-.}/.claude/logs" -maxdepth 1 -name '*.log' -type f 2>/dev/null | head -1 || true)
    if [[ -n "$latest_log" ]]; then
        if tail -20 "$latest_log" 2>/dev/null | grep -qiE 'rate.limit|overloaded|server_error|timeout' 2>/dev/null; then
            echo -e "\033[1;33m[!] Transient API error detected. Re-run 'tekhton' to retry.\033[0m" >&2
            return 0
        fi
    fi
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

# --- Dashboard integration ----------------------------------------------------

# emit_dashboard_diagnosis
# Reads DIAGNOSIS.md and generates data/diagnosis.js for Watchtower.
emit_dashboard_diagnosis() {
    if ! command -v is_dashboard_enabled &>/dev/null || ! is_dashboard_enabled; then
        return 0
    fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ -d "${dash_dir}/data" ]] || return 0

    local json
    if [[ -n "$DIAG_CLASSIFICATION" ]] && [[ "$DIAG_CLASSIFICATION" != "SUCCESS" ]]; then
        # Build suggestions JSON array
        local sugg_json="["
        local first=true
        for s in "${DIAG_SUGGESTIONS[@]}"; do
            local safe_s
            safe_s=$(printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g')
            if [[ "$first" = true ]]; then first=false; else sugg_json="${sugg_json},"; fi
            sugg_json="${sugg_json}\"${safe_s}\""
        done
        sugg_json="${sugg_json}]"

        local safe_chain=""
        if [[ -n "$_DIAG_CAUSE_CHAIN_SHORT" ]]; then
            safe_chain=$(printf '%s' "$_DIAG_CAUSE_CHAIN_SHORT" | sed 's/\\/\\\\/g; s/"/\\"/g')
        fi

        json=$(printf '{"available":true,"classification":"%s","confidence":"%s","stage":"%s","cause_chain":"%s","suggestions":%s,"recurring_count":%d}' \
            "$DIAG_CLASSIFICATION" \
            "$DIAG_CONFIDENCE" \
            "$(_json_escape "${_DIAG_PIPELINE_STAGE:-}")" \
            "$safe_chain" \
            "$sugg_json" \
            "$_DIAG_RECURRING_COUNT")
    else
        json='{"available":false}'
    fi

    _write_js_file "${dash_dir}/data/diagnosis.js" "TK_DIAGNOSIS" "$json"
}
