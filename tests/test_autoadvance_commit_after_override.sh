#!/usr/bin/env bash
# =============================================================================
# test_autoadvance_commit_after_override.sh — m46 acceptance test for the
# operator-override sentinel-clear path.
#
# The 2026-06-06 m37.2 false-positive replan dialog (root cause for m46's
# Goal 1) tripped `.tekhton/.final_check_result` to "1" upstream of the
# user-facing dialog. Operator chose [c] Continue, but the pre-m46
# dispatcher did NOT clear the sentinel — so every downstream iteration
# of the auto-advance chain read the stale value and silently skipped the
# commit via _hook_commit's FINAL_CHECK_RESULT branch.
#
# This test drives the override-then-next-iteration flow:
#   1. Plant `.tekhton/.final_check_result` with the value "1" and a
#      stale reason comment line.
#   2. Plant `.tekhton/.commit_decision` with "skipped" (simulating the
#      prior _hook_commit call's bookkeeping).
#   3. Source the replan dispatcher and invoke `handle_replan_choice c`.
#   4. Assert the sentinel files no longer exist on disk.
#   5. Drive a no-op `_hook_commit 0` invocation and assert the
#      FINAL_CHECK_RESULT skip path does NOT fire (the sentinel was
#      cleared, so the gate is open).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"
export TEKHTON_DIR=".tekhton"
export TEKHTON_SESSION_DIR="$TMPDIR"
export TEKHTON_TEST_MODE="true"
export TASK="m46 override test"
export MILESTONE_MODE=""
export LOG_DIR="${TMPDIR}/.claude/logs"
export PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
export REPLAN_MODEL="opus"
export REPLAN_MAX_TURNS="5"
export AUTO_COMMIT="false"   # _hook_commit's success branch skips the actual git invocation
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}" "${TMPDIR}/.tekhton"

