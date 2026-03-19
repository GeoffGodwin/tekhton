#!/usr/bin/env bash
# =============================================================================
# metrics.sh — Run metrics collection, adaptive turn calibration, dashboard
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn(), success() from common.sh
# Expects: LOG_DIR, PROJECT_DIR from caller
# Provides: record_run_metrics(), summarize_metrics(), calibrate_turn_estimate()
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
# Returns: "bug", "milestone", or "feature" (default)
# =============================================================================

_classify_task_type() {
    local task="$1"
    local lower
    lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

    if echo "$lower" | grep -qE '(^fix|bug|bugfix|hotfix|patch|regression|broken|crash)'; then
        echo "bug"
    elif echo "$lower" | grep -qE '(^milestone|milestone [0-9])'; then
        echo "milestone"
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
    local total_time="${TOTAL_TIME:-0}"
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

    # Sanitize all numeric fields — strip any non-numeric content that may leak
    # from log() output captured via $() subshells
    total_turns=$(echo "$total_turns" | grep -oE '[0-9]+' | tail -1); total_turns="${total_turns:-0}"
    total_time=$(echo "$total_time" | grep -oE '[0-9]+' | tail -1); total_time="${total_time:-0}"
    coder_turns=$(echo "$coder_turns" | grep -oE '[0-9]+' | tail -1); coder_turns="${coder_turns:-0}"
    reviewer_turns=$(echo "$reviewer_turns" | grep -oE '[0-9]+' | tail -1); reviewer_turns="${reviewer_turns:-0}"
    tester_turns=$(echo "$tester_turns" | grep -oE '[0-9]+' | tail -1); tester_turns="${tester_turns:-0}"
    scout_turns=$(echo "$scout_turns" | grep -oE '[0-9]+' | tail -1); scout_turns="${scout_turns:-0}"
    scout_est_coder=$(echo "$scout_est_coder" | grep -oE '[0-9]+' | tail -1); scout_est_coder="${scout_est_coder:-0}"
    scout_est_reviewer=$(echo "$scout_est_reviewer" | grep -oE '[0-9]+' | tail -1); scout_est_reviewer="${scout_est_reviewer:-0}"
    scout_est_tester=$(echo "$scout_est_tester" | grep -oE '[0-9]+' | tail -1); scout_est_tester="${scout_est_tester:-0}"
    adjusted_coder=$(echo "$adjusted_coder" | grep -oE '[0-9]+' | tail -1); adjusted_coder="${adjusted_coder:-0}"
    adjusted_reviewer=$(echo "$adjusted_reviewer" | grep -oE '[0-9]+' | tail -1); adjusted_reviewer="${adjusted_reviewer:-0}"
    adjusted_tester=$(echo "$adjusted_tester" | grep -oE '[0-9]+' | tail -1); adjusted_tester="${adjusted_tester:-0}"
    context_tokens=$(echo "$context_tokens" | grep -oE '[0-9]+' | tail -1); context_tokens="${context_tokens:-0}"
    retry_count=$(echo "$retry_count" | grep -oE '[0-9]+' | tail -1); retry_count="${retry_count:-0}"
    continuation_attempts=$(echo "$continuation_attempts" | grep -oE '[0-9]+' | tail -1); continuation_attempts="${continuation_attempts:-0}"

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

    # Append error fields only when populated (12.3)
    if [[ -n "$error_category" ]]; then
        record="${record},\"error_category\":\"${error_category}\",\"error_subcategory\":\"${error_subcategory}\",\"error_transient\":${error_transient:-false}"
    fi

    record="${record}}"

    echo "$record" >> "$_METRICS_FILE"
}

# --- Helper: extract turns for a stage from STAGE_SUMMARY -------------------
# STAGE_SUMMARY format: "\n  Coder: 45/100 turns, 5m30s"
# Returns the first number (actual turns used).

_extract_stage_turns() {
    local summary="$1"
    local stage_label="$2"
    # Match "Label:" or "Label (suffix):" patterns
    local turns
    turns=$(echo -e "$summary" | grep -i "${stage_label}" | head -1 | \
        grep -oE '[0-9]+/' | head -1 | tr -d '/' || echo "0")
    echo "${turns:-0}"
}

# =============================================================================
# summarize_metrics — Reads last N runs and prints a dashboard
#
# Usage: summarize_metrics [max_records]
# Default max_records: 50
# =============================================================================

