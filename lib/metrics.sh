#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# metrics.sh — Run metrics collection, adaptive turn calibration, dashboard
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn(), success() from common.sh
# Expects: LOG_DIR, PROJECT_DIR from caller
# Provides: record_run_metrics(), _extract_stage_turns(), _classify_task_type()
# Note: calibrate_turn_estimate() has been extracted to lib/metrics_calibration.sh
# Note: summarize_metrics(), _avg_field(), _scout_accuracy() extracted to lib/metrics_dashboard.sh
# =============================================================================

# --- Metrics file location ---------------------------------------------------

_METRICS_FILE=""

_ensure_metrics_file() {
    if [[ -n "$_METRICS_FILE" ]]; then
        return
    fi
    local log_dir="${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}"
    mkdir -p "$log_dir" 2>/dev/null || true
    _METRICS_FILE="${log_dir}/metrics.jsonl"
}

# =============================================================================
# _classify_task_type — Heuristic task classification from task string
#
# Returns: "bug", "milestone", "polish", "drift", or "feature" (default)
# =============================================================================

_classify_task_type() {
    local task="$1"
    local lower
    lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

    if echo "$lower" | grep -qE '(\[bug\]|^fix|bug|bugfix|hotfix|patch|regression|broken|crash)'; then
        echo "bug"
    elif echo "$lower" | grep -qE '(^milestone|milestone [0-9])'; then
        echo "milestone"
    elif echo "$lower" | grep -qE '\[polish\]'; then
        echo "polish"
    elif echo "$lower" | grep -qE '(drift|audit)'; then
        echo "drift"
    else
        echo "feature"
    fi
}

# =============================================================================
# record_run_metrics — Appends a JSONL record to metrics.jsonl
#
# Usage: record_run_metrics
# Reads pipeline globals: TASK, MILESTONE_MODE, TOTAL_TURNS, TOTAL_TIME,
#   STAGE_SUMMARY, LAST_AGENT_TURNS, LAST_CONTEXT_TOKENS, VERDICT,
#   SCOUT_REC_CODER_TURNS, ADJUSTED_CODER_TURNS, etc.
#
# JSONL is append-only — never reads/modifies existing records.
# =============================================================================

