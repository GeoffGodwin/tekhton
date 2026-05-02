#!/usr/bin/env bash
# Test: validate_config Check 13 — resilience arc config sanity (M136)
# Verifies the six checks added by lib/validate_config_arc.sh.
# shellcheck disable=SC2034
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Hermetic temp project to keep validate_config's filesystem checks predictable.
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging/color helpers and the milestone DAG (matches test_validate_config.sh).
RED="" GREEN="" YELLOW="" CYAN="" BOLD="" NC=""
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
_is_utf8_terminal() { return 1; }

_DAG_LOADED=false
has_milestone_manifest() { return 1; }
load_manifest() { return 1; }
validate_manifest() { return 0; }

# shellcheck source=../lib/validate_config.sh
source "${TEKHTON_HOME}/lib/validate_config.sh"

# Baseline healthy config — every test below mutates one variable and resets it.
PROJECT_NAME="test-project"
PROJECT_DESCRIPTION="A real project description"
TEST_CMD="npm test"
ANALYZE_CMD="npx eslint ."
ARCHITECTURE_FILE=""
DESIGN_FILE=""
TEKHTON_CONFIG_VERSION="3.85"
PIPELINE_STATE_FILE="${TEST_TMPDIR}/.claude/PIPELINE_STATE.md"

mkdir -p "${TEST_TMPDIR}/.claude/agents"
for f in coder.md reviewer.md tester.md jr-coder.md; do
    echo "# Role" > "${TEST_TMPDIR}/.claude/agents/$f"
done
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"

CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CLAUDE_CODER_MODEL="claude-opus-4-6"
CLAUDE_JR_CODER_MODEL="claude-haiku-4-5"
CLAUDE_REVIEWER_MODEL="claude-sonnet-4-6"
CLAUDE_TESTER_MODEL="claude-haiku-4-5"
CLAUDE_SCOUT_MODEL="claude-haiku-4-5"

echo "=== Check A: BUILD_FIX_MAX_ATTEMPTS=abc → error ==="
BUILD_FIX_MAX_ATTEMPTS="abc"
rc=0
output=$(validate_config 2>&1) || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "Non-integer BUILD_FIX_MAX_ATTEMPTS returns exit code 1"
else
    fail "Non-integer BUILD_FIX_MAX_ATTEMPTS returned exit code $rc"
fi
if echo "$output" | grep -q "BUILD_FIX_MAX_ATTEMPTS=abc"; then
    pass "Non-integer BUILD_FIX_MAX_ATTEMPTS error present"
else
    fail "Expected BUILD_FIX_MAX_ATTEMPTS=abc error message"
fi
unset BUILD_FIX_MAX_ATTEMPTS

echo ""
echo "=== Check B: BUILD_FIX_BASE_TURN_DIVISOR=0 → error ==="
BUILD_FIX_BASE_TURN_DIVISOR="0"
rc=0
output=$(validate_config 2>&1) || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "Out-of-range BUILD_FIX_BASE_TURN_DIVISOR returns exit code 1"
else
    fail "Out-of-range BUILD_FIX_BASE_TURN_DIVISOR returned exit code $rc"
fi
if echo "$output" | grep -q "BUILD_FIX_BASE_TURN_DIVISOR=0"; then
    pass "Out-of-range BUILD_FIX_BASE_TURN_DIVISOR error present"
else
    fail "Expected BUILD_FIX_BASE_TURN_DIVISOR=0 error message"
fi
unset BUILD_FIX_BASE_TURN_DIVISOR

echo ""
echo "=== Check C: UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5 → warning ==="
UI_GATE_ENV_RETRY_TIMEOUT_FACTOR="2.5"
rc=0
output=$(validate_config 2>&1) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Out-of-range timeout factor is only a warning (exit 0)"
else
    fail "Out-of-range timeout factor caused error (exit $rc)"
fi
if echo "$output" | grep -q "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5"; then
    pass "Out-of-range timeout factor warning present"
else
    fail "Expected UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5 warning"
fi
unset UI_GATE_ENV_RETRY_TIMEOUT_FACTOR

echo ""
echo "=== Check D: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=yes → warning ==="
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE="yes"
rc=0
output=$(validate_config 2>&1) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Invalid FORCE_NONINTERACTIVE is only a warning (exit 0)"
else
    fail "Invalid FORCE_NONINTERACTIVE caused error (exit $rc)"
fi
if echo "$output" | grep -q "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=yes"; then
    pass "Invalid FORCE_NONINTERACTIVE warning present"
else
    fail "Expected TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=yes warning"
fi
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE

echo ""
echo "=== Check E: PREFLIGHT_BAK_RETAIN_COUNT=abc → error ==="
PREFLIGHT_BAK_RETAIN_COUNT="abc"
rc=0
output=$(validate_config 2>&1) || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "Non-integer PREFLIGHT_BAK_RETAIN_COUNT returns exit code 1"
else
    fail "Non-integer PREFLIGHT_BAK_RETAIN_COUNT returned exit code $rc"
fi
if echo "$output" | grep -q "PREFLIGHT_BAK_RETAIN_COUNT=abc"; then
    pass "Non-integer PREFLIGHT_BAK_RETAIN_COUNT error present"
else
    fail "Expected PREFLIGHT_BAK_RETAIN_COUNT=abc error message"
fi
unset PREFLIGHT_BAK_RETAIN_COUNT

echo ""
echo "=== Check F: UI_TEST_CMD set + retry disabled → warning ==="
UI_TEST_CMD="npx playwright test"
UI_GATE_ENV_RETRY_ENABLED="false"
rc=0
output=$(validate_config 2>&1) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Disabled retry with UI_TEST_CMD is only a warning (exit 0)"
else
    fail "Disabled retry with UI_TEST_CMD caused error (exit $rc)"
