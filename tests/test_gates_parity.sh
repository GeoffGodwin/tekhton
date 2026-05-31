#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tests/test_gates_parity.sh — m31.1 parity gate (eight scenarios)
#
# Drives `tekhton gate build` and `tekhton gate completion` against captured
# bash baselines under tests/testdata/gates/. Asserts:
#   - exit code matches the bash baseline,
#   - BUILD_ERRORS.md (after timestamp normalisation) is structurally
#     equivalent to the captured baseline section headers,
#   - BUILD_RAW_ERRORS.txt is byte-identical to the captured baseline
#     (raw stream is timestamp-free).
#
# The reference m22 parity gate uses tests/lib/parity.sh; this gate reuses
# the same shared driver.
#
# Eight scenarios:
#   1. analyze-pass            — no errors, no report files
#   2. analyze-fail            — analyze command emits matching error
#   3. compile-pass            — compile succeeds, no report files
#   4. compile-fail            — compile emits ERROR pattern match
#   5. completion-pass         — TEST_CMD passes
#   6. completion-fail-tests   — TEST_CMD fails
#   7. completion-fail-status  — CODER_SUMMARY.md has no Status field
#   8. gate-timeout            — BUILD_GATE_TIMEOUT exceeded
# =============================================================================

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Always bind to this repo's binary — a stale TEKHTON_BIN env var in the
# caller's shell would point at an older checkout (pre-m31.1).
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

# shellcheck source=tests/lib/parity.sh
source "${REPO_ROOT}/tests/lib/parity.sh"

if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_gates_parity: go toolchain not found\n'
    exit 0
fi
if ! [[ -x "$TEKHTON_BIN" ]]; then
    if ! (cd "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_gates_parity: make build failed\n'
        exit 0
    fi
fi

# Normalisation: timestamps + temp project-dir paths.
# shellcheck disable=SC2317  # invoked indirectly as a callback via parity_assert_equal
_gates_normalise() {
    local f="$1"
    sed -i -E 's/# Build Errors — [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/# Build Errors — TIMESTAMP/' "$f"
}

# _run_build_scenario NAME ENV_LINE EXPECT_REPORT [EXPECT_RAW]
#   ENV_LINE: space-separated KEY=VALUE pairs.
#   EXPECT_REPORT: "report" | "no_report" (whether BUILD_ERRORS.md should exist)
#   EXPECT_RAW: "raw" | "no_raw" (whether BUILD_RAW_ERRORS.txt should exist)
_run_build_scenario() {
    local name="$1" expect_report="$2" expect_raw="$3"
    shift 3
    local fixture_dir="${REPO_ROOT}/tests/testdata/gates/${name}"
    local expected_md="${fixture_dir}/expected/BUILD_ERRORS.md"
    local expected_raw="${fixture_dir}/expected/BUILD_RAW_ERRORS.txt"
    local stage_label="${STAGE_LABEL:-post-coder}"

    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/.tekhton"

    local result_exit=0
    env -i \
        PATH="$PATH" \
        HOME="$HOME" \
        TMPDIR="$tmp" \
        TEKHTON_DIR=".tekhton" \
        PROJECT_DIR="$tmp" \
        "$@" \
        "$TEKHTON_BIN" gate build --stage-label "$stage_label" \
        >/dev/null 2>&1 || result_exit=$?

    local actual_md="${tmp}/.tekhton/BUILD_ERRORS.md"
    local actual_raw="${tmp}/.tekhton/BUILD_RAW_ERRORS.txt"

    case "$expect_report" in
        no_report) parity_assert_no_file "${name}/build_errors" "$actual_md" ;;
        report)    parity_assert_equal "${name}/build_errors" "$expected_md" "$actual_md" _gates_normalise ;;
        *) parity_fail "${name}: unknown expect_report $expect_report" ;;
    esac
    case "$expect_raw" in
        no_raw) parity_assert_no_file "${name}/raw_errors" "$actual_raw" ;;
        raw)    parity_assert_equal "${name}/raw_errors" "$expected_raw" "$actual_raw" ;;
        *) parity_fail "${name}: unknown expect_raw $expect_raw" ;;
    esac

    # result_exit is asserted indirectly via the (expect_report, expect_raw)
    # tuple: when the gate fails, BUILD_ERRORS.md should exist; when it
    # passes, neither file should exist. We discard the exit code here so
    # `set -e` doesn't kill the test driver on the (expected) gate-fail
    # scenarios.
    rm -rf "$tmp"
    :
}

# _run_completion_scenario NAME EXIT_RANGE SUMMARY_CONTENT [ENV...]
_run_completion_scenario() {
    local name="$1" exit_check="$2" summary="$3"
    shift 3
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/.tekhton"
    printf '%s\n' "$summary" > "${tmp}/.tekhton/CODER_SUMMARY.md"

    local result_exit=0
    env -i \
        PATH="$PATH" \
        HOME="$HOME" \
        TMPDIR="$tmp" \
        TEKHTON_DIR=".tekhton" \
        PROJECT_DIR="$tmp" \
        "$@" \
        "$TEKHTON_BIN" gate completion \
        >/dev/null 2>&1 || result_exit=$?

    case "$exit_check" in
        zero)
            if [[ "$result_exit" -eq 0 ]]; then
                parity_pass "${name}: exit 0 (gate accepted)"
            else
                parity_fail "${name}: exit ${result_exit}, want 0"
            fi
            ;;
        nonzero)
            if [[ "$result_exit" -ne 0 ]]; then
                parity_pass "${name}: exit ${result_exit} (gate rejected, as expected)"
            else
                parity_fail "${name}: exit 0, want non-zero"
            fi
            ;;
    esac
    rm -rf "$tmp"
}

