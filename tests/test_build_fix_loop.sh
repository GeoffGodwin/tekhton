#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_build_fix_loop.sh — Build-fix continuation loop integration tests (M128)
#
# Covers test cases T3–T10 from m128-build-fix-continuation-adaptive-budget.md:
#   run_build_fix_loop — retry-to-pass, exhausted, no_progress,
#                        total turn cap, report writer, stats export contract,
#                        single-attempt compat
#
# Pure-function tests (T1, T2) live in test_build_fix_helpers.sh.
#
# All tests use shell stubs only — no real coder agent invocation, no network.
# The RETRY_STATE counter pattern is reused from tests/test_ui_build_gate.sh.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "${name}: expected '${expected}', got '${actual}'"
    fi
}

# --- Pipeline globals (minimal viable subset) -------------------------------

TMPDIR_TOP=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TOP"' EXIT

cd "$TMPDIR_TOP"
mkdir -p .tekhton .claude

export PROJECT_DIR="$TMPDIR_TOP"
export LOG_FILE="$TMPDIR_TOP/test.log"
export LOG_DIR="$TMPDIR_TOP/logs"
mkdir -p "$LOG_DIR"
export TIMESTAMP="20260426_000000"
export TASK="M128 build-fix loop test"
export PIPELINE_STATE_FILE="$TMPDIR_TOP/.claude/PIPELINE_STATE.md"
export TEKHTON_SESSION_DIR="$TMPDIR_TOP/.claude"

export CLAUDE_CODER_MODEL="claude-sonnet-4-6"
export CODER_MAX_TURNS=80
export EFFECTIVE_CODER_MAX_TURNS=80
export AGENT_TOOLS_BUILD_FIX="Read Write Edit Glob Grep Bash"

export BUILD_RAW_ERRORS_FILE="$TMPDIR_TOP/.tekhton/BUILD_RAW_ERRORS.txt"
export BUILD_ERRORS_FILE="$TMPDIR_TOP/.tekhton/BUILD_ERRORS.md"
export BUILD_ROUTING_DIAGNOSIS_FILE="$TMPDIR_TOP/.tekhton/BUILD_ROUTING_DIAGNOSIS.md"
export BUILD_FIX_REPORT_FILE="$TMPDIR_TOP/.tekhton/BUILD_FIX_REPORT.md"

# Disable any inherited TUI state — log() must reach stdout
unset _TUI_ACTIVE 2>/dev/null || true

# --- Source common.sh for log/warn/error/header helpers ---------------------

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"

# --- Stubs and shared fixtures (defined BEFORE sourcing coder_buildfix.sh) --

# shellcheck source=tests/build_fix_loop_fixtures.sh
source "${TEKHTON_HOME}/tests/build_fix_loop_fixtures.sh"

# --- Source the unit under test --------------------------------------------

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder_buildfix_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder_buildfix.sh"

# =============================================================================
# T3: retries_until_pass — fail attempt 1, pass attempt 2 → ATTEMPTS=2
# =============================================================================
echo "=== T3: retries_until_pass ==="
reset_state
GATE_MODE="retry_pass"
echo "initial errors" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
assert_eq "T3 OUTCOME=passed" "passed" "$(field OUTCOME "$record")"
assert_eq "T3 ATTEMPTS=2"     "2"      "$(field ATTEMPTS "$record")"

# =============================================================================
# T4: stops_at_max_attempts — perpetual fail with strictly decreasing counts
# =============================================================================
echo "=== T4: stops_at_max_attempts ==="
reset_state
GATE_MODE="decreasing"
ERR_LINES_PER_ATTEMPT=10
export BUILD_FIX_MAX_ATTEMPTS=3
echo "seed" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
assert_eq "T4 OUTCOME=exhausted"   "exhausted" "$(field OUTCOME "$record")"
assert_eq "T4 ATTEMPTS==MAX (3)"   "3"         "$(field ATTEMPTS "$record")"

# =============================================================================
# T5: early_stop_no_progress — identical errors and tail across attempts
# =============================================================================
echo "=== T5: early_stop_no_progress ==="
reset_state
GATE_MODE="identical"
export BUILD_FIX_MAX_ATTEMPTS=5
export BUILD_FIX_REQUIRE_PROGRESS=true
cat > "${BUILD_RAW_ERRORS_FILE}" <<EOF
error a
error b
error c
EOF
record=$(run_loop_capture)
assert_eq "T5 OUTCOME=no_progress" "no_progress" "$(field OUTCOME "$record")"
assert_eq "T5 ATTEMPTS==2 (early)"  "2"          "$(field ATTEMPTS "$record")"
assert_eq "T5 GATES==1"             "1"          "$(field GATES "$record")"

# =============================================================================
# T6: total_turn_cap_enforced — large MAX, low cap → loop exits early
# =============================================================================
echo "=== T6: total_turn_cap_enforced ==="
reset_state
GATE_MODE="decreasing"
ERR_LINES_PER_ATTEMPT=20
export EFFECTIVE_CODER_MAX_TURNS=80
export BUILD_FIX_MAX_ATTEMPTS=10
export BUILD_FIX_TOTAL_TURN_CAP=40   # base=80/3=26 → attempt 1 budget 26, used=26
                                     # attempt 2: cap-used=14 ≥ 8, budget=min(39, rem=14)=14
                                     # used=40, attempt 3: rem=0 → budget=0 → exit
echo "seed" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
assert_eq "T6 OUTCOME=exhausted"   "exhausted" "$(field OUTCOME "$record")"
# Budget cap enforces stop before MAX_ATTEMPTS=10. Expect ≤3 attempts.
attempts=$(field ATTEMPTS "$record")
if [[ "$attempts" -ge 1 && "$attempts" -le 3 ]]; then
    pass
