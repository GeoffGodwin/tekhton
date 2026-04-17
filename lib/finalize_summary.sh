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

    # Quota pause statistics (M16)
    local quota_json="{\"total_pause_time_s\":0,\"pause_count\":0,\"was_quota_limited\":false}"
    if command -v get_quota_stats_json &>/dev/null; then
        quota_json=$(get_quota_stats_json)
    fi

    # Test audit verdict (M20)
    local test_audit_verdict="skipped"
    if [[ "${TEST_AUDIT_ENABLED:-true}" = "true" ]]; then
        local _audit_rpt="${TEST_AUDIT_REPORT_FILE:-}"
        if [[ -f "$_audit_rpt" ]]; then
            test_audit_verdict=$(grep -oiE 'Verdict:\s*(NEEDS_WORK|PASS|CONCERNS)' "$_audit_rpt" 2>/dev/null \
                | head -1 | sed 's/.*:\s*//' | tr '[:lower:]' '[:upper:]' || echo "unknown")
            : "${test_audit_verdict:=unknown}"
        fi
    fi

    # Test baseline status
    local baseline_status="disabled"
    if [[ "${TEST_BASELINE_ENABLED:-true}" = "true" ]]; then
        if declare -f has_test_baseline &>/dev/null && has_test_baseline 2>/dev/null; then
            local _bl_json="${PROJECT_DIR:-.}/.claude/TEST_BASELINE.json"
            local _bl_exit
            _bl_exit=$(grep -oP '"exit_code"\s*:\s*\K[0-9]+' "$_bl_json" 2>/dev/null || echo "0")
            if [[ "$_bl_exit" -eq 0 ]]; then
                baseline_status="clean"
            else
                baseline_status="pre_existing_failures"
            fi
        else
            baseline_status="not_captured"
        fi
    fi

    # UI validation results (M29)
    local ui_validation_pass="${UI_VALIDATION_PASS_COUNT:-0}"
    local ui_validation_fail="${UI_VALIDATION_FAIL_COUNT:-0}"
    local ui_validation_warn="${UI_VALIDATION_WARN_COUNT:-0}"

    # Parallel team fields (M37)
    local team_id="${CURRENT_TEAM_ID:-}"
    local parallel_group="${CURRENT_PARALLEL_GROUP:-}"
    local concurrent_teams="${CONCURRENT_TEAM_COUNT:-0}"

    # --- Per-stage data (M34 §1) ---
    # Serialize _STAGE_TURNS, _STAGE_DURATION, _STAGE_BUDGET in deterministic order.
    local stages_json="{"
    local stage_first=true
    local _stg
    for _stg in "${!_STAGE_DURATION[@]}"; do
        local _s_turns="${_STAGE_TURNS[$_stg]:-0}"
        local _s_dur="${_STAGE_DURATION[$_stg]:-0}"
        local _s_budget="${_STAGE_BUDGET[$_stg]:-0}"
        # Only emit stages that have non-zero data
        if [[ "$_s_turns" -eq 0 ]] && [[ "$_s_dur" -eq 0 ]] && [[ "$_s_budget" -eq 0 ]]; then
            continue
        fi
        if [[ "$stage_first" = true ]]; then stage_first=false; else stages_json="${stages_json},"; fi
        # M62: Include tester timing sub-fields when available
        # Guard: always emit for tester stage; defaults to -1 (unavailable sentinel)
        local _stg_extra=""
        if [[ "$_stg" == "tester" ]]; then
            _stg_extra=",\"test_execution_count\":${_TESTER_TIMING_EXEC_COUNT:--1},\"test_execution_approx_s\":${_TESTER_TIMING_EXEC_APPROX_S:--1},\"test_writing_approx_s\":${_TESTER_TIMING_WRITING_S:--1}"
        fi
        stages_json="${stages_json}\"${_stg}\":{\"turns\":${_s_turns},\"duration_s\":${_s_dur},\"budget\":${_s_budget}${_stg_extra}}"
    done
    stages_json="${stages_json}}"

    # --- Computed totals from stage data (M34 §5) ---
    local computed_turns=0
    local computed_time=0
    for _stg in "${!_STAGE_DURATION[@]}"; do
        computed_turns=$(( computed_turns + ${_STAGE_TURNS[$_stg]:-0} ))
        computed_time=$(( computed_time + ${_STAGE_DURATION[$_stg]:-0} ))
    done
    # Use stage sums as ground truth; fall back to orchestrator counters if zero
    local total_turns="$computed_turns"
    if [[ "$total_turns" -eq 0 ]]; then
        total_turns="${_ORCH_AGENT_CALLS:-0}"
    fi
    local total_time_s="$computed_time"
    if [[ "$total_time_s" -eq 0 ]]; then
        total_time_s="${_ORCH_ELAPSED:-0}"
    fi

    # --- Run type classification (M34 §2) ---
    local run_type="adhoc"
    if [[ -n "${_CURRENT_MILESTONE:-}" ]] && [[ "${_CURRENT_MILESTONE}" != "none" ]]; then
        run_type="milestone"
    elif [[ "${HUMAN_MODE:-false}" = "true" ]]; then
        case "${HUMAN_NOTES_TAG:-}" in
            BUG)    run_type="human_bug" ;;
            FEAT)   run_type="human_feat" ;;
            POLISH) run_type="human_polish" ;;
            *)      run_type="human" ;;
        esac
    elif [[ "${FIX_DRIFT_MODE:-false}" = "true" ]]; then
        run_type="drift"
    elif [[ "${FIX_NONBLOCKERS_MODE:-false}" = "true" ]]; then
        run_type="nonblocker"
    fi
    # Task label: first ~80 chars of TASK for display
    local task_label=""
    if [[ -n "${TASK:-}" ]]; then
        task_label=$(printf '%s' "$TASK" | head -c 80 | sed 's/\\/\\\\/g; s/"/\\"/g')
    fi

    local timestamp_iso
    timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local safe_milestone
    safe_milestone=$(printf '%s' "${_CURRENT_MILESTONE:-none}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Escape team fields for JSON
    local safe_team
    safe_team=$(printf '%s' "$team_id" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local safe_pgroup
    safe_pgroup=$(printf '%s' "$parallel_group" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # --- Pipeline decisions and timing breakdown (M50) ---
    local decisions_json="[]"
    if command -v _get_decision_log &>/dev/null; then
        decisions_json=$(_get_decision_log)
    fi
    local timing_json="{}"
    if command -v _get_timing_breakdown &>/dev/null; then
        timing_json=$(_get_timing_breakdown)
    fi

    # --- Remediation log (M54) ---
    local remediations_json="[]"
    if command -v get_remediation_log &>/dev/null; then
        remediations_json=$(get_remediation_log)
    fi

    # Write JSON via printf (proper escaping, no heredoc variable issues)
    printf '{\n  "milestone": "%s",\n  "outcome": "%s",\n  "attempts": %d,\n  "total_agent_calls": %d,\n  "wall_clock_seconds": %d,\n  "total_turns": %d,\n  "total_time_s": %d,\n  "run_type": "%s",\n  "task_label": "%s",\n  "stages": %s,\n  "files_changed": %s,\n  "error_classes_encountered": %s,\n  "recovery_actions_taken": %s,\n  "rework_cycles": %d,\n  "split_depth": %d,\n  "security_findings_count": %d,\n  "security_rework_cycles": %d,\n  "intake_verdict": "%s",\n  "intake_confidence": %d,\n  "quota": %s,\n  "test_baseline_status": "%s",\n  "test_audit_verdict": "%s",\n  "ui_validation": {"pass": %d, "fail": %d, "warn": %d},\n  "team": "%s",\n  "parallel_group": "%s",\n  "concurrent_teams": %d,\n  "decisions": %s,\n  "timing_breakdown": %s,\n  "remediations": %s,\n  "timestamp": "%s"\n}\n' \
        "$safe_milestone" \
        "$outcome" \
        "${_ORCH_ATTEMPT:-1}" \
        "${_ORCH_AGENT_CALLS:-0}" \
        "${_ORCH_ELAPSED:-0}" \
        "$total_turns" \
        "$total_time_s" \
        "$run_type" \
        "$task_label" \
        "$stages_json" \
        "$files_json" \
        "$error_classes" \
        "$recovery_actions" \
        "$rework_cycles" \
        "$split_depth" \
        "$security_findings_count" \
        "$security_rework_cycles" \
        "$intake_verdict" \
        "$intake_confidence" \
        "$quota_json" \
        "$baseline_status" \
        "$test_audit_verdict" \
        "$ui_validation_pass" \
        "$ui_validation_fail" \
        "$ui_validation_warn" \
        "$safe_team" \
        "$safe_pgroup" \
        "$concurrent_teams" \
        "$decisions_json" \
        "$timing_json" \
        "$remediations_json" \
        "$timestamp_iso" \
        > "$summary_file"

    # Archive a timestamped copy so _parse_run_summaries finds all historical runs.
    # The glob RUN_SUMMARY*.json in dashboard_parsers.sh picks up both the live
    # file and all archived copies, sorted newest-first by mtime.
    local ts="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
    cp "$summary_file" "${summary_dir}/RUN_SUMMARY_${ts}.json" 2>/dev/null || true

    log_verbose "Run summary written to ${summary_file}"
}
