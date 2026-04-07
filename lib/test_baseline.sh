#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_baseline.sh — Test baseline capture and pre-existing failure detection
#
# Prevents the orchestration loop from wasting retries on pre-existing test
# failures unrelated to the current milestone. Two-tier protection:
# 1. Baseline comparison in check_milestone_acceptance() — pre-existing
#    failures don't block acceptance
# 2. Stuck detection in run_complete_loop() — identical acceptance failures
#    across consecutive attempts trigger early exit
#
# Sourced by orchestrate.sh — do not run directly.
# Expects: TEST_CMD (from config), PROJECT_DIR
# Expects: log(), warn(), success() from common.sh
# Expects: emit_event() from causality.sh (optional, guarded)
#
# Provides:
#   capture_test_baseline         — run TEST_CMD and save baseline output
#   has_test_baseline             — check if baseline exists for current milestone
#   compare_test_with_baseline    — classify failures as pre-existing vs new
#   save_acceptance_test_output   — save acceptance test output for stuck detection
#   get_acceptance_output_hash    — hash of last acceptance test output
#   _normalize_test_output        — strip non-deterministic content from output
#   _extract_failure_lines        — extract failure-indicating lines
#   _check_acceptance_stuck       — stuck detection for orchestration loop
# =============================================================================

# --- File paths (computed from PROJECT_DIR) -----------------------------------

_test_baseline_json() {
    echo "${PROJECT_DIR:-.}/.claude/TEST_BASELINE.json"
}

_test_baseline_output() {
    echo "${PROJECT_DIR:-.}/.claude/TEST_BASELINE_OUTPUT.txt"
}

# --- Normalization helpers ----------------------------------------------------

# _normalize_test_output
# Strips non-deterministic content from test output for stable hashing.
# Reads from stdin, writes to stdout. Preserves test names and assertions.
_normalize_test_output() {
    sed -E \
        -e 's/\x1b\[[0-9;]*[mGKHJ]//g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?[Z]?/TIMESTAMP/g' \
        -e 's/[0-9]+\.[0-9]+s/N.NNs/g' \
        -e 's/in [0-9]+ seconds?/in N seconds/g' \
        -e 's/[0-9]+ms/Nms/g' \
        -e 's/[0-9]+\.[0-9]+ seconds?/N.NN seconds/g' \
        -e 's/pid[[:space:]]*[0-9]+/pid NNN/gi' \
        -e 's/0x[0-9a-fA-F]+/0xADDR/g'
}

# _extract_failure_lines
# Extracts lines indicating test failures. Framework-agnostic: covers
# pytest, Go test, Jest/Mocha, Cargo test, JUnit, and generic patterns.
# Reads from stdin, writes to stdout.
_extract_failure_lines() {
    grep -iE \
        '(^FAIL[[:space:]]|^---[[:space:]]*FAIL|FAILED|FAILURE[S]?|^ERROR[[:space:]]|ERROR:|AssertionError|assert.*failed|panic:|failures:)' \
        || true
}

# _hash_content
# Returns md5 hash of stdin. Same pattern as _compute_diff_hash in
# orchestrate_recovery.sh.
_hash_content() {
    md5sum 2>/dev/null | cut -d' ' -f1 || echo "no-hash"
}

# --- Baseline capture ---------------------------------------------------------

