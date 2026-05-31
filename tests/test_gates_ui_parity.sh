#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tests/test_gates_ui_parity.sh — m31.2 UI gate parity (five scenarios)
#
# Drives `tekhton gate ui` against captured baselines under
# tests/testdata/gates/ui_*. Asserts:
#   - exit code matches the bash-equivalent gate's behavior,
#   - UI_TEST_ERRORS.md (after timestamp normalisation) is byte-identical
#     to the captured baseline,
#   - BUILD_ERRORS.md (after timestamp normalisation) is byte-identical
#     to the captured baseline,
#   - BUILD_RAW_ERRORS.txt is byte-identical to the captured baseline.
#
# Five scenarios cover the M126 branches:
#   ui_clean              — UI_TEST_CMD exits 0 (no error files)
#   ui_assertion_fail     — UI_TEST_CMD exits 1 with assertion-failure output
#   ui_interactive_report — UI_TEST_CMD exits 124 with HTML-report marker
#                           → hardened rerun attempted, diagnosis emitted
#   ui_generic_timeout    — UI_TEST_CMD exits 124 without marker
#                           → no hardened rerun, generic_timeout diagnosis
#   ui_framework_detect   — `tekhton gate ui --print-framework` priority order
# =============================================================================

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Always bind to this repo's binary — a stale TEKHTON_BIN env var in the
# caller's shell would point at an older checkout that lacks m31.2.
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

# shellcheck source=tests/lib/parity.sh
source "${REPO_ROOT}/tests/lib/parity.sh"

if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_gates_ui_parity: go toolchain not found\n'
    exit 0
fi
if ! [[ -x "$TEKHTON_BIN" ]]; then
    if ! (cd "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_gates_ui_parity: make build failed\n'
        exit 0
    fi
fi

# Normalisation: replace timestamps in the markdown headers so byte-equality
# comparisons survive across runs.
# shellcheck disable=SC2317
_ui_normalise() {
    local f="$1"
    sed -i -E \
        -e 's/# UI Test Errors — [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/# UI Test Errors — TIMESTAMP/' \
        -e 's/# Build Errors — [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/# Build Errors — TIMESTAMP/' \
        "$f"
}

# _run_ui_scenario NAME EXPECT_EXIT UI_TEST_CMD EXTRA_ENV...
#   EXPECT_EXIT: "zero" | "nonzero"
#   EXTRA_ENV: space-separated KEY=VALUE pairs appended after the env -i list.
_run_ui_scenario() {
    local name="$1" expect_exit="$2" ui_cmd="$3"
    shift 3
    local fixture_dir="${REPO_ROOT}/tests/testdata/gates/${name}"
    local expected_ui="${fixture_dir}/expected/UI_TEST_ERRORS.md"
    local expected_be="${fixture_dir}/expected/BUILD_ERRORS.md"
    local expected_raw="${fixture_dir}/expected/BUILD_RAW_ERRORS.txt"

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
        UI_VALIDATION_ENABLED=true \
        UI_TEST_CMD="$ui_cmd" \
        UI_TEST_TIMEOUT=60 \
        UI_FRAMEWORK=playwright \
        "$@" \
        "$TEKHTON_BIN" gate ui --stage-label "post-coder" \
        >/dev/null 2>&1 || result_exit=$?

    case "$expect_exit" in
        zero)
            if [[ "$result_exit" -eq 0 ]]; then
                parity_pass "${name}: exit 0 (gate accepted)"
            else
                parity_fail "${name}: exit ${result_exit}, want 0"
            fi
            ;;
        nonzero)
            if [[ "$result_exit" -ne 0 ]]; then
                parity_pass "${name}: exit ${result_exit} (gate rejected)"
            else
                parity_fail "${name}: exit 0, want non-zero"
            fi
            ;;
    esac

    local actual_ui="${tmp}/.tekhton/UI_TEST_ERRORS.md"
    local actual_be="${tmp}/.tekhton/BUILD_ERRORS.md"
    local actual_raw="${tmp}/.tekhton/BUILD_RAW_ERRORS.txt"

    if [[ -f "$expected_ui" ]]; then
        parity_assert_equal "${name}/ui_test_errors" "$expected_ui" "$actual_ui" _ui_normalise
    else
        parity_assert_no_file "${name}/ui_test_errors" "$actual_ui"
    fi
    if [[ -f "$expected_be" ]]; then
        parity_assert_equal "${name}/build_errors" "$expected_be" "$actual_be" _ui_normalise
    else
        parity_assert_no_file "${name}/build_errors" "$actual_be"
    fi
    if [[ -f "$expected_raw" ]]; then
        parity_assert_equal "${name}/build_raw_errors" "$expected_raw" "$actual_raw"
    else
        parity_assert_no_file "${name}/build_raw_errors" "$actual_raw"
    fi

    rm -rf "$tmp"
}

