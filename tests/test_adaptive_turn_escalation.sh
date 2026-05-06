#!/usr/bin/env bash
# =============================================================================
# test_adaptive_turn_escalation.sh — Milestone 91
#
# Tests the adaptive rework turn escalation helpers in
# lib/orchestrate_aux.sh:
#   - _update_escalation_counter increments on AGENT_SCOPE/max_turns
#   - Counter resets to 0 on success / non-max_turns failure
#   - Counter resets to 1 when the failing stage changes
#   - _escalate_turn_budget multiplies and clamps to cap
#   - _apply_turn_escalation exports EFFECTIVE_* vars
#   - REWORK_TURN_ESCALATION_ENABLED=false disables the entire feature
#   - _can_escalate_further returns 0 below cap, 1 at/above cap
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

LOG_DIR="${TMPDIR}/logs"
mkdir -p "$LOG_DIR"

# Config that drives the helpers
CODER_MAX_TURNS=50
JR_CODER_MAX_TURNS=20
TESTER_MAX_TURNS=40
CODER_MAX_TURNS_CAP=200
REWORK_TURN_ESCALATION_ENABLED=true
REWORK_TURN_ESCALATION_FACTOR=1.5
REWORK_TURN_MAX_CAP=200
export CODER_MAX_TURNS JR_CODER_MAX_TURNS TESTER_MAX_TURNS CODER_MAX_TURNS_CAP
export REWORK_TURN_ESCALATION_ENABLED REWORK_TURN_ESCALATION_FACTOR REWORK_TURN_MAX_CAP

# Orchestrator globals that the helpers expect
_ORCH_CONSECUTIVE_MAX_TURNS=0
_ORCH_MAX_TURNS_STAGE=""

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/orchestrate_aux.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

_reset_state() {
    _ORCH_CONSECUTIVE_MAX_TURNS=0
    _ORCH_MAX_TURNS_STAGE=""
    unset EFFECTIVE_CODER_MAX_TURNS EFFECTIVE_JR_CODER_MAX_TURNS EFFECTIVE_TESTER_MAX_TURNS
    REWORK_TURN_ESCALATION_ENABLED=true
    REWORK_TURN_ESCALATION_FACTOR=1.5
    REWORK_TURN_MAX_CAP=200
}

# =============================================================================
# 1. Counter increments on AGENT_SCOPE/max_turns for same stage
# =============================================================================
_reset_state
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
assert_eq "1.1 first max_turns sets counter to 1" "1" "$_ORCH_CONSECUTIVE_MAX_TURNS"
assert_eq "1.2 stage recorded as coder" "coder" "$_ORCH_MAX_TURNS_STAGE"

_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
assert_eq "1.3 second max_turns on same stage increments to 2" "2" "$_ORCH_CONSECUTIVE_MAX_TURNS"

_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
assert_eq "1.4 third max_turns on same stage increments to 3" "3" "$_ORCH_CONSECUTIVE_MAX_TURNS"

# =============================================================================
# 2. Counter resets to 0 on success (empty category)
# =============================================================================
_reset_state
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
assert_eq "2.1 counter at 2 before success" "2" "$_ORCH_CONSECUTIVE_MAX_TURNS"

_update_escalation_counter "coder" "" "" || true
assert_eq "2.2 counter resets on success" "0" "$_ORCH_CONSECUTIVE_MAX_TURNS"
assert_eq "2.3 stage cleared on reset" "" "$_ORCH_MAX_TURNS_STAGE"

# =============================================================================
# 3. Counter resets to 1 when failing stage changes
# =============================================================================
_reset_state
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
assert_eq "3.1 counter at 2 for coder" "2" "$_ORCH_CONSECUTIVE_MAX_TURNS"

_update_escalation_counter "tester" "AGENT_SCOPE" "max_turns" || true
assert_eq "3.2 stage change resets counter to 1" "1" "$_ORCH_CONSECUTIVE_MAX_TURNS"
assert_eq "3.3 stage switched to tester" "tester" "$_ORCH_MAX_TURNS_STAGE"

# =============================================================================
# 4. Non-max_turns failure resets counter
# =============================================================================
_reset_state
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
_update_escalation_counter "coder" "UPSTREAM" "api_error" || true
assert_eq "4.1 non-max_turns failure resets counter" "0" "$_ORCH_CONSECUTIVE_MAX_TURNS"