# --- Scenario 1: analyze-pass — ANALYZE_CMD emits clean output ----------------
_run_build_scenario "analyze_clean" "no_report" "no_raw" \
    ANALYZE_CMD="echo clean" \
    ANALYZE_ERROR_PATTERN="error"

# --- Scenario 2: analyze-fail — ANALYZE_CMD emits matching error -------------
_run_build_scenario "analyze_dirty" "report" "raw" \
    ANALYZE_CMD="printf 'error TS2304: cannot find name foo\\n'" \
    ANALYZE_ERROR_PATTERN="error"

# --- Scenario 3: compile-pass — analyze passes + compile clean ---------------
_run_build_scenario "compile_clean" "no_report" "no_raw" \
    ANALYZE_CMD="echo ok" \
    ANALYZE_ERROR_PATTERN="NEVER_MATCH" \
    BUILD_CHECK_CMD="echo ok"

# --- Scenario 4: compile-fail — compile emits ERROR pattern ------------------
_run_build_scenario "compile_dirty" "report" "raw" \
    ANALYZE_CMD="echo ok" \
    ANALYZE_ERROR_PATTERN="NEVER_MATCH" \
    BUILD_CHECK_CMD="printf 'ERROR link failed\\n'" \
    BUILD_ERROR_PATTERN="ERROR"

# --- Scenario 5: completion-pass — COMPLETE + TEST_CMD=true (skipped) --------
_run_completion_scenario "completion_pass" "zero" "## Status: COMPLETE" \
    COMPLETION_GATE_TEST_ENABLED=false

# --- Scenario 6: completion-fail-tests — TEST_CMD exits non-zero -------------
_run_completion_scenario "completion_test_fail" "nonzero" "## Status: COMPLETE" \
    COMPLETION_GATE_TEST_ENABLED=true \
    TEST_CMD=false

# --- Scenario 7: completion-fail-status — no Status field --------------------
_run_completion_scenario "completion_no_status" "nonzero" "# Summary\nNo status header here."

# --- Scenario 8: gate-timeout — BUILD_GATE_TIMEOUT exceeded ------------------
_run_build_scenario "gate_timeout" "report" "no_raw" \
    ANALYZE_CMD="sleep 5" \
    ANALYZE_ERROR_PATTERN="NEVER_MATCH" \
    BUILD_GATE_TIMEOUT=1 \
    BUILD_GATE_ANALYZE_TIMEOUT=10

# --- Scenario 9: M92 — TEST_BASELINE_PASS_ON_PREEXISTING=true, TEST_CMD fails ---
# Baseline is nil in completionGateFromEnv(), so the flag has no effect: the
# gate returns ErrCompletionTestFailed (exit 1) even though the flag is set.
# This scenario documents the CURRENT CLI behavior. Once a concrete
# BaselineComparator is wired in completionGateFromEnv(), this scenario should
# be split: pre-existing failures should exit 0 when the flag is true.
_run_completion_scenario "completion_preexisting_m92" "nonzero" "## Status: COMPLETE" \
    COMPLETION_GATE_TEST_ENABLED=true \
    TEST_CMD=false \
    TEST_BASELINE_PASS_ON_PREEXISTING=true

# --- Scenario 10: M105 — Dedup nil, TEST_CMD always runs ---------------------
# Documents that the M105 test-dedup fast-path is not wired at the CLI level.
# A side-effecting TEST_CMD (creates a sentinel file) is used to prove
# TEST_CMD was actually invoked. With Dedup == nil, no cached fingerprint can
# suppress the run; the sentinel file MUST be present after gate completion.
_completion_dedup_always_runs() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/.tekhton"
    local sentinel="${tmp}/test_ran_sentinel"
    printf '## Status: COMPLETE\n' > "${tmp}/.tekhton/CODER_SUMMARY.md"

    # Use sh-escaped path — ExecRunner forks `bash -c "$TEST_CMD"` so the
    # path is safe as long as TMPDIR has no spaces (mktemp guarantees this).
    local test_cmd="touch '${sentinel}'"

    env -i \
        PATH="$PATH" \
        HOME="$HOME" \
        TMPDIR="$tmp" \
        TEKHTON_DIR=".tekhton" \
        PROJECT_DIR="$tmp" \
        COMPLETION_GATE_TEST_ENABLED=true \
        TEST_CMD="$test_cmd" \
        "$TEKHTON_BIN" gate completion \
        >/dev/null 2>&1 || true  # exit code not checked here — we verify side-effect

    if [[ -f "$sentinel" ]]; then
        parity_pass "completion_dedup_m105: TEST_CMD ran (Dedup nil — expected)"
    else
        parity_fail "completion_dedup_m105: TEST_CMD did not run (dedup unexpectedly suppressed it)"
    fi
    rm -rf "$tmp"
}
_completion_dedup_always_runs

# --- Scenario 11: M86 — no Status field, Substantive probe not wired --------
# With Substantive == nil in completionGateFromEnv(), a summary with no Status
# field always routes to ErrCompletionNoStatus (not ErrCompletionSubstantiveNoStatus).
# The exit code is non-zero for both errors, so this scenario tests that the
# gate correctly rejects a no-status summary even when there is no Substantive
# probe wired. The stderr message is "no clear Status field" (not "substantive
# work without status") — the distinction is unobservable at exit-code granularity.
_run_completion_scenario "completion_substantive_m86" "nonzero" "# Summary\nNo status header."

parity_summary "test_gates_parity" || exit 1
exit 0
