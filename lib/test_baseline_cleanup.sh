#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_baseline_cleanup.sh — Baseline cleanup and exit code helpers
#
# Extracted from test_baseline.sh to keep it under the 300-line ceiling.
# Sourced by tekhton.sh after test_baseline.sh — do not run directly.
# Depends on: _test_baseline_json(), _test_baseline_output() from test_baseline.sh
# =============================================================================

# get_baseline_exit_code
# Returns the exit code from the baseline JSON, or empty string if unavailable.
get_baseline_exit_code() {
    local baseline_json
    baseline_json=$(_test_baseline_json)
    [[ -f "$baseline_json" ]] || { echo ""; return 0; }
    grep -oP '"exit_code"\s*:\s*\K[0-9]+' "$baseline_json" 2>/dev/null || echo ""
}

# cleanup_stale_baselines
# Removes TEST_BASELINE.json and TEST_BASELINE_OUTPUT.txt files whose run_id
# does not match the current TIMESTAMP (stale from prior runs).
# Called during finalization to prevent cross-run baseline leakage.
cleanup_stale_baselines() {
    local baseline_json
    baseline_json=$(_test_baseline_json)
    [[ -f "$baseline_json" ]] || return 0

    local baseline_run_id
    baseline_run_id=$(grep -oP '"run_id"\s*:\s*"\K[^"]+' "$baseline_json" 2>/dev/null || echo "")

    # If run_id matches current run, keep it (potential resume)
    if [[ "$baseline_run_id" = "${TIMESTAMP:-}" ]]; then
        return 0
    fi

    # Stale baseline — remove
    log "[baseline] Cleaning up stale baseline (run_id=${baseline_run_id:-missing}, current=${TIMESTAMP:-unknown})"
    rm -f "$baseline_json"

    local baseline_output
    baseline_output=$(_test_baseline_output)
    rm -f "$baseline_output"

    # Also clean up acceptance output tmp file
    rm -f "${PROJECT_DIR:-.}/.claude/test_acceptance_output.tmp"

    if command -v emit_event &>/dev/null; then
        emit_event "baseline_cleanup" "pipeline" \
            "removed stale baseline (run_id=${baseline_run_id:-missing})" \
            "" "" "" \
            2>/dev/null || true
    fi
}
