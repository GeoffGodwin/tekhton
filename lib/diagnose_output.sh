#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_output.sh — Output/reporting functions for the diagnostic engine
#
# Sourced by lib/diagnose.sh — do not run directly.
# Expects: _DIAG_* module state variables declared in diagnose.sh
# Expects: DIAG_CLASSIFICATION, DIAG_CONFIDENCE, DIAG_SUGGESTIONS set by
#          classify_failure_diag in diagnose.sh
# Expects: PROJECT_DIR, Color codes (RED, GREEN, YELLOW, CYAN, BOLD, NC) (set by caller)
#
# Provides:
#   generate_diagnosis_report     — write ${DIAGNOSIS_FILE}
#   _list_relevant_files          — list files relevant to diagnosis
#   print_diagnosis_summary       — terminal output with box formatting
#   write_last_failure_context    — write LAST_FAILURE_CONTEXT.json
#   print_crash_first_aid         — quick first-aid checks for terminal
#   emit_dashboard_diagnosis      — generate data/diagnosis.js for Watchtower
# =============================================================================

# --- Report generator --------------------------------------------------------

# generate_diagnosis_report
# Produces ${DIAGNOSIS_FILE} with causal chain, classification, suggestions.
generate_diagnosis_report() {
    local report_file="${PROJECT_DIR:-.}/${DIAGNOSIS_FILE}"
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

        # Recommended recovery command (M82)
        if command -v _diagnose_recovery_command &>/dev/null; then
            local recovery_cmd
            recovery_cmd=$(_diagnose_recovery_command 2>/dev/null || echo "")
            if [[ -n "$recovery_cmd" ]]; then
                echo "## Recommended Recovery"
                echo ""
                echo '```'
                echo "$recovery_cmd"
                echo '```'
                echo ""
            fi
        fi

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
        "${BUILD_ERRORS_FILE}"
        "${REVIEWER_REPORT_FILE}"
        "${CODER_SUMMARY_FILE}"
        "${TESTER_REPORT_FILE}"
        "${SECURITY_REPORT_FILE}"
        "${CLARIFICATIONS_FILE}"
        "${HUMAN_ACTION_FILE}"
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
# Prints a terminal-friendly summary. Routes through the output bus so
# TUI-mode callers get structured events instead of raw ANSI output.
print_diagnosis_summary() {
    out_banner "DIAGNOSIS: ${DIAG_CLASSIFICATION}"

    # First suggestion as description
    if [[ ${#DIAG_SUGGESTIONS[@]} -gt 0 ]]; then
        out_msg "  ${DIAG_SUGGESTIONS[0]}"
    fi

    # Cause chain (short)
    if [[ -n "$_DIAG_CAUSE_CHAIN_SHORT" ]]; then
        out_msg ""
        out_msg "  Cause chain:"
        out_msg "    ${_DIAG_CAUSE_CHAIN_SHORT}"
    fi

    # Suggestions
    if [[ ${#DIAG_SUGGESTIONS[@]} -gt 1 ]]; then
        out_msg ""
        out_msg "  Suggestions:"
        local idx=1
        for suggestion in "${DIAG_SUGGESTIONS[@]:1}"; do
            if [[ "$suggestion" =~ ^[[:space:]] ]]; then
                out_msg "    ${suggestion}"
            else
                out_msg "    ${idx}. ${suggestion}"
                idx=$(( idx + 1 ))
            fi
        done
    fi

    # Recurring note
    if [[ -n "$_DIAG_RECURRING_NOTE" ]]; then
        out_msg ""
        out_kv "Recurring" "${_DIAG_RECURRING_NOTE}" warn
    fi

    # Recommended recovery (M82)
    if command -v _diagnose_recovery_command &>/dev/null; then
        local recovery_cmd
        recovery_cmd=$(_diagnose_recovery_command 2>/dev/null || echo "")
        if [[ -n "$recovery_cmd" ]]; then
            out_msg ""
            out_msg "  Recommended recovery:"
            out_msg "    ${recovery_cmd}"
        fi
    fi

    out_msg ""
    out_msg "  Full report: ${DIAGNOSIS_FILE}"
    out_msg ""
}

# --- Failure context persistence (M129 schema v2) ----------------------------

# write_last_failure_context CLASSIFICATION STAGE OUTCOME
# Writes LAST_FAILURE_CONTEXT.json atomically for fast --diagnose startup.
#
# M129 schema v2: emits schema_version, classification, stage, outcome, task,
# consecutive_count, timestamp, top-level category/subcategory aliases (when
# resolvable), plus nested primary_cause / secondary_cause objects (when slots
# populated). Pretty-print contract (one key per line, multi-line nested
# objects) is load-bearing — downstream parsers in m130/m132/m133 use
# grep -oP line scans, not jq. See lib/failure_context.sh for the slot API.
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

    local safe_task=""
    if [[ -n "${TASK:-}" ]]; then
        safe_task=$(printf '%s' "$TASK" | sed 's/\\/\\\\/g; s/"/\\"/g')
    fi

    local alias_cat="" alias_sub=""
    if command -v resolve_alias_category &>/dev/null; then
        alias_cat=$(resolve_alias_category)
        alias_sub=$(resolve_alias_subcategory)
    fi

    {
        printf '{\n'
        printf '  "schema_version": 2,\n'
        printf '  "classification": "%s",\n' "$classification"
        printf '  "stage": "%s",\n' "$stage"
        printf '  "outcome": "%s",\n' "$outcome"
        printf '  "task": "%s",\n' "$safe_task"
        printf '  "consecutive_count": %d,\n' "$new_count"
        printf '  "timestamp": "%s"' "$timestamp_iso"
        if [[ -n "$alias_cat" ]]; then
            printf ',\n  "category": "%s"' "$alias_cat"
        fi
        if [[ -n "$alias_sub" ]]; then
            printf ',\n  "subcategory": "%s"' "$alias_sub"
        fi
        if command -v emit_cause_objects_json &>/dev/null; then
            local cause_block
            cause_block=$(emit_cause_objects_json "  ")
            if [[ -n "$cause_block" ]]; then
                # emit_cause_objects_json terminates each emitted object with
                # ",\n". We need a leading comma+newline before the first
                # object and must strip the trailing ",\n" so the JSON closes
                # cleanly with `}`.
                printf ',\n'
                printf '%s' "${cause_block%,$'\n'}"
            fi
        fi
        printf '\n}\n'
    } > "$tmpfile"

    mv "$tmpfile" "$ctx_file"
}

# Crash first-aid + dashboard integration moved to diagnose_output_extra.sh
# (M129) to keep this file under the 300-line ceiling.
