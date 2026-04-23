#!/usr/bin/env bash
# =============================================================================
# test_agent_retry_pause.sh — Spinner pause/resume bracket (M124)
#
# Verifies lib/agent_retry_pause.sh:
#   _retry_pause_spinner_around_quota —
#     - Reads spinner PID from named ref, passes to _pause_agent_spinner
#     - Clears named refs after pausing (so stray _stop_agent_spinner is no-op)
#     - On callback success: calls _resume_agent_spinner, rewrites named refs
#       with the new PID pair echoed by the resumed spinner
#     - On callback failure: _RETRY_QP_RC is non-zero, spinner NOT resumed
#     - Works without _pause_agent_spinner/_resume_agent_spinner loaded
#
#   _pause_agent_spinner —
#     - With empty PIDs: no error (no kill attempt)
#     - With a live subshell PID: kills it (process exits)
#
#   _enter_qp_rate / _enter_qp_proactive —
#     - Delegate to enter_quota_pause with the expected label format
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Silence logging noise from any transitively sourced file.
log()         { : ; }
warn()        { : ; }
error()       { : ; }
success()     { : ; }
header()      { : ; }
log_verbose() { : ; }

# Stub enter_quota_pause so _enter_qp_rate / _enter_qp_proactive callbacks
# can be tested without running the real quota loop.
_ENTER_QP_LABEL=""
enter_quota_pause() { _ENTER_QP_LABEL="${1:-}"; return 0; }

# Load the module under test.
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/agent_retry_pause.sh"

# Also load agent_spinner.sh to get _pause_agent_spinner / _resume_agent_spinner.
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/agent_spinner.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# =============================================================================
echo "=== _pause_agent_spinner: empty PIDs are a no-op ==="
# shellcheck disable=SC2218  # Function defined in sourced agent_spinner.sh (line above)
rc=0; _pause_agent_spinner "" "" || rc=$?
[[ "$rc" -eq 0 ]] && pass "_pause_agent_spinner empty PIDs: clean exit" \
    || fail "exit code" "got $rc"

# =============================================================================
echo "=== _pause_agent_spinner: kills a live subshell ==="
# Spawn a background process that sleeps, then verify it's gone after pause.
sleep 9999 &
_live_pid=$!
# Verify it started
kill -0 "$_live_pid" 2>/dev/null \
    && pass "background process started" \
    || fail "background process" "did not start"

# shellcheck disable=SC2218  # Defined in sourced agent_spinner.sh above
_pause_agent_spinner "$_live_pid" ""

# After pause the process should be gone.
# Give wait() a moment to reap it.
wait "$_live_pid" 2>/dev/null || true
kill -0 "$_live_pid" 2>/dev/null \
    && fail "_pause_agent_spinner" "process still alive after pause" \
    || pass "_pause_agent_spinner killed the subshell"

# =============================================================================
echo "=== _resume_agent_spinner: delegates to _start_agent_spinner ==="
# In test mode (TEKHTON_TEST_MODE or no /dev/tty), _start_agent_spinner
# outputs ':' (empty_spinner:empty_tui) — both PIDs are empty.
export TEKHTON_TEST_MODE=true
result=$(_resume_agent_spinner "TestLabel" "/dev/null" 50)
[[ "$result" == ":" ]] && pass "_resume_agent_spinner echoes ':' in test mode" \
    || fail "_resume_agent_spinner output" "got '$result'"
unset TEKHTON_TEST_MODE

# =============================================================================
echo "=== _retry_pause_spinner_around_quota: happy path ==="
# Stub the spinner functions as counters so we can verify call order.
_PAUSE_CALLS=0; _PAUSE_SP=""; _PAUSE_TP=""
_pause_agent_spinner() { _PAUSE_CALLS=$((_PAUSE_CALLS+1)); _PAUSE_SP="$1"; _PAUSE_TP="$2"; }

_resume_agent_spinner() { printf '77:88\n'; }

_cb_succeed() { return 0; }

_spinner_pid="111"
_tui_pid="222"

_RETRY_QP_RC=0
_retry_pause_spinner_around_quota \
    _cb_succeed "TestLabel" 50 "/dev/null" "_spinner_pid" "_tui_pid"

