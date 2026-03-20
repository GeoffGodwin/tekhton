#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# metrics_dashboard.sh — Metrics dashboard and summary helpers
#
# Sourced by tekhton.sh — do not run directly.
# Expects: _ensure_metrics_file(), _METRICS_FILE from metrics.sh
# Provides: summarize_metrics(), _avg_field(), _scout_accuracy()
# =============================================================================

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
    bug_count=$(echo "$records" | grep -c '"task_type":"bug"' || true)
    feature_count=$(echo "$records" | grep -c '"task_type":"feature"' || true)
    milestone_count=$(echo "$records" | grep -c '"task_type":"milestone"' || true)

    # Count successes by type
    local bug_success feature_success milestone_success
    bug_success=$(echo "$records" | grep '"task_type":"bug"' | grep -c '"outcome":"success"' || true)
    feature_success=$(echo "$records" | grep '"task_type":"feature"' | grep -c '"outcome":"success"' || true)
    milestone_success=$(echo "$records" | grep '"task_type":"milestone"' | grep -c '"outcome":"success"' || true)

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

    # Success rate calculation (inlined to avoid polluting global namespace)
    local bug_pct="N/A" feature_pct="N/A" milestone_pct="N/A"
    if [[ "$bug_count" -gt 0 ]]; then
        bug_pct="$(( bug_success * 100 / bug_count ))%"
    fi
    if [[ "$feature_count" -gt 0 ]]; then
        feature_pct="$(( feature_success * 100 / feature_count ))%"
    fi
    if [[ "$milestone_count" -gt 0 ]]; then
        milestone_pct="$(( milestone_success * 100 / milestone_count ))%"
    fi

    echo "Tekhton Metrics — last ${max_records} runs (${total_lines} total)"
    echo "────────────────────────────────────────"

    if [[ "$bug_count" -gt 0 ]]; then
        echo "Bug fixes:     ${bug_count} runs, avg ${bug_avg_turns} coder turns, ${bug_pct} success"
    fi
    if [[ "$feature_count" -gt 0 ]]; then
        echo "Features:      ${feature_count} runs, avg ${feature_avg_turns} coder turns, ${feature_pct} success"
    fi
    if [[ "$milestone_count" -gt 0 ]]; then
        echo "Milestones:    ${milestone_count} runs, avg ${milestone_avg_turns} coder turns, ${milestone_pct} success"
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
    upstream_count=$(echo "$records" | grep -c '"error_category":"UPSTREAM"' || true)
    env_count=$(echo "$records" | grep -c '"error_category":"ENVIRONMENT"' || true)
    agent_count=$(echo "$records" | grep -c '"error_category":"AGENT_SCOPE"' || true)
    pipeline_count=$(echo "$records" | grep -c '"error_category":"PIPELINE"' || true)

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
            env_transient=$(echo "$records" | grep '"error_category":"ENVIRONMENT"' | grep -c '"error_transient":true' || true)
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
        val=$(echo "$line" | grep -oE "\"${field}\":[0-9]+" | grep -oE '[0-9]+$' || true)
        sum=$(( sum + ${val:-0} ))
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
        est=$(echo "$line" | grep -oE "\"${est_field}\":[0-9]+" | grep -oE '[0-9]+$' || true)
        actual=$(echo "$line" | grep -oE "\"${actual_field}\":[0-9]+" | grep -oE '[0-9]+$' || true)
        # Skip records where scout didn't estimate (est=0)
        if [[ "$est" -gt 0 ]]; then
            local diff=$(( ${est:-0} - ${actual:-0} ))
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
