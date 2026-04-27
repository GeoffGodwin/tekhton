#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_resilience_arc_loop.sh — M134 coverage gap: run_build_fix_loop invocation
#
# S3.1–S3.3 in test_resilience_arc_integration.sh verify that
# classify_routing_decision exports LAST_BUILD_CLASSIFICATION correctly but do
# not call run_build_fix_loop itself. This file adds four scenarios that stub
# _bf_invoke_build_fix and run_build_gate to exercise the loop's attempt
# accounting, cumulative turn cap, and progress-gate halt without spawning an
# agent process.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"

TMPDIR_TOP=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TOP"' EXIT
export TMPDIR_TOP

unset _TUI_ACTIVE 2>/dev/null || true

# Source minimal dependencies. error_patterns.sh brings in classify_routing_decision.
# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"

_arc_source() {
    local f="${TEKHTON_HOME}/$1"
    if [[ -f "$f" ]]; then
        # shellcheck disable=SC1090
        source "$f"
    else
        echo "  SKIP (not yet implemented): $1"
    fi
}

_arc_source "lib/prompts.sh"
_arc_source "lib/error_patterns.sh"
_arc_source "stages/coder_buildfix.sh"

# shellcheck source=tests/resilience_arc_fixtures.sh
source "${TEKHTON_HOME}/tests/resilience_arc_fixtures.sh"

# ---- test accounting ---------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then pass "$desc"
    else fail "$desc — expected '$expected', got '$actual'"; fi
}

# ---- pipeline globals --------------------------------------------------------
export CODER_MAX_TURNS=80
export EFFECTIVE_CODER_MAX_TURNS=80
export TASK="loop-test"
export HUMAN_MODE=false
export HUMAN_NOTES_TAG=""
export MILESTONE_MODE=false

# ---- permanent stubs ---------------------------------------------------------
# _bf_invoke_build_fix: skip actual agent call; redefined per scenario.
_bf_invoke_build_fix() { return 0; }
# run_build_gate: default fails; redefined per scenario.
run_build_gate() { return 1; }
# write_pipeline_state: no-op (avoids needing state.sh + PIPELINE_STATE_FILE).
write_pipeline_state() { return 0; }
# append_human_action: no-op (called on noncode_dominant path).
append_human_action() { return 0; }
# _build_resume_flag: returns a fixed flag string (avoids needing state.sh).
_build_resume_flag() { echo "--start-at coder"; }

# ---- scenario helpers --------------------------------------------------------

# _setup_loop_scenario — creates a fresh temp dir, writes TS error fixture,
# and exports all artifact paths as absolute paths so _bf_read_raw_errors and
# _append_build_fix_report do not depend on CWD.
_setup_loop_scenario() {
    local dir
    dir=$(mktemp -d "${TMPDIR_TOP}/loop.XXXXXX")
    mkdir -p "${dir}/.tekhton"
    cat > "${dir}/.tekhton/BUILD_RAW_ERRORS.txt" <<'EOF'
src/app/page.tsx(12,5): error TS2304: Cannot find name 'undefined'.
src/lib/db.ts(8,3): error TS2339: Property 'query' does not exist.
EOF
    export PROJECT_DIR="$dir"
    export BUILD_RAW_ERRORS_FILE="${dir}/.tekhton/BUILD_RAW_ERRORS.txt"
    export BUILD_ERRORS_FILE="${dir}/.tekhton/BUILD_ERRORS.md"
    export BUILD_FIX_REPORT_FILE="${dir}/.tekhton/BUILD_FIX_REPORT.md"
    export BUILD_ROUTING_DIAGNOSIS_FILE="${dir}/.tekhton/BUILD_ROUTING_DIAGNOSIS.md"
}

# _loop_capture_vars OUT_FILE — called from an EXIT trap inside a subshell so
# the loop's exported stats are written to a file before exit 1 terminates the
# subshell. Parent reads the file after the subshell exits.
_loop_capture_vars() {
    printf '_BF_CAP_OUTCOME=%s\n'  "${BUILD_FIX_OUTCOME:-}"  > "$1"
    printf '_BF_CAP_ATTEMPTS=%s\n' "${BUILD_FIX_ATTEMPTS:-0}" >> "$1"
}

# =============================================================================
# S3.4 — gate passes on attempt 1 → BUILD_FIX_OUTCOME=passed, ATTEMPTS=1
# =============================================================================
echo "=== S3.4: Loop succeeds on attempt 1 → BUILD_FIX_OUTCOME=passed ==="
if declare -f run_build_fix_loop &>/dev/null; then
    _arc_reset_orch_state
    _setup_loop_scenario
    export BUILD_FIX_MAX_ATTEMPTS=3
    export BUILD_FIX_REQUIRE_PROGRESS=false
    unset BUILD_FIX_TOTAL_TURN_CAP
    run_build_gate() { return 0; }
    run_build_fix_loop
    assert_eq "S3.4 OUTCOME=passed"  "passed" "${BUILD_FIX_OUTCOME:-}"
    assert_eq "S3.4 ATTEMPTS=1"      "1"      "${BUILD_FIX_ATTEMPTS:-}"
    if (( "${BUILD_FIX_TURN_BUDGET_USED:-0}" > 0 )); then
        pass "S3.4 TURN_BUDGET_USED > 0 (budget was applied)"
    else
        fail "S3.4 TURN_BUDGET_USED should be > 0, got ${BUILD_FIX_TURN_BUDGET_USED:-0}"
    fi
    unset BUILD_FIX_MAX_ATTEMPTS BUILD_FIX_REQUIRE_PROGRESS
