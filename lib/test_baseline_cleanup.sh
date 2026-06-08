#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_baseline_cleanup.sh — Baseline cleanup and exit code helpers (bash).
#
# m38.5 — lib/test_baseline.sh was ported to internal/test_baseline/ and
# deleted. The two trivial path helpers (_test_baseline_json,
# _test_baseline_output) inlined here so this file no longer depends on a
# missing source. get_baseline_exit_code now execs the Go CLI; the rest of
# cleanup_stale_baselines stays bash through M38 — its port lands with
# the acceptance-gate port in a later milestone.
#
# Sourced by tekhton.sh / lib/orchestrate.sh — do not run directly.
# =============================================================================

_test_baseline_json() {
    echo "${PROJECT_DIR:-.}/.claude/TEST_BASELINE.json"
}

_test_baseline_output() {
    echo "${PROJECT_DIR:-.}/.claude/TEST_BASELINE_OUTPUT.txt"
}

# get_baseline_exit_code
# m38.5: now execs `tekhton baseline get-exit-code`. Falls back to the
# bash grep when the binary is unavailable so this still works in test
# sandboxes that don't have `tekhton` on PATH.
get_baseline_exit_code() {
    if command -v tekhton >/dev/null 2>&1; then
        tekhton baseline get-exit-code --project-dir "${PROJECT_DIR:-.}" 2>/dev/null || echo ""
        return 0
    fi
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
            >/dev/null 2>&1 || true
    fi
}