[[ "$_PAUSE_CALLS" -eq 1 ]] && pass "happy: _pause_agent_spinner called once" \
    || fail "_pause_agent_spinner calls" "expected 1, got $_PAUSE_CALLS"
[[ "$_PAUSE_SP" == "111" ]] && pass "happy: pause received correct spinner PID" \
    || fail "pause spinner PID" "expected '111', got '$_PAUSE_SP'"
[[ "$_PAUSE_TP" == "222" ]] && pass "happy: pause received correct tui PID" \
    || fail "pause tui PID" "expected '222', got '$_PAUSE_TP'"
[[ "$_RETRY_QP_RC" -eq 0 ]] && pass "happy: _RETRY_QP_RC=0 on success" \
    || fail "_RETRY_QP_RC" "expected 0, got $_RETRY_QP_RC"
# _resume_agent_spinner runs in a command-substitution subshell so a counter
# inside the stub won't propagate; instead verify via the nameref side-effects.
[[ "$_spinner_pid" == "77" ]] \
    && pass "happy: _spinner_pid nameref updated to new PID (proves resume ran)" \
    || fail "_spinner_pid nameref" "expected '77', got '$_spinner_pid'"
[[ "$_tui_pid" == "88" ]] \
    && pass "happy: _tui_pid nameref updated to new tui PID (proves resume ran)" \
    || fail "_tui_pid nameref" "expected '88', got '$_tui_pid'"

# =============================================================================
echo "=== _retry_pause_spinner_around_quota: callback failure path ==="
_PAUSE_CALLS=0
_spinner_pid="333"
_tui_pid="444"

_cb_fail() { return 1; }
_RETRY_QP_RC=0
_retry_pause_spinner_around_quota \
    _cb_fail "TestLabel" 50 "/dev/null" "_spinner_pid" "_tui_pid"

[[ "$_RETRY_QP_RC" -eq 1 ]] && pass "failure: _RETRY_QP_RC=1 on callback failure" \
    || fail "_RETRY_QP_RC" "expected 1, got $_RETRY_QP_RC"
# When callback fails, _spinner_pid and _tui_pid stay empty (not updated to
# new PIDs) — that proves _resume_agent_spinner was not called.
[[ -z "$_spinner_pid" ]] && pass "failure: _spinner_pid cleared after pause" \
    || fail "_spinner_pid" "expected empty, got '$_spinner_pid'"
[[ -z "$_tui_pid" ]] && pass "failure: _tui_pid cleared after pause" \
    || fail "_tui_pid" "expected empty, got '$_tui_pid'"

# =============================================================================
echo "=== _retry_pause_spinner_around_quota: absent spinner module ==="
# Undefine the spinner functions — the bracket must not error when the
# agent_spinner.sh module is not loaded (e.g. test harnesses that only
# source agent_retry_pause.sh on its own).
unset -f _pause_agent_spinner _resume_agent_spinner

_spinner_pid="555"
_tui_pid="666"
_RETRY_QP_RC=0
rc=0; _retry_pause_spinner_around_quota \
    _cb_succeed "TestLabel" 50 "/dev/null" "_spinner_pid" "_tui_pid" || rc=$?
[[ "$rc" -eq 0 ]] && pass "absent spinner module: clean exit" \
    || fail "exit code" "got $rc"
[[ "$_RETRY_QP_RC" -eq 0 ]] && pass "absent spinner module: callback still ran" \
    || fail "_RETRY_QP_RC" "expected 0, got $_RETRY_QP_RC"

# =============================================================================
echo "=== _enter_qp_rate: label format ==="
_ENTER_QP_LABEL=""
_enter_qp_rate "Coder"
[[ "$_ENTER_QP_LABEL" == "Rate limited (agent: Coder)" ]] \
    && pass "_enter_qp_rate label format" \
    || fail "_enter_qp_rate label" "got '$_ENTER_QP_LABEL'"

# =============================================================================
echo "=== _enter_qp_proactive: label format ==="
_ENTER_QP_LABEL=""
_enter_qp_proactive "Coder" 8
[[ "$_ENTER_QP_LABEL" == "Paused at 8% remaining (reserve threshold)" ]] \
    && pass "_enter_qp_proactive label format" \
    || fail "_enter_qp_proactive label" "got '$_ENTER_QP_LABEL'"

# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
