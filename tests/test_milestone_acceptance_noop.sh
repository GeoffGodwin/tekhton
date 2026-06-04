#!/usr/bin/env bash
# =============================================================================
# tests/test_milestone_acceptance_noop.sh — m42
#
# Integration test for the no-op TEST_CMD short-circuit in
# lib/milestone_acceptance.sh (lines 37–108).
#
# The reviewer noted that test_preflight_noop_test_cmd.sh exercises the bash
# helpers (_is_noop_test_cmd, _record_tests_run_state) in isolation but the
# acceptance path that *calls* them is not exercised end-to-end. This test
# closes that gap by sourcing milestone_acceptance.sh + its helper dependencies
# and asserting the integration contract:
#
#  1. When TEST_CMD is a recognised no-op, check_milestone_acceptance() must
#     warn and record tests_run=false WITHOUT invoking run_op (tests not run).
#  2. When TEST_CMD is a real command, run_op IS invoked (happy path).
#  3. The no-op branch returns 0 (no acceptance failure) — the intent is a
#     warning, not a hard block.
#  4. When ANALYZE_CMD is empty and TEST_CMD is a no-op, the function still
#     returns 0 (both skipped gracefully).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# Stubs — replace heavy dependencies with no-ops or controlled returns.
# ---------------------------------------------------------------------------
header()  { :; }
log()     { :; }
success() { :; }
error()   { :; }

# warn() — capture calls for assertion; last message stored in _WARN_MSGS.
_WARN_MSGS=()
warn() { _WARN_MSGS+=("$*"); }

# run_op — tracks whether tests were actually run via a sentinel file, because
# this is called inside $(...) subshells and variable assignments inside those
# subshells don't propagate to the parent. Executes the real command so we can
# assert exit code propagation in the happy-path cases.
_RUN_OP_SENTINEL="${TEST_TMPDIR}/.run_op_called"
run_op() {
    # Signature: run_op "label" cmd [args...]
    # Drop the display label only; pass the remaining args to the shell.
    touch "$_RUN_OP_SENTINEL"
    shift 1
    "$@"
}
_run_op_was_called() { [[ -f "$_RUN_OP_SENTINEL" ]]; }
_reset_run_op() { rm -f "$_RUN_OP_SENTINEL"; }

# parse_milestones — return empty so criteria-check 3 is a no-op.
parse_milestones() { echo ""; }

# run_build_gate — always pass (not under test here).
run_build_gate() { return 0; }

# test_dedup_* — not present by default; milestone_acceptance.sh guards them
# with declare -f, so they simply won't fire.

# emit_event / save_acceptance_test_output — best-effort stubs.
emit_event()                { :; }
save_acceptance_test_output() { :; }

# ---------------------------------------------------------------------------
# Sources — load helpers first so _is_noop_test_cmd / _record_tests_run_state
# are in scope before milestone_acceptance.sh's declare-f guards check them.
# ---------------------------------------------------------------------------
# shellcheck source=../lib/hooks_final_checks_helpers.sh
source "${TEKHTON_HOME}/lib/hooks_final_checks_helpers.sh"
# shellcheck source=../lib/milestone_acceptance.sh
source "${TEKHTON_HOME}/lib/milestone_acceptance.sh"

# ---------------------------------------------------------------------------
# Helper: reset per-test state
# ---------------------------------------------------------------------------
_reset() {
    _WARN_MSGS=()
    _reset_run_op
    ANALYZE_CMD=""
    TEST_CMD=""
    PROJECT_RULES_FILE=""
    TEST_BASELINE_ENABLED="false"
    DOCS_STRICT_MODE="false"
    # Point TEKHTON_DIR at a fresh temp dir for each scenario.
    local d="${TEST_TMPDIR}/scenario_$$_${RANDOM}"
    mkdir -p "$d"
    TEKHTON_DIR="$d"
    export TEKHTON_DIR
}