# --- Scenario 1: ui_clean — UI_TEST_CMD exits 0 -------------------------------
_run_ui_scenario "ui_clean" "zero" "true"

# --- Scenario 2: ui_assertion_fail — UI_TEST_CMD exits 1 with assertion -------
# The bash gate retries once on generic failure (E2E flakiness); both runs
# fail here so the gate writes the failure-path artifacts.
_run_ui_scenario "ui_assertion_fail" "nonzero" \
    "printf 'AssertionError: button not found\\n' && exit 1"

# --- Scenario 3: ui_interactive_report — exit 124 + HTML report marker --------
# Simulating a hung Playwright report: the subprocess prints the marker
# and exits 124 itself (instead of relying on the timeout(1) utility).
# UI_GATE_ENV_RETRY_ENABLED=true (the default) → hardened rerun attempted.
_run_ui_scenario "ui_interactive_report" "nonzero" \
    "printf 'Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.\\n' && exit 124"

# --- Scenario 4: ui_generic_timeout — exit 124 without marker -----------------
# UI_GATE_ENV_RETRY_ENABLED=false so the hardened rerun does NOT fire and
# the diagnosis block reports `Hardened rerun attempted: no`.
_run_ui_scenario "ui_generic_timeout" "nonzero" \
    "printf 'Test timeout exceeded\\n' && exit 124" \
    UI_GATE_ENV_RETRY_ENABLED=false

# --- Scenario 5: ui_framework_detect — priority order via --print-framework ---
_framework_detect_scenario() {
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # intentional early expansion of $tmp
    trap "rm -rf '$tmp'" RETURN

    local got
    # P0: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 → playwright always.
    got=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" PROJECT_DIR="$tmp" \
        TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 \
        UI_FRAMEWORK=vitest UI_TEST_CMD="vitest run" \
        "$TEKHTON_BIN" gate ui --print-framework 2>&1 || true)
    if [[ "$got" == "playwright" ]]; then
        parity_pass "ui_framework_detect P0: FORCE_NONINTERACTIVE=1 → playwright"
    else
        parity_fail "ui_framework_detect P0: got '$got', want 'playwright'"
    fi

    # P1: UI_FRAMEWORK=playwright → playwright.
    got=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" PROJECT_DIR="$tmp" \
        UI_FRAMEWORK=playwright \
        "$TEKHTON_BIN" gate ui --print-framework 2>&1 || true)
    if [[ "$got" == "playwright" ]]; then
        parity_pass "ui_framework_detect P1: UI_FRAMEWORK=playwright → playwright"
    else
        parity_fail "ui_framework_detect P1: got '$got', want 'playwright'"
    fi

    # P2: UI_TEST_CMD word-boundary regex match.
    got=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" PROJECT_DIR="$tmp" \
        UI_TEST_CMD="npx playwright test" \
        "$TEKHTON_BIN" gate ui --print-framework 2>&1 || true)
    if [[ "$got" == "playwright" ]]; then
        parity_pass "ui_framework_detect P2: UI_TEST_CMD regex → playwright"
    else
        parity_fail "ui_framework_detect P2: got '$got', want 'playwright'"
    fi

    # P3: playwright.config.ts present in PROJECT_DIR.
    local config_tmp
    config_tmp=$(mktemp -d)
    touch "${config_tmp}/playwright.config.ts"
    got=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$config_tmp" PROJECT_DIR="$config_tmp" \
        "$TEKHTON_BIN" gate ui --print-framework 2>&1 || true)
    if [[ "$got" == "playwright" ]]; then
        parity_pass "ui_framework_detect P3: playwright.config.ts → playwright"
    else
        parity_fail "ui_framework_detect P3: got '$got', want 'playwright'"
    fi
    rm -rf "$config_tmp"

    # P4: no signals → none.
    got=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" PROJECT_DIR="$tmp" \
        "$TEKHTON_BIN" gate ui --print-framework 2>&1 || true)
    if [[ "$got" == "none" ]]; then
        parity_pass "ui_framework_detect P4: no signals → none"
    else
        parity_fail "ui_framework_detect P4: got '$got', want 'none'"
    fi
}
_framework_detect_scenario

parity_summary "test_gates_ui_parity" || exit 1
exit 0