else
    fail "T6 expected ATTEMPTS in [1,3], got '${attempts}'"
fi
used=$(field USED "$record")
if [[ "$used" -le 40 ]]; then
    pass
else
    fail "T6 USED=${used} exceeded TOTAL_TURN_CAP=40"
fi

# =============================================================================
# T7: report_written — BUILD_FIX_REPORT_FILE created with attempt sections
# =============================================================================
echo "=== T7: report_written ==="
reset_state
GATE_MODE="retry_pass"
echo "errors" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
if [[ -f "${BUILD_FIX_REPORT_FILE}" ]]; then pass; else fail "T7 report not written"; fi
for needle in "## Attempt 1" "Turn budget:" "Terminal class:" "Gate result:" \
              "Progress signal:" "M127 classification:"; do
    if grep -q "$needle" "${BUILD_FIX_REPORT_FILE}" 2>/dev/null; then
        pass
    else
        fail "T7 report missing field: ${needle}"
    fi
done

# =============================================================================
# T8: pipeline_state_notes_include_build_fix_summary
# =============================================================================
echo "=== T8: pipeline_state_notes ==="
reset_state
GATE_MODE="decreasing"
ERR_LINES_PER_ATTEMPT=10
export BUILD_FIX_MAX_ATTEMPTS=3
echo "seed" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
notes=$(field NOTES "$record")
if echo "$notes" | grep -q "BUILD_FIX_REPORT.md"; then
    pass
else
    fail "T8 state notes missing BUILD_FIX_REPORT pointer (got: ${notes})"
fi
if echo "$notes" | grep -qE "[0-9]+/[0-9]+ attempt"; then
    pass
else
    fail "T8 state notes missing attempt count (got: ${notes})"
fi

# =============================================================================
# T9: stats_exported_on_every_exit_path
# =============================================================================
echo "=== T9: stats_exported_on_every_exit_path ==="

# 9a — passed
reset_state
GATE_MODE="retry_pass"
echo "x" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
case "$(field OUTCOME "$record")" in
    passed) pass ;;
    *) fail "T9a OUTCOME=$(field OUTCOME "$record"), expected passed" ;;
esac

# 9b — exhausted
reset_state
GATE_MODE="decreasing"
export BUILD_FIX_MAX_ATTEMPTS=2
echo "x" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
case "$(field OUTCOME "$record")" in
    exhausted) pass ;;
    *) fail "T9b OUTCOME=$(field OUTCOME "$record"), expected exhausted" ;;
esac

# 9c — no_progress
reset_state
GATE_MODE="identical"
export BUILD_FIX_MAX_ATTEMPTS=5
echo "x" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
case "$(field OUTCOME "$record")" in
    no_progress) pass ;;
    *) fail "T9c OUTCOME=$(field OUTCOME "$record"), expected no_progress" ;;
esac

# 9d — not_run (BUILD_FIX_ENABLED=false)
reset_state
export BUILD_FIX_ENABLED=false
echo "x" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
case "$(field OUTCOME "$record")" in
    not_run) pass ;;
    *) fail "T9d OUTCOME=$(field OUTCOME "$record"), expected not_run" ;;
esac

# 9d-ext — BUILD_FIX_ENABLED=false must call write_pipeline_state(coder,
# build_failure) and exit 1 (analogous coverage to noncode_dominant arm in
# test_m127_buildfix_routing.sh — reviewer gap).
_t9d_capture="${TMPDIR_TOP}/t9d_wps_capture.txt"
_t9d_exit=0
(
    write_pipeline_state() { printf '%s\n' "$@" > "${_t9d_capture}"; }
    export BUILD_FIX_ENABLED=false
    run_build_fix_loop
) || _t9d_exit=$?
if [[ "$_t9d_exit" -eq 1 ]]; then pass; else
    fail "T9d-ext BUILD_FIX_ENABLED=false must exit 1; got ${_t9d_exit}"
fi
if [[ -f "$_t9d_capture" ]] && head -1 "$_t9d_capture" | grep -q "^coder$"; then
    pass
else
    fail "T9d-ext write_pipeline_state first arg must be 'coder'"
fi
if [[ -f "$_t9d_capture" ]] && grep -q "^build_failure$" "$_t9d_capture"; then
    pass
else
    fail "T9d-ext write_pipeline_state second arg must be 'build_failure'"
fi

# 9e — secondary cause set on terminal failure (exhausted path)
reset_state
GATE_MODE="decreasing"
export BUILD_FIX_MAX_ATTEMPTS=2
echo "x" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
assert_eq "T9e SEC_CAT=AGENT_SCOPE" "AGENT_SCOPE" "$(field SEC_CAT "$record")"
assert_eq "T9e SEC_SUB=max_turns"   "max_turns"   "$(field SEC_SUB "$record")"

# =============================================================================
# T10: single_attempt_compat_mode — MAX_ATTEMPTS=1 reproduces pre-M128 behavior
# =============================================================================
echo "=== T10: single_attempt_compat_mode ==="
reset_state
GATE_MODE="decreasing"
export BUILD_FIX_MAX_ATTEMPTS=1
echo "x" > "${BUILD_RAW_ERRORS_FILE}"
record=$(run_loop_capture)
assert_eq "T10 OUTCOME=exhausted (single attempt)" "exhausted" "$(field OUTCOME "$record")"
assert_eq "T10 ATTEMPTS==1"                        "1"         "$(field ATTEMPTS "$record")"

# =============================================================================
# Summary
# =============================================================================
echo
echo "--------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "M128 build-fix loop tests passed"
