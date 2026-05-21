#!/usr/bin/env bash
# =============================================================================
# tests/run_tests.sh — Self-test runner for Tekhton
#
# Run from the tekhton repo root:
#   bash tests/run_tests.sh
# =============================================================================

set -euo pipefail

export TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${TEKHTON_HOME}/tests"

# --- Env contract hygiene ----------------------------------------------------
# When tekhton itself runs `bash tests/run_tests.sh` as TEST_CMD, the M26 env
# contract has already exported the parent project's pipeline.conf values
# (CODER_MAX_TURNS, MILESTONE_DIR, MILESTONE_DAG_ENABLED, …) into our env.
# Tests build their own fixtures and call `load_config` against them — but
# `internal/config.seedFromEnv` adopts any pre-existing env value over the
# derived defaults, so e.g. TESTER_FIX_MAX_TURNS (= CODER_MAX_TURNS/3) freezes
# at the parent's value instead of the fixture's. Tests like
# test_auto_fix_on_test_failure.sh / test_milestones.sh / test_milestone_*.sh
# fail under that pollution but pass from a clean shell.
#
# The fix: unset every contract key before any test runs. Derive the list
# from `tekhton config defaults --emit shell` so it never goes stale — adding
# a new default key in internal/config/defaults.go automatically extends the
# wipe. PROJECT_DIR / MILESTONE_DIR / MILESTONE_MANIFEST are wiped explicitly
# because they're absolute-path-resolved and not in the defaults list.
_tekhton_bin="${TEKHTON_HOME}/bin/tekhton"
if [[ -x "$_tekhton_bin" ]]; then
    while IFS= read -r _key; do
        [[ -z "$_key" ]] && continue
        unset "$_key" 2>/dev/null || true
    done < <(
        "$_tekhton_bin" config defaults --emit shell 2>/dev/null \
            | sed -nE 's/^export ([A-Z_][A-Z0-9_]*)=.*/\1/p'
    )
fi
unset PROJECT_DIR MILESTONE_DIR MILESTONE_MANIFEST \
      _CURRENT_MILESTONE TASK MILESTONE_MODE AUTO_ADVANCE AUTO_ADVANCE_LIMIT \
      HUMAN_MODE HUMAN_NOTES_TAG LOG_DIR LOG_FILE TIMESTAMP TEKHTON_SESSION_DIR \
      _DAG_LOADED 2>/dev/null || true