# Stub all I/O functions; the dispatcher must not emit during tests.
# shellcheck disable=SC2317  # called indirectly via lib/replan*.sh
log()         { :; }
# shellcheck disable=SC2317
log_verbose() { :; }
# shellcheck disable=SC2317
success()     { :; }
# shellcheck disable=SC2317
warn()        { :; }
# shellcheck disable=SC2317
error()       { :; }
# shellcheck disable=SC2317
header()      { :; }
# shellcheck disable=SC2317
_safe_read_file() { cat "$1" 2>/dev/null || true; }
# shellcheck disable=SC2317
write_pipeline_state() { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true

# Re-stub after common.sh source so its real implementations don't bleed in.
# shellcheck disable=SC2317
log()         { :; }
# shellcheck disable=SC2317
log_verbose() { :; }
# shellcheck disable=SC2317
success()     { :; }
# shellcheck disable=SC2317
warn()        { :; }
# shellcheck disable=SC2317
error()       { :; }
# shellcheck disable=SC2317
header()      { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/state.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/replan.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

_plant_sentinels() {
    # Two-line `.final_check_result` matching trip_commit_gate's writer
    # shape (line 1 = exit code, line 2 = `# <reason>`).
    printf '1\n# completion_gate_failed_substantive_work_only\n' \
        > "${TMPDIR}/.tekhton/.final_check_result"
    # A separate `.final_check_reason` file (future/legacy split — best-effort rm).
    printf 'completion_gate_failed_substantive_work_only\n' \
        > "${TMPDIR}/.tekhton/.final_check_reason"
    # `.commit_decision` written by _write_commit_decision on a prior skip.
    printf 'skipped\n' > "${TMPDIR}/.tekhton/.commit_decision"
}

# ============================================================
# Scenario A: handle_replan_choice c clears all three sentinels
# ============================================================
echo "=== A: handle_replan_choice c clears sentinels ==="

_plant_sentinels

# Confirm pre-conditions exist
[[ -f "${TMPDIR}/.tekhton/.final_check_result" ]] || fail "precondition: final_check_result must exist"
[[ -f "${TMPDIR}/.tekhton/.final_check_reason" ]] || fail "precondition: final_check_reason must exist"
[[ -f "${TMPDIR}/.tekhton/.commit_decision" ]]    || fail "precondition: commit_decision must exist"

if handle_replan_choice "c"; then
    pass "handle_replan_choice c returned 0"
else
    fail "handle_replan_choice c should return 0"
fi

if [[ ! -f "${TMPDIR}/.tekhton/.final_check_result" ]]; then
    pass ".final_check_result removed by override path"
else
    fail "REGRESSION: .final_check_result still present after [c] Continue"
fi
if [[ ! -f "${TMPDIR}/.tekhton/.final_check_reason" ]]; then
    pass ".final_check_reason removed by override path"
else
    fail ".final_check_reason still present after [c] Continue"
fi
if [[ ! -f "${TMPDIR}/.tekhton/.commit_decision" ]]; then
    pass ".commit_decision removed by override path"
else
    fail ".commit_decision still present after [c] Continue"
fi

# ============================================================
# Scenario B: handle_replan_choice C (uppercase) also clears
# ============================================================
echo "=== B: handle_replan_choice C (uppercase) clears sentinels ==="

_plant_sentinels
if handle_replan_choice "C"; then pass "uppercase C returned 0"; else fail "uppercase C should return 0"; fi
if [[ ! -f "${TMPDIR}/.tekhton/.final_check_result" ]]; then
    pass "uppercase C clears .final_check_result"
else
    fail "uppercase C should clear .final_check_result"
fi

# ============================================================
# Scenario C: handle_replan_choice with the `s|S` and `a|A` arms also clear
# the sentinels (Watch For: every non-replan branch).
# ============================================================
echo "=== C: handle_replan_choice s clears sentinels ==="

_plant_sentinels
# s returns 1 by design — we only assert on the side effect (clear).
handle_replan_choice "s" "test rationale" 2>/dev/null || true
if [[ ! -f "${TMPDIR}/.tekhton/.final_check_result" ]]; then
    pass "[s] Split clears .final_check_result"
else
    fail "[s] Split should clear .final_check_result"
fi

echo "=== D: handle_replan_choice a clears sentinels ==="

_plant_sentinels
handle_replan_choice "a" "test rationale" 2>/dev/null || true
if [[ ! -f "${TMPDIR}/.tekhton/.final_check_result" ]]; then
    pass "[a] Abort clears .final_check_result"
else
    fail "[a] Abort should clear .final_check_result"
fi

# ============================================================
# Scenario E: after sentinel-clear, _hook_commit (exit_code=0)
# does NOT take the FINAL_CHECK_RESULT skip branch.
# We exercise this by checking that _final_check_result_read returns 0
# when no sentinel exists (the predicate _hook_commit gates on).
# ============================================================
echo "=== E: _final_check_result_read returns 0 after sentinel clear ==="

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/finalize_commit_sentinel.sh"

# Plant + clear via dispatcher
_plant_sentinels
handle_replan_choice "c" 2>/dev/null

result=$(_final_check_result_read)
if [[ "$result" == "0" ]]; then
    pass "_final_check_result_read returns 0 after handle_replan_choice c"
else
    fail "_final_check_result_read returned '${result}' instead of '0'"
fi

# ============================================================
# Scenario F: _clear_commit_skip_sentinels is idempotent — clearing
# when no sentinel exists must not fail.
# ============================================================
echo "=== F: idempotent clear (no sentinels present) ==="

rm -f "${TMPDIR}/.tekhton/.final_check_result" \
      "${TMPDIR}/.tekhton/.final_check_reason" \
      "${TMPDIR}/.tekhton/.commit_decision" 2>/dev/null

if _clear_commit_skip_sentinels; then
    pass "_clear_commit_skip_sentinels returns 0 when no sentinels exist"
else
    fail "_clear_commit_skip_sentinels should be idempotent (rc=0)"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