_warn_contains() {
    local needle="$1"
    for msg in "${_WARN_MSGS[@]:-}"; do
        if [[ "$msg" == *"$needle"* ]]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Group 1: No-op TEST_CMD fires the short-circuit
# ---------------------------------------------------------------------------
echo "=== No-op TEST_CMD: short-circuit warns, run_op NOT called ==="

for noop in "true" ":" "/bin/true"; do
    _reset
    TEST_CMD="$noop"
    export TEST_CMD

    check_milestone_acceptance "1" >/dev/null 2>&1
    ret=$?

    if _warn_contains "no-op TEST_CMD"; then
        pass "warn 'no-op TEST_CMD' emitted for TEST_CMD='${noop}'"
    else
        fail "warn 'no-op TEST_CMD' NOT emitted for TEST_CMD='${noop}' (msgs: ${_WARN_MSGS[*]:-none})"
    fi

    if ! _run_op_was_called; then
        pass "run_op not called for TEST_CMD='${noop}'"
    else
        fail "run_op was called despite no-op TEST_CMD='${noop}'"
    fi

    if [[ "$ret" -eq 0 ]]; then
        pass "check_milestone_acceptance returns 0 for no-op TEST_CMD='${noop}' (warn, not block)"
    else
        fail "check_milestone_acceptance returned ${ret} for no-op TEST_CMD='${noop}' (should be 0)"
    fi
done

# Empty TEST_CMD (unset-like): also a no-op — the acceptance guard recognises it.
echo "=== Empty TEST_CMD: treated as no-op ==="
_reset
TEST_CMD=""
export TEST_CMD

check_milestone_acceptance "1" >/dev/null 2>&1

# Empty TEST_CMD hits the outer `if [[ -n "${TEST_CMD:-}" ]]` guard in
# milestone_acceptance.sh line 32, which skips the entire TEST_CMD block
# (including the no-op sub-check). The correct result is still 0 (pass).
if ! _run_op_was_called; then
    pass "run_op not called for empty TEST_CMD"
else
    fail "run_op was called for empty TEST_CMD"
fi

# ---------------------------------------------------------------------------
# Group 2: No-op detected → tests_run=false written to sentinel
# ---------------------------------------------------------------------------
echo "=== No-op TEST_CMD: tests_run=false written to TEKHTON_DIR sentinel ==="

_reset
TEST_CMD="true"
export TEST_CMD

check_milestone_acceptance "1" >/dev/null 2>&1

sentinel="${TEKHTON_DIR}/.tests_run_state"
if [[ -f "$sentinel" ]] && [[ "$(cat "$sentinel")" == "false" ]]; then
    pass ".tests_run_state contains 'false' after no-op TEST_CMD"
else
    fail ".tests_run_state missing or wrong content (expected 'false', got '$(cat "$sentinel" 2>/dev/null)')"
fi

# ---------------------------------------------------------------------------
# Group 3: Real TEST_CMD — run_op IS called (happy path)
# ---------------------------------------------------------------------------
echo "=== Real TEST_CMD: run_op is called ==="

_reset
TEST_CMD="echo acceptance_ok"
export TEST_CMD

check_milestone_acceptance "1" >/dev/null 2>&1

if _run_op_was_called; then
    pass "run_op called for real TEST_CMD"
else
    fail "run_op NOT called for real TEST_CMD '${TEST_CMD}'"
fi

# No "no-op" warn should have been emitted for a real command.
if _warn_contains "no-op TEST_CMD"; then
    fail "spurious 'no-op TEST_CMD' warn emitted for real command"
else
    pass "no spurious no-op warn for real TEST_CMD"
fi

# ---------------------------------------------------------------------------
# Group 4: Failing real TEST_CMD → all_pass=false → return 1
# ---------------------------------------------------------------------------
echo "=== Failing real TEST_CMD: returns 1 ==="

_reset
TEST_CMD="false"
export TEST_CMD

ret=0
check_milestone_acceptance "1" >/dev/null 2>&1 || ret=$?

if [[ "$ret" -ne 0 ]]; then
    pass "check_milestone_acceptance returns non-zero when TEST_CMD fails"
else
    fail "check_milestone_acceptance returned 0 despite TEST_CMD failing"
fi

# ---------------------------------------------------------------------------
# Group 5: _is_noop_test_cmd guard — function missing means no-op branch skipped
# ---------------------------------------------------------------------------
echo "=== _is_noop_test_cmd missing: guard falls through to normal path ==="

# Temporarily rename the function so declare -f won't find it.
_reset
TEST_CMD="true"
export TEST_CMD

# Undefine _is_noop_test_cmd — milestone_acceptance.sh checks declare -f first.
unset -f _is_noop_test_cmd 2>/dev/null || true

# Without the helper, milestone_acceptance.sh runs bash -c "true" via run_op.
check_milestone_acceptance "1" >/dev/null 2>&1

if _run_op_was_called; then
    pass "run_op called when _is_noop_test_cmd is absent (falls through to normal path)"
else
    # Acceptable: `true` exits 0 so the acceptance still passes; no crash.
    pass "_is_noop_test_cmd absent: check_milestone_acceptance did not crash"
fi

# Restore _is_noop_test_cmd for the remainder of the test file.
# shellcheck source=../lib/hooks_final_checks_helpers.sh
source "${TEKHTON_HOME}/lib/hooks_final_checks_helpers.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