# Export _FILE config variables for test subprocesses — matching production
# defaults from config_defaults.sh (all under TEKHTON_DIR).
export TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"
export CODER_SUMMARY_FILE="${CODER_SUMMARY_FILE:-${TEKHTON_DIR}/CODER_SUMMARY.md}"
export REVIEWER_REPORT_FILE="${REVIEWER_REPORT_FILE:-${TEKHTON_DIR}/REVIEWER_REPORT.md}"
export TESTER_REPORT_FILE="${TESTER_REPORT_FILE:-${TEKHTON_DIR}/TESTER_REPORT.md}"
export JR_CODER_SUMMARY_FILE="${JR_CODER_SUMMARY_FILE:-${TEKHTON_DIR}/JR_CODER_SUMMARY.md}"
export BUILD_ERRORS_FILE="${BUILD_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_ERRORS.md}"
export BUILD_RAW_ERRORS_FILE="${BUILD_RAW_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_RAW_ERRORS.txt}"
export UI_TEST_ERRORS_FILE="${UI_TEST_ERRORS_FILE:-${TEKHTON_DIR}/UI_TEST_ERRORS.md}"
export PREFLIGHT_ERRORS_FILE="${PREFLIGHT_ERRORS_FILE:-${TEKHTON_DIR}/PREFLIGHT_ERRORS.md}"
export DIAGNOSIS_FILE="${DIAGNOSIS_FILE:-${TEKHTON_DIR}/DIAGNOSIS.md}"
export CLARIFICATIONS_FILE="${CLARIFICATIONS_FILE:-${TEKHTON_DIR}/CLARIFICATIONS.md}"
export HUMAN_NOTES_FILE="${HUMAN_NOTES_FILE:-${TEKHTON_DIR}/HUMAN_NOTES.md}"
export SPECIALIST_REPORT_FILE="${SPECIALIST_REPORT_FILE:-${TEKHTON_DIR}/SPECIALIST_REPORT.md}"
export UI_VALIDATION_REPORT_FILE="${UI_VALIDATION_REPORT_FILE:-${TEKHTON_DIR}/UI_VALIDATION_REPORT.md}"
export INTAKE_REPORT_FILE="${INTAKE_REPORT_FILE:-${TEKHTON_DIR}/INTAKE_REPORT.md}"
export TEST_AUDIT_REPORT_FILE="${TEST_AUDIT_REPORT_FILE:-${TEKHTON_DIR}/TEST_AUDIT_REPORT.md}"
export HEALTH_REPORT_FILE="${HEALTH_REPORT_FILE:-${TEKHTON_DIR}/HEALTH_REPORT.md}"
export SECURITY_NOTES_FILE="${SECURITY_NOTES_FILE:-${TEKHTON_DIR}/SECURITY_NOTES.md}"
export SECURITY_REPORT_FILE="${SECURITY_REPORT_FILE:-${TEKHTON_DIR}/SECURITY_REPORT.md}"
export DOCS_AGENT_REPORT_FILE="${DOCS_AGENT_REPORT_FILE:-${TEKHTON_DIR}/DOCS_AGENT_REPORT.md}"
export DESIGN_FILE="${DESIGN_FILE:-${TEKHTON_DIR}/DESIGN.md}"
export ARCHITECTURE_LOG_FILE="${ARCHITECTURE_LOG_FILE:-${TEKHTON_DIR}/ARCHITECTURE_LOG.md}"
export DRIFT_LOG_FILE="${DRIFT_LOG_FILE:-${TEKHTON_DIR}/DRIFT_LOG.md}"
export HUMAN_ACTION_FILE="${HUMAN_ACTION_FILE:-${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md}"
export NON_BLOCKING_LOG_FILE="${NON_BLOCKING_LOG_FILE:-${TEKHTON_DIR}/NON_BLOCKING_LOG.md}"
export TDD_PREFLIGHT_FILE="${TDD_PREFLIGHT_FILE:-${TEKHTON_DIR}/TESTER_PREFLIGHT.md}"
export SCOUT_REPORT_FILE="${SCOUT_REPORT_FILE:-${TEKHTON_DIR}/SCOUT_REPORT.md}"
export ARCHITECT_PLAN_FILE="${ARCHITECT_PLAN_FILE:-${TEKHTON_DIR}/ARCHITECT_PLAN.md}"
export CLEANUP_REPORT_FILE="${CLEANUP_REPORT_FILE:-${TEKHTON_DIR}/CLEANUP_REPORT.md}"
export DRIFT_ARCHIVE_FILE="${DRIFT_ARCHIVE_FILE:-${TEKHTON_DIR}/DRIFT_ARCHIVE.md}"
export PROJECT_INDEX_FILE="${PROJECT_INDEX_FILE:-${TEKHTON_DIR}/PROJECT_INDEX.md}"
export REPLAN_DELTA_FILE="${REPLAN_DELTA_FILE:-${TEKHTON_DIR}/REPLAN_DELTA.md}"
export MERGE_CONTEXT_FILE="${MERGE_CONTEXT_FILE:-${TEKHTON_DIR}/MERGE_CONTEXT.md}"
PASS=0
FAIL=0
FAILED_TESTS=()

# Per-test heartbeat — written outside the captured stdout pipe so a hang
# inside a single test is visible from another terminal:
#   tail -f /tmp/tekhton_test_progress.log
# The last `START <test>` line with no matching `END` identifies the culprit.
TEST_PROGRESS_LOG="${TEST_PROGRESS_LOG:-/tmp/tekhton_test_progress.log}"
: > "$TEST_PROGRESS_LOG" 2>/dev/null || true
_log_progress() {
    printf '[%s pid=%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" \
        >> "$TEST_PROGRESS_LOG" 2>/dev/null || true
}
_log_progress "run_tests.sh BEGIN (TEKHTON_HOME=${TEKHTON_HOME})"

# Per-test timeout — bounds each shell test individually so a single hung test
# can't lock up the suite (and by extension, the tekhton baseline-capture flow
# that runs this script as TEST_CMD). Default 60s; tests that legitimately need
# longer declare it with a `# TIMEOUT_SECS=N` magic comment at the top of the
# file. The whole-suite env knob TEKHTON_TEST_TIMEOUT_SECS overrides the default
# for slow-CI scenarios.
TEKHTON_TEST_TIMEOUT_SECS="${TEKHTON_TEST_TIMEOUT_SECS:-60}"