summarize_metrics() {
    local max_records="${1:-50}"

    _ensure_metrics_file

    if [[ ! -f "$_METRICS_FILE" ]] || [[ ! -s "$_METRICS_FILE" ]]; then
        echo "No metrics data found."
        return
    fi

    local total_lines
    total_lines=$(wc -l < "$_METRICS_FILE" | tr -d '[:space:]')

    # Read last N records
    local records
    records=$(tail -n "$max_records" "$_METRICS_FILE")

    # Count by task type
    local bug_count feature_count milestone_count
    bug_count=$(echo "$records" | grep -c '"task_type":"bug"' || echo "0")
    feature_count=$(echo "$records" | grep -c '"task_type":"feature"' || echo "0")
    milestone_count=$(echo "$records" | grep -c '"task_type":"milestone"' || echo "0")

    # Count successes by type
    local bug_success feature_success milestone_success
    bug_success=$(echo "$records" | grep '"task_type":"bug"' | grep -c '"outcome":"success"' || echo "0")
    feature_success=$(echo "$records" | grep '"task_type":"feature"' | grep -c '"outcome":"success"' || echo "0")
    milestone_success=$(echo "$records" | grep '"task_type":"milestone"' | grep -c '"outcome":"success"' || echo "0")

    # Average coder turns by type
    local bug_avg_turns feature_avg_turns milestone_avg_turns
    bug_avg_turns=$(_avg_field "$records" "bug" "coder_turns")
    feature_avg_turns=$(_avg_field "$records" "feature" "coder_turns")
    milestone_avg_turns=$(_avg_field "$records" "milestone" "coder_turns")

    # Scout accuracy (average absolute difference between estimate and actual)
    local scout_coder_acc scout_reviewer_acc scout_tester_acc
    scout_coder_acc=$(_scout_accuracy "$records" "scout_est_coder" "coder_turns")
    scout_reviewer_acc=$(_scout_accuracy "$records" "scout_est_reviewer" "reviewer_turns")
    scout_tester_acc=$(_scout_accuracy "$records" "scout_est_tester" "tester_turns")

    # Success rate calculation helper
    _pct() {
        local success="$1" total="$2"
        if [[ "$total" -eq 0 ]]; then
            echo "N/A"
        else
            echo "$(( success * 100 / total ))%"
        fi
    }

    echo "Tekhton Metrics — last ${max_records} runs (${total_lines} total)"
    echo "────────────────────────────────────────"

    if [[ "$bug_count" -gt 0 ]]; then
        echo "Bug fixes:     ${bug_count} runs, avg ${bug_avg_turns} coder turns, $(_pct "$bug_success" "$bug_count") success"
    fi
    if [[ "$feature_count" -gt 0 ]]; then
        echo "Features:      ${feature_count} runs, avg ${feature_avg_turns} coder turns, $(_pct "$feature_success" "$feature_count") success"
    fi
    if [[ "$milestone_count" -gt 0 ]]; then
        echo "Milestones:    ${milestone_count} runs, avg ${milestone_avg_turns} coder turns, $(_pct "$milestone_success" "$milestone_count") success"
    fi

    echo "────────────────────────────────────────"
    echo "Scout accuracy: coder ±${scout_coder_acc} turns, reviewer ±${scout_reviewer_acc}, tester ±${scout_tester_acc}"

    # Retry statistics (13.2.2)
    local total_retries=0
    local runs_with_retries=0
    local record_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local rc
        rc=$(echo "$line" | grep -oE '"retry_count":[0-9]+' | grep -oE '[0-9]+$' || echo "")
        if [[ -n "$rc" ]]; then
            total_retries=$(( total_retries + rc ))
            record_count=$(( record_count + 1 ))
            if [[ "$rc" -gt 0 ]]; then
                runs_with_retries=$(( runs_with_retries + 1 ))
            fi
        fi
    done <<< "$records"

    if [[ "$total_retries" -gt 0 ]]; then
        echo "Retries:       ${total_retries} total across ${runs_with_retries} runs (avg $(( total_retries * 100 / record_count )) per 100 invocations)"
    fi

    # Error breakdown by category (12.3)
    local has_errors=false
    local upstream_count env_count agent_count pipeline_count
    upstream_count=$(echo "$records" | grep -c '"error_category":"UPSTREAM"' || echo "0")
    env_count=$(echo "$records" | grep -c '"error_category":"ENVIRONMENT"' || echo "0")
    agent_count=$(echo "$records" | grep -c '"error_category":"AGENT_SCOPE"' || echo "0")
    pipeline_count=$(echo "$records" | grep -c '"error_category":"PIPELINE"' || echo "0")

    if [[ "$upstream_count" -gt 0 ]] || [[ "$env_count" -gt 0 ]] || \
       [[ "$agent_count" -gt 0 ]] || [[ "$pipeline_count" -gt 0 ]]; then
        has_errors=true
    fi

    if [[ "$has_errors" = true ]]; then
        echo "────────────────────────────────────────"
        echo "Error breakdown:"
        if [[ "$upstream_count" -gt 0 ]]; then
            echo "  UPSTREAM:     ${upstream_count} (all transient — auto-retry would resolve)"
        fi
        if [[ "$env_count" -gt 0 ]]; then
            local env_transient
            env_transient=$(echo "$records" | grep '"error_category":"ENVIRONMENT"' | grep -c '"error_transient":true' || echo "0")
            echo "  ENVIRONMENT:  ${env_count} (${env_transient} transient)"
        fi
        if [[ "$agent_count" -gt 0 ]]; then
            echo "  AGENT_SCOPE:  ${agent_count} (permanent — scope or turn issues)"
        fi
        if [[ "$pipeline_count" -gt 0 ]]; then
            echo "  PIPELINE:     ${pipeline_count} (permanent — internal errors)"
        fi
    fi

    echo "────────────────────────────────────────"
}