else
    skip "S3.4 — run_build_fix_loop not yet implemented"
fi

# =============================================================================
# S3.5 — all attempts fail, loop exhausts → OUTCOME=exhausted, ATTEMPTS=max
# =============================================================================
echo "=== S3.5: Loop exhausts BUILD_FIX_MAX_ATTEMPTS=2 → OUTCOME=exhausted ==="
if declare -f run_build_fix_loop &>/dev/null; then
    _arc_reset_orch_state
    _setup_loop_scenario
    run_build_gate() { return 1; }
    export BUILD_FIX_MAX_ATTEMPTS=2
    export BUILD_FIX_REQUIRE_PROGRESS=false
    unset BUILD_FIX_TOTAL_TURN_CAP
    _cap=$(mktemp)
    _rc=0
    (
        _st="$_cap"
        trap '_loop_capture_vars "$_st"' EXIT
        run_build_fix_loop
    ) || _rc=$?
    _BF_CAP_OUTCOME=""; _BF_CAP_ATTEMPTS=0
    # shellcheck source=/dev/null
    source "$_cap"; rm -f "$_cap"
    assert_eq "S3.5 exit code=1"         "1"         "$_rc"
    assert_eq "S3.5 OUTCOME=exhausted"   "exhausted" "$_BF_CAP_OUTCOME"
    assert_eq "S3.5 ATTEMPTS=2"          "2"         "$_BF_CAP_ATTEMPTS"
    attempt_count=$(grep -c '^## Attempt' "${BUILD_FIX_REPORT_FILE}" 2>/dev/null || echo 0)
    assert_eq "S3.5 report has 2 attempt sections" "2" "$attempt_count"
    unset _rc _cap _BF_CAP_OUTCOME _BF_CAP_ATTEMPTS attempt_count
else
    skip "S3.5 — run_build_fix_loop not yet implemented"
fi

# =============================================================================
# S3.6 — unchanged errors at attempt 2 → OUTCOME=no_progress, halted early
# =============================================================================
echo "=== S3.6: No-progress gate halts loop at attempt 2 → OUTCOME=no_progress ==="
if declare -f run_build_fix_loop &>/dev/null; then
    _arc_reset_orch_state
    _setup_loop_scenario
    run_build_gate() { return 1; }
    export BUILD_FIX_MAX_ATTEMPTS=5
    export BUILD_FIX_REQUIRE_PROGRESS=true
    unset BUILD_FIX_TOTAL_TURN_CAP
    # _bf_invoke_build_fix is a no-op → BUILD_RAW_ERRORS_FILE never changes
    # → _build_fix_progress_signal sees identical count+tail at attempt 2 → "unchanged"
    _cap=$(mktemp)
    _rc=0
    (
        _st="$_cap"
        trap '_loop_capture_vars "$_st"' EXIT
        run_build_fix_loop
    ) || _rc=$?
    _BF_CAP_OUTCOME=""; _BF_CAP_ATTEMPTS=0
    # shellcheck source=/dev/null
    source "$_cap"; rm -f "$_cap"
    assert_eq "S3.6 exit code=1"          "1"           "$_rc"
    assert_eq "S3.6 OUTCOME=no_progress"  "no_progress" "$_BF_CAP_OUTCOME"
    assert_eq "S3.6 ATTEMPTS=2"           "2"           "$_BF_CAP_ATTEMPTS"
    attempt_count=$(grep -c '^## Attempt' "${BUILD_FIX_REPORT_FILE}" 2>/dev/null || echo 0)
    assert_eq "S3.6 report has 2 attempt sections (halted early)" "2" "$attempt_count"
    unset _rc _cap _BF_CAP_OUTCOME _BF_CAP_ATTEMPTS attempt_count
else
    skip "S3.6 — run_build_fix_loop not yet implemented"
fi

# =============================================================================
# S3.7 — cumulative turn cap < floor → loop halts before first attempt
# =============================================================================
echo "=== S3.7: Turn cap below 8-turn floor → loop exits with ATTEMPTS=0 ==="
if declare -f run_build_fix_loop &>/dev/null; then
    _arc_reset_orch_state
    _setup_loop_scenario
    run_build_gate() { return 1; }
    export BUILD_FIX_MAX_ATTEMPTS=3
    export BUILD_FIX_TOTAL_TURN_CAP=5
    unset BUILD_FIX_REQUIRE_PROGRESS
    # _compute_build_fix_budget sees remaining=5 < 8-turn floor → returns 0
    # Loop exits immediately with attempt decremented back to 0
    _cap=$(mktemp)
    _rc=0
    (
        _st="$_cap"
        trap '_loop_capture_vars "$_st"' EXIT
        run_build_fix_loop
    ) || _rc=$?
    _BF_CAP_OUTCOME=""; _BF_CAP_ATTEMPTS=99
    # shellcheck source=/dev/null
    source "$_cap"; rm -f "$_cap"
    assert_eq "S3.7 exit code=1"       "1"         "$_rc"
    assert_eq "S3.7 OUTCOME=exhausted" "exhausted" "$_BF_CAP_OUTCOME"
    assert_eq "S3.7 ATTEMPTS=0 (cap before first attempt)" "0" "$_BF_CAP_ATTEMPTS"
    unset BUILD_FIX_TOTAL_TURN_CAP _rc _cap _BF_CAP_OUTCOME _BF_CAP_ATTEMPTS
else
    skip "S3.7 — run_build_fix_loop not yet implemented"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  Resilience arc loop: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