_resolve_test_timeout() {
    local file="$1"
    # Match a leading-comment directive within the first 20 lines. Anchored on
    # `# TIMEOUT_SECS=N` (allowing whitespace) so a literal mention inside a
    # test body doesn't accidentally extend the cap.
    local v
    v=$(head -20 "$file" 2>/dev/null \
        | grep -oE '^[[:space:]]*#[[:space:]]*TIMEOUT_SECS[[:space:]]*=[[:space:]]*[0-9]+' \
        | head -1 \
        | grep -oE '[0-9]+$' || true)
    if [[ -n "$v" ]]; then
        echo "$v"
    else
        echo "$TEKHTON_TEST_TIMEOUT_SECS"
    fi
}

# Disable commit signing for all test subprocesses — tests create temporary
# git repos that inherit the global signing config, causing failures in
# environments with broken or unavailable signing keys.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="commit.gpgsign"
export GIT_CONFIG_VALUE_0="false"

# Force TUI off — if a parent shell has `_TUI_ACTIVE=true` exported (e.g. a
# previous pipeline run that didn't clean up), `log()` silently redirects to
# LOG_FILE and tests that capture stdout get empty output.
export _TUI_ACTIVE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_test() {
    local test_name="$1"
    local test_file="${TESTS_DIR}/${test_name}"
    local output rc=0

    if [ ! -f "$test_file" ]; then
        echo -e "${RED}MISSING${NC} ${test_name}"
        FAIL=$((FAIL + 1))
        return
    fi

    # Single invocation — capture output and exit code together so the FAIL
    # branch reports the same run that produced the non-zero exit code.
    # Re-running the test for debug output can yield divergent results when
    # `set -euo pipefail` aborts the first run early (SIGPIPE inside `$()`,
    # bare grep with no match, etc.) but the second run starts clean.
    #
    # Wrapped in `timeout` so a single hung test can't stall the whole suite.
    # --kill-after=5s escalates to SIGKILL if the test ignores SIGTERM (e.g.
    # backgrounded subprocesses still holding the stdout pipe).
    local timeout_secs
    timeout_secs=$(_resolve_test_timeout "$test_file")
    _log_progress "START ${test_name} (timeout=${timeout_secs}s)"
    local _t0 _t1
    _t0=$(date +%s)
    output=$(timeout --kill-after=5s "${timeout_secs}s" \
        bash "$test_file" < /dev/null 2>&1) || rc=$?
    _t1=$(date +%s)
    _log_progress "END   ${test_name} rc=${rc} elapsed=$((_t1 - _t0))s"

    # timeout exits 124 (SIGTERM fired) or 137 (SIGKILL fired after grace
    # period). Surface either as a clear timeout failure so the log names the
    # culprit instead of a generic non-zero exit.
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo -e "${RED}FAIL${NC} ${test_name} — TIMED OUT after ${timeout_secs}s"
        FAILED_TESTS+=("$test_name (timeout ${timeout_secs}s)")
        echo "  --- partial output ---"
        printf '%s\n' "$output" | sed 's/^/  /'
        echo "  --- end ---"
        FAIL=$((FAIL + 1))
    elif [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}PASS${NC} ${test_name}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} ${test_name}"
        FAILED_TESTS+=("$test_name")
        echo "  --- output ---"
        printf '%s\n' "$output" | sed 's/^/  /'
        echo "  --- end ---"
        FAIL=$((FAIL + 1))
    fi
}

echo "════════════════════════════════════════"
echo "  Tekhton Self-Tests"
echo "════════════════════════════════════════"
echo

# m14: bash shims in lib/milestone_dag.sh defer to `tekhton dag …` for
# validate / migrate / pointer-rewrite. Build the binary up-front so the
# subprocess shell tests can find it on PATH. Skip silently when go isn't
# installed — those tests will warn and skip rather than fail.
_log_progress "PHASE make-build BEGIN"
if [ -f "${TEKHTON_HOME}/go.mod" ] && command -v go &>/dev/null; then
    if (cd "$TEKHTON_HOME" && make build >/dev/null 2>&1); then
        export PATH="${TEKHTON_HOME}/bin:${PATH}"
    fi
fi
_log_progress "PHASE make-build END"

