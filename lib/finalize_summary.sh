#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize_summary.sh — RUN_SUMMARY.json emission hook (Milestone 16)
#
# Sourced by finalize.sh — do not run directly.
# Expects: LOG_DIR, PROJECT_DIR, _CURRENT_MILESTONE, _ORCH_ATTEMPT,
#          _ORCH_AGENT_CALLS, _ORCH_ELAPSED, _ORCH_NO_PROGRESS_COUNT,
#          _ORCH_REVIEW_BUMPED, AUTONOMOUS_TIMEOUT, AGENT_ERROR_CATEGORY,
#          AGENT_ERROR_SUBCATEGORY, CONTINUATION_ATTEMPTS,
#          LAST_AGENT_RETRY_COUNT, REVIEW_CYCLE, MILESTONE_CURRENT_SPLIT_DEPTH
#
# Provides:
#   _hook_emit_run_summary — writes RUN_SUMMARY.json to LOG_DIR
# =============================================================================

# k. Emit RUN_SUMMARY.json (runs on BOTH success and failure)
_hook_emit_run_summary() {
    local exit_code="$1"

    local summary_dir="${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}"
    mkdir -p "$summary_dir" 2>/dev/null || true
    local summary_file="${summary_dir}/RUN_SUMMARY.json"

    # Determine outcome
    local outcome="unknown"
    if [[ "$exit_code" -eq 0 ]]; then
        outcome="success"
    elif [[ -n "${_ORCH_ATTEMPT:-}" ]] && [[ "${_ORCH_ELAPSED:-0}" -ge "${AUTONOMOUS_TIMEOUT:-7200}" ]]; then
        outcome="timeout"
    elif [[ "${_ORCH_NO_PROGRESS_COUNT:-0}" -ge 2 ]]; then
        outcome="stuck"
    else
        outcome="failure"
    fi

    # Collect files changed
    local files_json="[]"
    local changed_files
    changed_files=$(git diff --name-only HEAD 2>/dev/null || true)
    if [[ -n "$changed_files" ]]; then
        files_json="["
        local first=true
        while IFS= read -r filepath; do
            [[ -z "$filepath" ]] && continue
            # Escape special JSON characters in file paths
            local safe_path
            safe_path=$(printf '%s' "$filepath" | sed 's/\\/\\\\/g; s/"/\\"/g')
            if [[ "$first" = true ]]; then
                files_json="${files_json}\"${safe_path}\""
                first=false
            else
                files_json="${files_json},\"${safe_path}\""
            fi
        done <<< "$changed_files"
        files_json="${files_json}]"
    fi

    # Collect error classes encountered
    local error_classes="[]"
    if [[ -n "${AGENT_ERROR_CATEGORY:-}" ]]; then
        error_classes="[\"${AGENT_ERROR_CATEGORY}/${AGENT_ERROR_SUBCATEGORY:-unknown}\"]"
    fi

    # Collect recovery actions taken
    local recovery_actions="[]"
    local ra_items=()
    if [[ "${_ORCH_REVIEW_BUMPED:-false}" = true ]]; then
        ra_items+=("\"review_cycle_bump\"")
    fi
    if [[ "${CONTINUATION_ATTEMPTS:-0}" -gt 0 ]]; then
        ra_items+=("\"continuation\"")
    fi
    if [[ "${LAST_AGENT_RETRY_COUNT:-0}" -gt 0 ]]; then
        ra_items+=("\"transient_retry\"")
    fi
    if [[ ${#ra_items[@]} -gt 0 ]]; then
        local joined
        joined=$(printf ',%s' "${ra_items[@]}")
        recovery_actions="[${joined:1}]"
    fi

    # Rework cycles and split depth
    local rework_cycles="${REVIEW_CYCLE:-0}"
    rework_cycles=$(echo "$rework_cycles" | grep -oE '[0-9]+' | tail -1 || echo "0")
    rework_cycles="${rework_cycles:-0}"
    local split_depth="${MILESTONE_CURRENT_SPLIT_DEPTH:-0}"
    split_depth=$(echo "$split_depth" | grep -oE '[0-9]+' | tail -1 || echo "0")
    split_depth="${split_depth:-0}"

    # Security findings summary
    local security_findings_count=0
    if [[ -n "${SECURITY_FINDINGS_BLOCK:-}" ]]; then
        security_findings_count=$(echo "$SECURITY_FINDINGS_BLOCK" | grep -c '^- ' || true)
    fi
    local security_rework_cycles="${SECURITY_REWORK_CYCLES_DONE:-0}"

    # Intake verdict (M10)
    local intake_verdict="${INTAKE_VERDICT:-none}"
    local intake_confidence="${INTAKE_CONFIDENCE:-0}"
    intake_confidence=$(echo "$intake_confidence" | grep -oE '[0-9]+' | tail -1)
    intake_confidence="${intake_confidence:-0}"

    local timestamp_iso
    timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local safe_milestone
    safe_milestone=$(printf '%s' "${_CURRENT_MILESTONE:-none}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Write JSON via printf (proper escaping, no heredoc variable issues)
    printf '{\n  "milestone": "%s",\n  "outcome": "%s",\n  "attempts": %d,\n  "total_agent_calls": %d,\n  "wall_clock_seconds": %d,\n  "files_changed": %s,\n  "error_classes_encountered": %s,\n  "recovery_actions_taken": %s,\n  "rework_cycles": %d,\n  "split_depth": %d,\n  "security_findings_count": %d,\n  "security_rework_cycles": %d,\n  "intake_verdict": "%s",\n  "intake_confidence": %d,\n  "timestamp": "%s"\n}\n' \
        "$safe_milestone" \
        "$outcome" \
        "${_ORCH_ATTEMPT:-1}" \
        "${_ORCH_AGENT_CALLS:-0}" \
        "${_ORCH_ELAPSED:-0}" \
        "$files_json" \
        "$error_classes" \
        "$recovery_actions" \
        "$rework_cycles" \
        "$split_depth" \
        "$security_findings_count" \
        "$security_rework_cycles" \
        "$intake_verdict" \
        "$intake_confidence" \
        "$timestamp_iso" \
        > "$summary_file"

    log "Run summary written to ${summary_file}"
}
