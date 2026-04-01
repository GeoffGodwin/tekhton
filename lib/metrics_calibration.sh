#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# metrics_calibration.sh — Adaptive turn calibration from historical metrics
#
# Sourced by tekhton.sh — do not run directly.
# Expects: _ensure_metrics_file(), _METRICS_FILE from metrics.sh
# Provides: calibrate_turn_estimate()
# =============================================================================

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
    local est_field actual_field adjusted_field
    case "$stage" in
        coder)    est_field="scout_est_coder";    actual_field="coder_turns";    adjusted_field="adjusted_coder" ;;
        reviewer) est_field="scout_est_reviewer";  actual_field="reviewer_turns"; adjusted_field="adjusted_reviewer" ;;
        tester)   est_field="scout_est_tester";    actual_field="tester_turns";   adjusted_field="adjusted_tester" ;;
        *)
            echo "$recommendation"
            return
            ;;
    esac

    # Read last 50 records
    local records
    records=$(tail -n 50 "$_METRICS_FILE")

    # Compute average estimate and average actual for records where est > 0.
    # IMPORTANT: Skip records where the agent hit its turn limit (actual >= adjusted * 0.85).
    # Capped records poison the calibration — they record "turns allowed" not "turns needed",
    # creating a negative feedback loop that drives limits progressively lower.
    local est_sum=0 actual_sum=0 count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local est actual adjusted
        est=$(echo "$line" | grep -oE "\"${est_field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        actual=$(echo "$line" | grep -oE "\"${actual_field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        adjusted=$(echo "$line" | grep -oE "\"${adjusted_field}\":[0-9]+" | grep -oE '[0-9]+$' || echo "0")
        if [[ "$est" -gt 0 ]] && [[ "$actual" -gt 0 ]]; then
            # Skip capped records: if the agent used >= 85% of its allocated turns,
            # it likely hit the limit rather than finishing naturally
            if [[ "$adjusted" -gt 0 ]] && [[ $(( actual * 100 / adjusted )) -ge 85 ]]; then
                continue
            fi
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

    # M48: Floor at 50% of the original recommendation to prevent
    # pathological under-provisioning from noisy historical data.
    local floor=$(( (recommendation + 1) / 2 ))
    if [[ "$adjusted" -lt "$floor" ]]; then
        adjusted="$floor"
    fi

    # Never go below 1
    if [[ "$adjusted" -lt 1 ]]; then
        adjusted=1
    fi

    echo "$adjusted"
}