_reset_state
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
_update_escalation_counter "coder" "AGENT_SCOPE" "null_run" || true
assert_eq "4.2 null_run resets counter (not max_turns)" "0" "$_ORCH_CONSECUTIVE_MAX_TURNS"

# =============================================================================
# 5. _escalate_turn_budget math + cap clamping
# =============================================================================
_reset_state
# base=50, factor=1.5, count=1 → 50 * (1 + 1.5*1) = 50 * 2.5 = 125
assert_eq "5.1 factor=1.5 count=1" "125" "$(_escalate_turn_budget 50 1.5 1 200)"
# base=50, factor=1.5, count=2 → 50 * 4 = 200
assert_eq "5.2 factor=1.5 count=2 at cap" "200" "$(_escalate_turn_budget 50 1.5 2 200)"
# base=50, factor=1.5, count=3 → 50 * 5.5 = 275 → clamped to 200
assert_eq "5.3 factor=1.5 count=3 clamped" "200" "$(_escalate_turn_budget 50 1.5 3 200)"
# Small base with large factor — ensure no underflow
assert_eq "5.4 small base count=1" "15" "$(_escalate_turn_budget 10 0.5 1 100)"

# =============================================================================
# 6. _apply_turn_escalation exports EFFECTIVE_* vars
# =============================================================================
_reset_state
_ORCH_MAX_TURNS_STAGE="coder"
_apply_turn_escalation 1 2>/dev/null

assert_eq "6.1 EFFECTIVE_CODER_MAX_TURNS set" "125" "${EFFECTIVE_CODER_MAX_TURNS:-}"
# JR: 20 * 2.5 = 50
assert_eq "6.2 EFFECTIVE_JR_CODER_MAX_TURNS set" "50" "${EFFECTIVE_JR_CODER_MAX_TURNS:-}"
# Tester: 40 * 2.5 = 100
assert_eq "6.3 EFFECTIVE_TESTER_MAX_TURNS set" "100" "${EFFECTIVE_TESTER_MAX_TURNS:-}"

# After escalation, _can_escalate_further should still be true (125 < 200)
if _can_escalate_further; then
    echo "ok: 6.4 _can_escalate_further true below cap"
else
    echo "FAIL: 6.4 _can_escalate_further should be true below cap"
    FAIL=1
fi

# Escalate far enough to hit cap
_apply_turn_escalation 3 2>/dev/null
assert_eq "6.5 escalated to cap" "200" "${EFFECTIVE_CODER_MAX_TURNS:-}"

# _can_escalate_further returns 1 at cap
if _can_escalate_further; then
    echo "FAIL: 6.6 _can_escalate_further should be false at cap"
    FAIL=1
else
    echo "ok: 6.6 _can_escalate_further false at cap"
fi

# =============================================================================
# 7. REWORK_TURN_ESCALATION_ENABLED=false disables feature
# =============================================================================
_reset_state
REWORK_TURN_ESCALATION_ENABLED=false

_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
assert_eq "7.1 counter stays 0 when disabled" "0" "$_ORCH_CONSECUTIVE_MAX_TURNS"

# EFFECTIVE_* should remain unset
if [[ -n "${EFFECTIVE_CODER_MAX_TURNS:-}" ]]; then
    echo "FAIL: 7.2 EFFECTIVE_CODER_MAX_TURNS set when disabled"
    FAIL=1
else
    echo "ok: 7.2 EFFECTIVE_CODER_MAX_TURNS unset when disabled"
fi

# _can_escalate_further returns 1 when disabled
if _can_escalate_further; then
    echo "FAIL: 7.3 _can_escalate_further true when disabled"
    FAIL=1
else
    echo "ok: 7.3 _can_escalate_further false when disabled"
fi

# =============================================================================
# 8. Escalation is stage-scoped (max_turns on different stage doesn't compound
#    the first stage's counter)
# =============================================================================
_reset_state
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
_update_escalation_counter "tester" "AGENT_SCOPE" "max_turns" || true
assert_eq "8.1 tester max_turns resets count to 1" "1" "$_ORCH_CONSECUTIVE_MAX_TURNS"
_update_escalation_counter "coder" "AGENT_SCOPE" "max_turns" || true
assert_eq "8.2 coder max_turns after tester resets to 1" "1" "$_ORCH_CONSECUTIVE_MAX_TURNS"

# =============================================================================
echo
if [ "$FAIL" -ne 0 ]; then
    echo "test_adaptive_turn_escalation: FAILED"
    exit 1
fi
echo "test_adaptive_turn_escalation: PASSED"