fi
if echo "$output" | grep -q "interactive reporter timeouts will not be auto-retried"; then
    pass "Disabled-retry warning message present"
else
    fail "Expected disabled-retry warning"
fi
unset UI_TEST_CMD UI_GATE_ENV_RETRY_ENABLED

echo ""
echo "=== All defaults → arc checks pass cleanly ==="
unset BUILD_FIX_MAX_ATTEMPTS BUILD_FIX_BASE_TURN_DIVISOR \
      UI_GATE_ENV_RETRY_TIMEOUT_FACTOR TEKHTON_UI_GATE_FORCE_NONINTERACTIVE \
      PREFLIGHT_BAK_RETAIN_COUNT UI_GATE_ENV_RETRY_ENABLED UI_TEST_CMD
DESIGN_FILE=""
rc=0
output=$(validate_config 2>&1) || rc=$?
if echo "$output" | grep -q "\[Resilience Arc\]"; then
    pass "Arc section header present in default-state output"
else
    fail "Expected [Resilience Arc] header in arc-default output"
fi
if [[ "$rc" -eq 0 ]]; then
    pass "Arc default checks produce no errors"
else
    fail "Arc default checks produced errors (exit $rc)"
fi

echo ""
echo "=== Arc defaults: all 7 new arc vars have correct values in config_defaults.sh ==="
if (
    _clamp_config_value() { :; }
    _clamp_config_float() { :; }
    unset UI_GATE_ENV_RETRY_ENABLED UI_GATE_ENV_RETRY_TIMEOUT_FACTOR \
          TEKHTON_UI_GATE_FORCE_NONINTERACTIVE BUILD_FIX_CLASSIFICATION_REQUIRED \
          PREFLIGHT_UI_CONFIG_AUDIT_ENABLED PREFLIGHT_UI_CONFIG_AUTO_FIX \
          PREFLIGHT_BAK_RETAIN_COUNT 2>/dev/null || true
    # shellcheck source=../lib/config_defaults.sh
    source "${TEKHTON_HOME}/lib/config_defaults.sh"
    [[ "${UI_GATE_ENV_RETRY_ENABLED:-}" == "true" ]] \
        || { echo "WRONG UI_GATE_ENV_RETRY_ENABLED=${UI_GATE_ENV_RETRY_ENABLED:-unset}"; exit 1; }
    [[ "${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR:-}" == "0.5" ]] \
        || { echo "WRONG UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR:-unset}"; exit 1; }
    [[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-}" == "0" ]] \
        || { echo "WRONG TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-unset}"; exit 1; }
    [[ "${BUILD_FIX_CLASSIFICATION_REQUIRED:-}" == "true" ]] \
        || { echo "WRONG BUILD_FIX_CLASSIFICATION_REQUIRED=${BUILD_FIX_CLASSIFICATION_REQUIRED:-unset}"; exit 1; }
    [[ "${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED:-}" == "true" ]] \
        || { echo "WRONG PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED:-unset}"; exit 1; }
    [[ "${PREFLIGHT_UI_CONFIG_AUTO_FIX:-}" == "true" ]] \
        || { echo "WRONG PREFLIGHT_UI_CONFIG_AUTO_FIX=${PREFLIGHT_UI_CONFIG_AUTO_FIX:-unset}"; exit 1; }
    [[ "${PREFLIGHT_BAK_RETAIN_COUNT:-}" == "5" ]] \
        || { echo "WRONG PREFLIGHT_BAK_RETAIN_COUNT=${PREFLIGHT_BAK_RETAIN_COUNT:-unset}"; exit 1; }
); then
    pass "All 7 new arc vars have correct defaults in config_defaults.sh"
else
    fail "One or more arc vars had wrong default (see output above)"
fi

echo ""
echo "=== Idempotent source: double-source does not change arc var values ==="
if (
    _clamp_config_value() { :; }
    _clamp_config_float() { :; }
    unset UI_GATE_ENV_RETRY_ENABLED UI_GATE_ENV_RETRY_TIMEOUT_FACTOR \
          TEKHTON_UI_GATE_FORCE_NONINTERACTIVE BUILD_FIX_CLASSIFICATION_REQUIRED \
          PREFLIGHT_UI_CONFIG_AUDIT_ENABLED PREFLIGHT_UI_CONFIG_AUTO_FIX \
          PREFLIGHT_BAK_RETAIN_COUNT 2>/dev/null || true
    # shellcheck source=../lib/config_defaults.sh
    source "${TEKHTON_HOME}/lib/config_defaults.sh"
    snap1="${UI_GATE_ENV_RETRY_ENABLED}|${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR}|${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}|${BUILD_FIX_CLASSIFICATION_REQUIRED}|${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED}|${PREFLIGHT_UI_CONFIG_AUTO_FIX}|${PREFLIGHT_BAK_RETAIN_COUNT}"
    source "${TEKHTON_HOME}/lib/config_defaults.sh"
    snap2="${UI_GATE_ENV_RETRY_ENABLED}|${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR}|${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}|${BUILD_FIX_CLASSIFICATION_REQUIRED}|${PREFLIGHT_UI_CONFIG_AUDIT_ENABLED}|${PREFLIGHT_UI_CONFIG_AUTO_FIX}|${PREFLIGHT_BAK_RETAIN_COUNT}"
    [[ "$snap1" == "$snap2" ]] || { echo "CHANGED: before=$snap1 after=$snap2"; exit 1; }
); then
    pass "Double-sourcing config_defaults.sh leaves arc var values unchanged"
else
    fail "Arc var values changed between first and second source"
fi

echo ""
echo "════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
exit "$FAIL"