# --- Helper: average a numeric field for a task type from JSONL records ------

_avg_field() {
    local records="$1"
    local task_type="$2"
    local field="$3"

    local type_records
    type_records=$(echo "$records" | grep "\"task_type\":\"${task_type}\"" || true)

    if [[ -z "$type_records" ]]; then
        echo "0"
        return
    fi

    local sum=0
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local val
        val=$(echo "$line" | grep -oE "\"${field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        sum=$(( sum + val ))
        count=$(( count + 1 ))
    done <<< "$type_records"

    if [[ "$count" -eq 0 ]]; then
        echo "0"
    else
        echo "$(( sum / count ))"
    fi
}

# --- Helper: scout accuracy (avg absolute diff between estimate and actual) --

_scout_accuracy() {
    local records="$1"
    local est_field="$2"
    local actual_field="$3"

    local sum=0
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local est actual
        est=$(echo "$line" | grep -oE "\"${est_field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        actual=$(echo "$line" | grep -oE "\"${actual_field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        # Skip records where scout didn't estimate (est=0)
        if [[ "$est" -gt 0 ]]; then
            local diff=$(( est - actual ))
            # Absolute value
            if [[ "$diff" -lt 0 ]]; then
                diff=$(( -diff ))
            fi
            sum=$(( sum + diff ))
            count=$(( count + 1 ))
        fi
    done <<< "$records"

    if [[ "$count" -eq 0 ]]; then
        echo "N/A"
    else
        echo "$(( sum / count ))"
    fi
}

# =============================================================================
# calibrate_turn_estimate — Adjusts turn estimate based on historical accuracy
#
# Usage: calibrate_turn_estimate RECOMMENDATION STAGE
#   RECOMMENDATION: scout's recommended turns (integer)
#   STAGE: "coder", "reviewer", or "tester"
# Returns: adjusted turn count on stdout
#
# Only applies calibration when METRICS_ADAPTIVE_TURNS=true and at least
# METRICS_MIN_RUNS records exist. Returns the original estimate unchanged
# when insufficient data is available.
#
# Calibration multiplier = actual_avg / estimate_avg, clamped to [0.5, 2.0].
# =============================================================================

calibrate_turn_estimate() {
    local recommendation="$1"
    local stage="$2"

    # Short-circuit if adaptive calibration is disabled
    if [[ "${METRICS_ADAPTIVE_TURNS:-true}" != "true" ]]; then
        echo "$recommendation"
        return
    fi

    _ensure_metrics_file

    if [[ ! -f "$_METRICS_FILE" ]] || [[ ! -s "$_METRICS_FILE" ]]; then
        echo "$recommendation"
        return
    fi

    local min_runs="${METRICS_MIN_RUNS:-5}"
    local total_lines
    total_lines=$(wc -l < "$_METRICS_FILE" | tr -d '[:space:]')

    if [[ "$total_lines" -lt "$min_runs" ]]; then
        echo "$recommendation"
        return
    fi

    # Determine field names based on stage
    local est_field actual_field
    case "$stage" in
        coder)    est_field="scout_est_coder";    actual_field="coder_turns" ;;
        reviewer) est_field="scout_est_reviewer";  actual_field="reviewer_turns" ;;
        tester)   est_field="scout_est_tester";    actual_field="tester_turns" ;;
        *)
            echo "$recommendation"
            return
            ;;
    esac

    # Read last 50 records
    local records
    records=$(tail -n 50 "$_METRICS_FILE")

    # Compute average estimate and average actual for records where est > 0
    local est_sum=0 actual_sum=0 count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local est actual
        est=$(echo "$line" | grep -oE "\"${est_field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        actual=$(echo "$line" | grep -oE "\"${actual_field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        if [[ "$est" -gt 0 ]] && [[ "$actual" -gt 0 ]]; then
            est_sum=$(( est_sum + est ))
            actual_sum=$(( actual_sum + actual ))
            count=$(( count + 1 ))
        fi
    done <<< "$records"

    # Need enough data points with scout estimates
    if [[ "$count" -lt "$min_runs" ]]; then
        echo "$recommendation"
        return
    fi

    # Calculate multiplier: actual_avg / estimate_avg
    # Using integer arithmetic: (actual_sum * 100) / est_sum gives centimultiplier
    local centimult
    centimult=$(( actual_sum * 100 / est_sum ))

    # Clamp to [50, 200] (representing 0.5x to 2.0x)
    if [[ "$centimult" -lt 50 ]]; then
        centimult=50
    elif [[ "$centimult" -gt 200 ]]; then
        centimult=200
    fi

    # Apply multiplier: (recommendation * centimult + 50) / 100 (rounded)
    local adjusted
    adjusted=$(( (recommendation * centimult + 50) / 100 ))

    # Never go below 1
    if [[ "$adjusted" -lt 1 ]]; then
        adjusted=1
    fi

    echo "$adjusted"
}