# Discover and run all test files.
#
# TEST_FILES override (M28-arc / task #40): when set to a space-separated
# list of test filenames, run only those instead of the full suite. Used by
# lib/hooks_final_checks.sh's auto-fix loop to re-test only the failures
# from the previous run instead of re-executing all 478 tests. Names may be
# bare ("test_foo.sh") or absolute paths; basename is taken either way.
# When TEST_FILES is empty or unset, the default glob runs (no behavior
# change for normal callers).
_log_progress "PHASE shell-tests BEGIN"
if [[ -n "${TEST_FILES:-}" ]]; then
    _log_progress "TEST_FILES override active: ${TEST_FILES}"
    for raw in $TEST_FILES; do
        name=$(basename "$raw")
        if [ -f "${TESTS_DIR}/${name}" ]; then
            run_test "$name"
        else
            echo -e "${RED}MISSING${NC} ${name} (not found in ${TESTS_DIR})"
            FAIL=$((FAIL + 1))
        fi
    done
else
    for test_file in "${TESTS_DIR}"/test_*.sh; do
        [ -f "$test_file" ] || continue
        run_test "$(basename "$test_file")"
    done
fi
_log_progress "PHASE shell-tests END"

echo
echo "────────────────────────────────────────"
echo -e "  Shell:  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo "────────────────────────────────────────"

# --- Python tests (conditional) -----------------------------------------------
PYTHON_PASS=0
PYTHON_FAIL=0
PYTHON_TESTS_DIR="${TEKHTON_HOME}/tools/tests"

_log_progress "PHASE python-tests BEGIN"
if [ -d "$PYTHON_TESTS_DIR" ]; then
    if command -v python3 &>/dev/null && python3 -c "import pytest" &>/dev/null; then
        echo
        echo "════════════════════════════════════════"
        echo "  Python Tool Tests"
        echo "════════════════════════════════════════"
        echo

        if python3 -m pytest "$PYTHON_TESTS_DIR" --tb=short -q 2>&1; then
            echo -e "  ${GREEN}Python tests passed${NC}"
            PYTHON_PASS=1
        else
            echo -e "  ${RED}Python tests failed${NC}"
            PYTHON_FAIL=1
        fi
    elif command -v python3 &>/dev/null; then
        echo
        echo -e "  ${YELLOW}SKIP${NC} Python tests (pytest not installed)"
    else
        echo
        echo -e "  ${YELLOW}SKIP${NC} Python tests (python3 not found)"
    fi
else
    echo
    echo -e "  ${YELLOW}SKIP${NC} Python tests (tools/tests/ not found)"
fi
_log_progress "PHASE python-tests END"

# --- Go tests (conditional) ---------------------------------------------------
GO_PASS=0
GO_FAIL=0

_log_progress "PHASE go-tests BEGIN"
if [ -f "${TEKHTON_HOME}/go.mod" ]; then
    if command -v go &>/dev/null; then
        echo
        echo "════════════════════════════════════════"
        echo "  Go Package Tests"
        echo "════════════════════════════════════════"
        echo

        if (cd "$TEKHTON_HOME" && go test ./... 2>&1); then
            echo -e "  ${GREEN}Go tests passed${NC}"
            GO_PASS=1
        else
            echo -e "  ${RED}Go tests failed${NC}"
            GO_FAIL=1
        fi
    else
        echo
        echo -e "  ${YELLOW}SKIP${NC} Go tests (go not on PATH — required by go.mod)"
    fi
fi

echo
echo "════════════════════════════════════════"
echo "  Final Summary"
echo "════════════════════════════════════════"
echo -e "  Shell:  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
if [ "${#FAILED_TESTS[@]}" -gt 0 ]; then
    echo "  Failed shell tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}-${NC} ${t}"
    done
fi
if [ "$PYTHON_PASS" -gt 0 ] || [ "$PYTHON_FAIL" -gt 0 ]; then
    if [ "$PYTHON_FAIL" -gt 0 ]; then
        echo -e "  Python: ${RED}FAILED${NC}"
    else
        echo -e "  Python: ${GREEN}PASSED${NC}"
    fi
fi
if [ "$GO_PASS" -gt 0 ] || [ "$GO_FAIL" -gt 0 ]; then
    if [ "$GO_FAIL" -gt 0 ]; then
        echo -e "  Go:     ${RED}FAILED${NC}"
    else
        echo -e "  Go:     ${GREEN}PASSED${NC}"
    fi
fi

_log_progress "PHASE go-tests END"
_log_progress "run_tests.sh DONE shell_pass=${PASS} shell_fail=${FAIL} python_fail=${PYTHON_FAIL} go_fail=${GO_FAIL}"

if [ "$FAIL" -gt 0 ] || [ "$PYTHON_FAIL" -gt 0 ] || [ "$GO_FAIL" -gt 0 ]; then
    exit 1
fi