# capture_test_baseline [MILESTONE]
# Runs TEST_CMD and saves baseline output + metadata JSON.
# Called once at the start of run_complete_loop(), before any pipeline attempt.
capture_test_baseline() {
    local milestone="${1:-${_CURRENT_MILESTONE:-unknown}}"

    if [[ -z "${TEST_CMD:-}" ]] || [[ "${TEST_CMD}" = "true" ]]; then
        log "[baseline] No TEST_CMD configured — skipping baseline capture"
        return 0
    fi

    log "[baseline] Capturing test baseline for milestone ${milestone}..."

    local test_output=""
    local test_exit=0
    test_output=$(bash -c "${TEST_CMD}" 2>&1) || test_exit=$?

    # Save raw output (atomic write via tmpfile+mv)
    local baseline_output
    baseline_output=$(_test_baseline_output)
    local baseline_dir
    baseline_dir="$(dirname "$baseline_output")"
    mkdir -p "$baseline_dir" 2>/dev/null || true

    local tmp_output="${baseline_output}.tmp.$$"
    printf '%s\n' "$test_output" > "$tmp_output"
    mv "$tmp_output" "$baseline_output"

    # Compute hashes
    local output_hash
    output_hash=$(printf '%s' "$test_output" | _normalize_test_output | _hash_content)

    local failure_hash
    failure_hash=$(printf '%s' "$test_output" | _normalize_test_output | _extract_failure_lines | sort | _hash_content)

    local failure_count
    failure_count=$(printf '%s' "$test_output" | _extract_failure_lines | wc -l | tr -d '[:space:]')
    failure_count="${failure_count:-0}"

    # Write metadata JSON (atomic via tmpfile+mv)
    local baseline_json
    baseline_json=$(_test_baseline_json)

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

    local tmp_json="${baseline_json}.tmp.$$"
    printf '{\n  "run_id": "%s",\n  "timestamp": "%s",\n  "milestone": "%s",\n  "exit_code": %d,\n  "output_hash": "%s",\n  "failure_hash": "%s",\n  "failure_count": %s\n}\n' \
        "${TIMESTAMP:-unknown}" \
        "$timestamp" \
        "$milestone" \
        "$test_exit" \
        "$output_hash" \
        "$failure_hash" \
        "$failure_count" \
        > "$tmp_json"
    mv "$tmp_json" "$baseline_json"

    if [[ "$test_exit" -eq 0 ]]; then
        log "[baseline] Tests pass at baseline — no pre-existing failures"
    else
        warn "[baseline] Tests FAIL at baseline (exit ${test_exit}, ${failure_count} failure lines)"
        warn "[baseline] These pre-existing failures will not block acceptance"
    fi

    # Emit causal event
    if command -v emit_event &>/dev/null; then
        emit_event "test_baseline" "pipeline" \
            "exit=${test_exit}, failures=${failure_count}" \
            "" "" \
            "{\"exit_code\":${test_exit},\"failure_count\":${failure_count},\"output_hash\":\"${output_hash}\",\"failure_hash\":\"${failure_hash}\"}" \
            2>/dev/null || true
    fi

    return 0
}

# --- Baseline queries ---------------------------------------------------------

# has_test_baseline [MILESTONE]
# Returns 0 if a baseline exists for the given milestone, 1 otherwise.
# shellcheck disable=SC2120  # Called with args from milestone_acceptance.sh
has_test_baseline() {
    local milestone="${1:-${_CURRENT_MILESTONE:-unknown}}"
    local baseline_json
    baseline_json=$(_test_baseline_json)

    [[ -f "$baseline_json" ]] || return 1

    local baseline_milestone
    baseline_milestone=$(grep -oP '"milestone"\s*:\s*"\K[^"]+' "$baseline_json" 2>/dev/null || echo "")

    [[ "$baseline_milestone" = "$milestone" ]]
}

# _should_capture_test_baseline
# Returns 0 if a baseline should be captured, 1 if not needed.
# Checks run_id to distinguish same-run resume from new-run stale baseline.
_should_capture_test_baseline() {
    [[ "${TEST_BASELINE_ENABLED:-true}" = "true" ]] || return 1
    [[ -n "${TEST_CMD:-}" ]] && [[ "${TEST_CMD}" != "true" ]] || return 1

    # No baseline file at all → capture
    # shellcheck disable=SC2119  # Uses default arg (milestone from global)
    if ! has_test_baseline 2>/dev/null; then
        return 0
    fi

    # Baseline exists — check run_id for staleness
    local baseline_json
    baseline_json=$(_test_baseline_json)
    local baseline_run_id
    baseline_run_id=$(grep -oP '"run_id"\s*:\s*"\K[^"]+' "$baseline_json" 2>/dev/null || echo "")

    # Missing run_id → pre-M63 baseline, treat as stale (backward compat)
    if [[ -z "$baseline_run_id" ]]; then
        return 0
    fi

    # Same run → skip (resume within same run)
    if [[ "$baseline_run_id" = "${TIMESTAMP:-}" ]]; then
        return 1
    fi

    # Different run → stale, re-capture
    return 0
}

# --- Baseline comparison (Tier 1) --------------------------------------------

# compare_test_with_baseline TEST_OUTPUT TEST_EXIT_CODE
# Compares current test failures against the captured baseline.
# Outputs one of: pre_existing, new_failures, inconclusive
compare_test_with_baseline() {
    local test_output="$1"
    local test_exit="$2"

    local baseline_json
    baseline_json=$(_test_baseline_json)

    [[ -f "$baseline_json" ]] || { echo "inconclusive"; return 0; }

    # Read baseline exit code
    local baseline_exit
    baseline_exit=$(grep -oP '"exit_code"\s*:\s*\K[0-9]+' "$baseline_json" 2>/dev/null || echo "0")

    # If baseline tests passed, all current failures are NEW
    if [[ "$baseline_exit" -eq 0 ]]; then
        echo "new_failures"
        return 0
    fi

    # Baseline had failures — compare failure signatures
    local baseline_failure_hash
    baseline_failure_hash=$(grep -oP '"failure_hash"\s*:\s*"\K[^"]+' "$baseline_json" 2>/dev/null || echo "")

    local current_failure_hash
    current_failure_hash=$(printf '%s' "$test_output" | _normalize_test_output | \
        _extract_failure_lines | sort | _hash_content)

    if [[ "$current_failure_hash" = "$baseline_failure_hash" ]]; then
        echo "pre_existing"
        return 0
    fi

    # Hashes differ — check if there are MORE failures now
    local baseline_failure_count
    baseline_failure_count=$(grep -oP '"failure_count"\s*:\s*\K[0-9]+' "$baseline_json" 2>/dev/null || echo "0")

    local current_failure_count
    current_failure_count=$(printf '%s' "$test_output" | _extract_failure_lines | \
        wc -l | tr -d '[:space:]')
    current_failure_count="${current_failure_count:-0}"

    if [[ "$current_failure_count" -gt "$baseline_failure_count" ]]; then
        echo "new_failures"
        return 0
    fi

    # Same or fewer count but different hash — inconclusive
    echo "inconclusive"
    return 0
}