record_run_metrics() {
    if [[ "${METRICS_ENABLED:-true}" != "true" ]]; then
        return
    fi

    _ensure_metrics_file

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local task_type
    task_type=$(_classify_task_type "${TASK:-unknown}")

    local milestone_mode="${MILESTONE_MODE:-false}"
    local total_turns="${TOTAL_TURNS:-0}"
    local verdict="${VERDICT:-unknown}"

    # Per-stage data from STAGE_SUMMARY (format: "\n  Label: N/M turns, Xm Ys")
    local coder_turns=0
    local reviewer_turns=0
    local tester_turns=0
    local scout_turns=0

    if [[ -n "${STAGE_SUMMARY:-}" ]]; then
        coder_turns=$(_extract_stage_turns "$STAGE_SUMMARY" "Coder")
        reviewer_turns=$(_extract_stage_turns "$STAGE_SUMMARY" "Reviewer")
        tester_turns=$(_extract_stage_turns "$STAGE_SUMMARY" "Tester")
        scout_turns=$(_extract_stage_turns "$STAGE_SUMMARY" "Scout")
    fi

    # Block 1: primary stage durations from _STAGE_DURATION (coder/reviewer/tester/scout/security/cleanup)
    local coder_duration_s=0 reviewer_duration_s=0 tester_duration_s=0 scout_duration_s=0
    local security_duration_s=0 cleanup_duration_s=0
    if declare -p _STAGE_DURATION &>/dev/null; then
        coder_duration_s="${_STAGE_DURATION[coder]:-0}"
        reviewer_duration_s="${_STAGE_DURATION[reviewer]:-0}"
        tester_duration_s="${_STAGE_DURATION[tester]:-0}"
        scout_duration_s="${_STAGE_DURATION[scout]:-0}"
        security_duration_s="${_STAGE_DURATION[security]:-0}"
        cleanup_duration_s="${_STAGE_DURATION[cleanup]:-0}"
    fi

    # Block 2: extended stages via _collect_extended_stage_vars() (turns + durations for test_audit/analyze_cleanup/specialists/cycles; also security/cleanup turns)
    local security_turns=0 cleanup_turns=0
    local test_audit_turns=0 test_audit_duration_s=0
    local analyze_cleanup_turns=0 analyze_cleanup_duration_s=0
    local specialist_security_turns=0 specialist_perf_turns=0 specialist_api_turns=0
    local review_cycles=0 security_rework_cycles=0
    local _ext_line
    while IFS='=' read -r _ext_key _ext_val; do
        [[ -z "$_ext_key" ]] && continue
        printf -v "$_ext_key" '%s' "$_ext_val"
    done < <(_collect_extended_stage_vars)

    # Compute total_time from stage durations (wall-clock) rather than
    # TOTAL_TIME (agent-invocation-only sum) to match finalize_summary.sh
    # and give accurate run durations in the dashboard.
    local computed_time=0
    local _stg_name
    if declare -p _STAGE_DURATION &>/dev/null; then
        for _stg_name in "${!_STAGE_DURATION[@]}"; do
            computed_time=$(( computed_time + ${_STAGE_DURATION[$_stg_name]:-0} ))
        done
    fi
    local total_time="$computed_time"
    if [[ "$total_time" -eq 0 ]]; then
        total_time="${TOTAL_TIME:-0}"
    fi

    # Scout estimates vs actual
    local scout_est_coder="${SCOUT_REC_CODER_TURNS:-0}"
    local scout_est_reviewer="${SCOUT_REC_REVIEWER_TURNS:-0}"
    local scout_est_tester="${SCOUT_REC_TESTER_TURNS:-0}"
    local adjusted_coder="${ADJUSTED_CODER_TURNS:-0}"
    local adjusted_reviewer="${ADJUSTED_REVIEWER_TURNS:-0}"
    local adjusted_tester="${ADJUSTED_TESTER_TURNS:-0}"

    # Context size
    local context_tokens="${LAST_CONTEXT_TOKENS:-0}"

    # Retry count (13.2.2)
    local retry_count="${LAST_AGENT_RETRY_COUNT:-0}"

    # Continuation attempts (14)
    local continuation_attempts="${CONTINUATION_ATTEMPTS:-0}"

    # Orchestration loop fields (M16)
    local pipeline_attempts="${_ORCH_ATTEMPT:-0}"
    local total_agent_calls="${_ORCH_AGENT_CALLS:-0}"

    # Sanitize core numeric fields — strip non-numeric content that may leak
    # from log() output captured via $() subshells.
    # Extended stage fields are pre-sanitized by _collect_extended_stage_vars().
    total_turns=$(_sanitize_numeric "$total_turns")
    total_time=$(_sanitize_numeric "$total_time")
    coder_turns=$(_sanitize_numeric "$coder_turns")
    reviewer_turns=$(_sanitize_numeric "$reviewer_turns")
    tester_turns=$(_sanitize_numeric "$tester_turns")
    scout_turns=$(_sanitize_numeric "$scout_turns")
    scout_est_coder=$(_sanitize_numeric "$scout_est_coder")
    scout_est_reviewer=$(_sanitize_numeric "$scout_est_reviewer")
    scout_est_tester=$(_sanitize_numeric "$scout_est_tester")
    adjusted_coder=$(_sanitize_numeric "$adjusted_coder")
    adjusted_reviewer=$(_sanitize_numeric "$adjusted_reviewer")
    adjusted_tester=$(_sanitize_numeric "$adjusted_tester")
    context_tokens=$(_sanitize_numeric "$context_tokens")
    retry_count=$(_sanitize_numeric "$retry_count")
    continuation_attempts=$(_sanitize_numeric "$continuation_attempts")
    pipeline_attempts=$(_sanitize_numeric "$pipeline_attempts")
    coder_duration_s=$(_sanitize_numeric "$coder_duration_s")
    reviewer_duration_s=$(_sanitize_numeric "$reviewer_duration_s")
    tester_duration_s=$(_sanitize_numeric "$tester_duration_s")
    scout_duration_s=$(_sanitize_numeric "$scout_duration_s")
    security_duration_s=$(_sanitize_numeric "$security_duration_s")
    cleanup_duration_s=$(_sanitize_numeric "$cleanup_duration_s")
    total_agent_calls=$(_sanitize_numeric "$total_agent_calls")

    # Outcome
    local outcome="unknown"
    case "$verdict" in
        APPROVED|APPROVED_WITH_NOTES) outcome="success" ;;
        CHANGES_REQUIRED) outcome="rework_needed" ;;
        *) outcome="$verdict" ;;
    esac

    # Error classification fields (12.3 — only populated on non-success)
    local error_category="${AGENT_ERROR_CATEGORY:-}"
    local error_subcategory="${AGENT_ERROR_SUBCATEGORY:-}"
    local error_transient="${AGENT_ERROR_TRANSIENT:-}"

    # Escape task string for JSON (replace backslash, double-quote, newlines)
    local safe_task
    safe_task=$(printf '%s' "${TASK:-}" | tr '\n\r' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Build JSONL record (single line, no jq dependency)
    local record
    record=$(printf '{"timestamp":"%s","task":"%s","task_type":"%s","milestone_mode":%s,"total_turns":%d,"total_time_s":%d,"coder_turns":%d,"reviewer_turns":%d,"tester_turns":%d,"scout_turns":%d,"scout_est_coder":%d,"scout_est_reviewer":%d,"scout_est_tester":%d,"adjusted_coder":%d,"adjusted_reviewer":%d,"adjusted_tester":%d,"context_tokens":%d,"retry_count":%d,"continuation_attempts":%d,"verdict":"%s","outcome":"%s"' \
        "$timestamp" \
        "$safe_task" \
        "$task_type" \
        "$milestone_mode" \
        "$total_turns" \
        "$total_time" \
        "$coder_turns" \
        "$reviewer_turns" \
        "$tester_turns" \
        "$scout_turns" \
        "$scout_est_coder" \
        "$scout_est_reviewer" \
        "$scout_est_tester" \
        "$adjusted_coder" \
        "$adjusted_reviewer" \
        "$adjusted_tester" \
        "$context_tokens" \
        "$retry_count" \
        "$continuation_attempts" \
        "$verdict" \
        "$outcome")

    # Append per-stage durations when available
    if [[ "$coder_duration_s" -gt 0 || "$reviewer_duration_s" -gt 0 || "$tester_duration_s" -gt 0 || "$scout_duration_s" -gt 0 ]]; then
        record="${record},\"coder_duration_s\":${coder_duration_s},\"reviewer_duration_s\":${reviewer_duration_s},\"tester_duration_s\":${tester_duration_s},\"scout_duration_s\":${scout_duration_s}"
    fi

    # Append extended stage metrics (M66) — security, cleanup, specialists, cycles
    record=$(_append_extended_stage_record "$record" \
        "$security_turns" "$security_duration_s" \
        "$cleanup_turns" "$cleanup_duration_s" \
        "$test_audit_turns" "$test_audit_duration_s" \
        "$analyze_cleanup_turns" "$analyze_cleanup_duration_s" \
        "$specialist_security_turns" "$specialist_perf_turns" "$specialist_api_turns" \
        "$review_cycles" "$security_rework_cycles")

    # Append orchestration fields when in --complete mode (M16)
    if [[ "$pipeline_attempts" -gt 0 ]]; then
        record="${record},\"pipeline_attempts\":${pipeline_attempts},\"total_agent_calls\":${total_agent_calls}"
    fi

    # Append indexer metrics when available (M7)
    if [[ -n "${INDEXER_CACHE_HIT_RATE:-}" ]]; then
        record="${record},\"indexer_hit_rate\":${INDEXER_CACHE_HIT_RATE}"
    fi
    if [[ -n "${INDEXER_GENERATION_TIME_MS:-}" ]] && [[ "${INDEXER_GENERATION_TIME_MS:-0}" -gt 0 ]]; then
        record="${record},\"indexer_gen_time_ms\":${INDEXER_GENERATION_TIME_MS}"
    fi

    # Append intake metrics when populated (M10)
    if [[ -n "${INTAKE_VERDICT:-}" ]]; then
        local intake_confidence="${INTAKE_CONFIDENCE:-0}"
        intake_confidence=$(echo "$intake_confidence" | grep -oE '[0-9]+' | tail -1)
        intake_confidence="${intake_confidence:-0}"
        local intake_tweaks_applied="false"
        if [[ "${INTAKE_VERDICT}" == "TWEAKED" ]]; then
            intake_tweaks_applied="true"
        fi
        local intake_questions=0
        if [[ "${INTAKE_VERDICT}" == "NEEDS_CLARITY" ]] && [[ -f "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}" ]]; then
            intake_questions=$(awk '/^## Questions/{found=1; next} found && /^## /{exit} found && /^- /{count++} END{print count+0}' "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}" 2>/dev/null || echo "0")
            intake_questions=$(echo "$intake_questions" | grep -oE '[0-9]+' | tail -1)
            intake_questions="${intake_questions:-0}"
        fi
        record="${record},\"intake_verdict\":\"${INTAKE_VERDICT}\",\"intake_confidence\":${intake_confidence},\"intake_tweaks_applied\":${intake_tweaks_applied},\"intake_questions_asked\":${intake_questions}"
    fi

    # Append error fields only when populated (12.3)
    if [[ -n "$error_category" ]]; then
        record="${record},\"error_category\":\"${error_category}\",\"error_subcategory\":\"${error_subcategory}\",\"error_transient\":${error_transient:-false}"
    fi

    # Append note execution metrics when in --human mode (M42)
    if [[ "${HUMAN_MODE:-false}" = "true" ]] || [[ -n "${NOTES_FILTER:-}" ]]; then
        local _note_tag="${NOTES_FILTER:-unknown}"
        local _note_acceptance="${NOTE_ACCEPTANCE_RESULT:-}"
        local _reviewer_skipped="${REVIEWER_SKIPPED:-false}"
        local _note_id=""
        if [[ -n "${CLAIMED_NOTE_IDS:-}" ]]; then
            _note_id="${CLAIMED_NOTE_IDS%% *}"  # First claimed note ID
        fi
        # Escape for JSON
        _note_tag=$(printf '%s' "$_note_tag" | sed 's/"/\\"/g')
        _note_acceptance=$(printf '%s' "$_note_acceptance" | sed 's/"/\\"/g')
        _note_id=$(printf '%s' "$_note_id" | sed 's/"/\\"/g')
        record="${record},\"note_id\":\"${_note_id}\",\"note_tag\":\"${_note_tag}\",\"note_acceptance\":\"${_note_acceptance}\",\"reviewer_skipped\":${_reviewer_skipped}"
    fi

    record="${record}}"

    echo "$record" >> "$_METRICS_FILE"
}

# --- Helper: extract turns for a stage from STAGE_SUMMARY -------------------
# STAGE_SUMMARY format: "\n  Coder (claude-sonnet-4-6): 45/100 turns, 5m30s"
# Also handles legacy format without model suffix: "\n  Coder: 45/100 turns, 5m30s"
# Returns the first number (actual turns used).

_extract_stage_turns() {
    local summary="$1"
    local stage_label="$2"
    # Match "Label:" or "Label (suffix):" patterns
    local turns
    turns=$(echo -e "$summary" | grep -i "${stage_label}" | head -1 | \
        grep -oE '[0-9]+/' | head -1 | tr -d '/' || true)
    echo "${turns:-0}"
}