# --- Acceptance output tracking (Tier 2) --------------------------------------

# save_acceptance_test_output OUTPUT EXIT_CODE
# Saves acceptance test output for cross-attempt comparison.
save_acceptance_test_output() {
    local output="$1"
    # shellcheck disable=SC2034  # exit_code reserved for future use
    local exit_code="$2"
    local out_file="${PROJECT_DIR:-.}/.claude/test_acceptance_output.tmp"
    mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
    printf '%s\n' "$output" > "$out_file" 2>/dev/null || true
}

# get_acceptance_output_hash
# Returns normalized hash of saved acceptance output. Empty string if no output.
get_acceptance_output_hash() {
    local out_file="${PROJECT_DIR:-.}/.claude/test_acceptance_output.tmp"
    if [[ -f "$out_file" ]]; then
        _normalize_test_output < "$out_file" | _hash_content
    else
        echo ""
    fi
}

# --- Stuck detection (Tier 2) ------------------------------------------------

# _check_acceptance_stuck
# Compares acceptance output hash across consecutive attempts.
# Returns: 0 = stuck + auto-pass, 1 = not stuck, 2 = stuck + exit
_check_acceptance_stuck() {
    local current_hash
    current_hash=$(get_acceptance_output_hash)

    [[ -n "$current_hash" ]] || return 1  # No output to compare

    if [[ "$current_hash" = "${_ORCH_LAST_ACCEPTANCE_HASH:-}" ]]; then
        _ORCH_IDENTICAL_ACCEPTANCE_COUNT=$(( _ORCH_IDENTICAL_ACCEPTANCE_COUNT + 1 ))
    else
        _ORCH_IDENTICAL_ACCEPTANCE_COUNT=1
        _ORCH_LAST_ACCEPTANCE_HASH="$current_hash"
        return 1
    fi

    local threshold="${TEST_BASELINE_STUCK_THRESHOLD:-2}"
    if [[ "$_ORCH_IDENTICAL_ACCEPTANCE_COUNT" -lt "$threshold" ]]; then
        return 1
    fi

    warn "Acceptance failure IDENTICAL for ${_ORCH_IDENTICAL_ACCEPTANCE_COUNT} consecutive attempts."
    warn "These appear to be pre-existing failures unrelated to this milestone."

    # Emit causal event
    if command -v emit_event &>/dev/null; then
        emit_event "acceptance_stuck" "pipeline" \
            "identical_failures=${_ORCH_IDENTICAL_ACCEPTANCE_COUNT}" \
            "" "" \
            "{\"hash\":\"${current_hash}\",\"consecutive\":${_ORCH_IDENTICAL_ACCEPTANCE_COUNT}}" \
            2>/dev/null || true
    fi

    if [[ "${TEST_BASELINE_PASS_ON_STUCK:-false}" = "true" ]]; then
        # Never auto-pass if baseline was clean — all failures are new regressions
        local _bl_exit
        _bl_exit=$(get_baseline_exit_code)
        if [[ "$_bl_exit" == "0" ]]; then
            warn "Stuck detected but baseline was clean — all failures are new regressions. NOT auto-passing."
            if command -v emit_event &>/dev/null; then
                emit_event "stuck_test_detected" "pipeline" \
                    "clean_baseline_block" \
                    "" "" \
                    "{\"hash\":\"${current_hash}\",\"baseline_exit\":0,\"consecutive\":${_ORCH_IDENTICAL_ACCEPTANCE_COUNT}}" \
                    2>/dev/null || true
            fi
            return 1
        fi
        warn "TEST_BASELINE_PASS_ON_STUCK=true — treating acceptance as PASSED."
        return 0
    else
        warn "Exiting to avoid burning more retries. Set TEST_BASELINE_PASS_ON_STUCK=true to auto-pass."
        return 2
    fi
}

# --- Baseline cleanup (extracted to test_baseline_cleanup.sh) ----------------
# get_baseline_exit_code() and cleanup_stale_baselines() are in
# lib/test_baseline_cleanup.sh, sourced by tekhton.sh after this file.
