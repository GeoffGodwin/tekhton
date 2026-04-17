#!/usr/bin/env bash
# =============================================================================
# test_preflight_fix.sh — Tests for _try_preflight_fix() (Milestone 44)
#
# Tests:
# - Config defaults for PREFLIGHT_FIX_* are set correctly
# - _try_preflight_fix() returns 0 when fix succeeds
# - _try_preflight_fix() returns 1 when attempts exhausted
# - Shell runs TEST_CMD independently after each fix attempt
# - PREFLIGHT_FIX_ENABLED=false skips the fix loop entirely
# - Regression detection aborts early when new failures introduced
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals ---------------------------------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/logs"
LOG_FILE="$TMPDIR/test.log"
TASK="Test preflight fix"
CLAUDE_JR_CODER_MODEL="claude-sonnet-4-6"
JR_CODER_MAX_TURNS=40
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
CODER_ROLE_FILE=".claude/agents/coder.md"
PROJECT_NAME="test-project"
AGENT_TOOLS_BUILD_FIX="Read Write Edit Glob Grep"

export PROJECT_DIR LOG_DIR LOG_FILE TASK
export CLAUDE_JR_CODER_MODEL JR_CODER_MAX_TURNS JR_CODER_ROLE_FILE
export CODER_ROLE_FILE PROJECT_NAME AGENT_TOOLS_BUILD_FIX

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
cd "$TMPDIR"
git init -q .
git add -A >/dev/null 2>&1
git commit -q -m "init" --allow-empty 2>/dev/null

# --- Source dependencies ------------------------------------------------------
source "${TEKHTON_HOME}/lib/common.sh"

# --- Mock run_agent -----------------------------------------------------------
declare -g _MOCK_RUN_AGENT_CALLS=0
declare -g _MOCK_FIX_ON_ATTEMPT=-1  # -1 = never fix, N = fix on attempt N

run_agent() {
    _MOCK_RUN_AGENT_CALLS=$(( _MOCK_RUN_AGENT_CALLS + 1 ))
    # If configured to fix on this attempt, create the fix script
    if [[ "$_MOCK_FIX_ON_ATTEMPT" -eq "$_MOCK_RUN_AGENT_CALLS" ]]; then
        cat > "$TMPDIR/test_cmd.sh" <<'EOFTEST'
#!/usr/bin/env bash
echo "All tests passed"
exit 0
EOFTEST
        chmod +x "$TMPDIR/test_cmd.sh"
    fi
    return 0
}

# --- Mock render_prompt -------------------------------------------------------
render_prompt() {
    echo "# Mock preflight fix prompt for $1"
}

# Source the file under test
source "${TEKHTON_HOME}/lib/orchestrate_helpers.sh"
source "${TEKHTON_HOME}/lib/orchestrate_preflight.sh"

# --- Test helpers -------------------------------------------------------------
PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

# =============================================================================
# Test Suite 1: Config defaults
# =============================================================================
echo "=== Test Suite 1: Config defaults ==="

# Source config_defaults.sh with required mock
_clamp_config_value() { :; }
_clamp_config_float() { :; }
source "${TEKHTON_HOME}/lib/config_defaults.sh"

if [[ "${PREFLIGHT_FIX_ENABLED}" = "true" ]]; then
    pass "1.1 PREFLIGHT_FIX_ENABLED defaults to true"
else
    fail "1.1 PREFLIGHT_FIX_ENABLED defaults to true (got: ${PREFLIGHT_FIX_ENABLED})"
fi

if [[ "${PREFLIGHT_FIX_MAX_ATTEMPTS}" = "2" ]]; then
    pass "1.2 PREFLIGHT_FIX_MAX_ATTEMPTS defaults to 2"
else
    fail "1.2 PREFLIGHT_FIX_MAX_ATTEMPTS defaults to 2 (got: ${PREFLIGHT_FIX_MAX_ATTEMPTS})"
fi

if [[ -n "${PREFLIGHT_FIX_MODEL}" ]]; then
    pass "1.3 PREFLIGHT_FIX_MODEL is set"
else
    fail "1.3 PREFLIGHT_FIX_MODEL is set (got empty)"
fi

if [[ -n "${PREFLIGHT_FIX_MAX_TURNS}" ]]; then
    pass "1.4 PREFLIGHT_FIX_MAX_TURNS is set"
else
    fail "1.4 PREFLIGHT_FIX_MAX_TURNS is set (got empty)"
fi

# =============================================================================
# Test Suite 2: Fix succeeds on first attempt
# =============================================================================
echo "=== Test Suite 2: Fix succeeds on first attempt ==="

_MOCK_RUN_AGENT_CALLS=0
_MOCK_FIX_ON_ATTEMPT=1
PREFLIGHT_FIX_ENABLED=true
PREFLIGHT_FIX_MAX_ATTEMPTS=2

# Create a test command that initially fails
cat > "$TMPDIR/test_cmd.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: test_something"
exit 1
EOF
chmod +x "$TMPDIR/test_cmd.sh"
TEST_CMD="bash $TMPDIR/test_cmd.sh"
export TEST_CMD

local_result=0
_try_preflight_fix "FAIL: test_something" "1" || local_result=$?

if [[ "$local_result" -eq 0 ]]; then
    pass "2.1 returns 0 when fix succeeds"
else
    fail "2.1 returns 0 when fix succeeds (got exit $local_result)"
fi

if [[ "$_MOCK_RUN_AGENT_CALLS" -eq 1 ]]; then
    pass "2.2 called run_agent exactly once"
else
    fail "2.2 called run_agent exactly once (got $_MOCK_RUN_AGENT_CALLS)"
fi

# =============================================================================
# Test Suite 3: Fix exhausts all attempts
# =============================================================================
echo "=== Test Suite 3: Fix exhausts all attempts ==="

_MOCK_RUN_AGENT_CALLS=0
_MOCK_FIX_ON_ATTEMPT=-1  # never fix
PREFLIGHT_FIX_MAX_ATTEMPTS=2

# Create a test command that always fails
cat > "$TMPDIR/test_cmd.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: test_something"
exit 1
EOF
chmod +x "$TMPDIR/test_cmd.sh"

local_result=0
_try_preflight_fix "FAIL: test_something" "1" || local_result=$?

if [[ "$local_result" -eq 1 ]]; then
    pass "3.1 returns 1 when attempts exhausted"
else
    fail "3.1 returns 1 when attempts exhausted (got exit $local_result)"
fi

if [[ "$_MOCK_RUN_AGENT_CALLS" -eq 2 ]]; then
    pass "3.2 called run_agent exactly twice (max attempts)"
else
    fail "3.2 called run_agent exactly twice (got $_MOCK_RUN_AGENT_CALLS)"
fi

# =============================================================================
# Test Suite 4: PREFLIGHT_FIX_ENABLED=false skips fix loop
# =============================================================================
echo "=== Test Suite 4: Disabled skips fix loop ==="

_MOCK_RUN_AGENT_CALLS=0
PREFLIGHT_FIX_ENABLED=false

local_result=0
_try_preflight_fix "FAIL: test_something" "1" || local_result=$?

if [[ "$local_result" -eq 1 ]]; then
    pass "4.1 returns 1 when disabled"
else
    fail "4.1 returns 1 when disabled (got exit $local_result)"
fi

if [[ "$_MOCK_RUN_AGENT_CALLS" -eq 0 ]]; then
    pass "4.2 run_agent not called when disabled"
else
    fail "4.2 run_agent not called when disabled (got $_MOCK_RUN_AGENT_CALLS)"
fi

PREFLIGHT_FIX_ENABLED=true  # restore

# =============================================================================
# Test Suite 5: Fix succeeds on second attempt
# =============================================================================
echo "=== Test Suite 5: Fix succeeds on second attempt ==="

_MOCK_RUN_AGENT_CALLS=0
_MOCK_FIX_ON_ATTEMPT=2
PREFLIGHT_FIX_MAX_ATTEMPTS=2

cat > "$TMPDIR/test_cmd.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: test_something"
exit 1
EOF
chmod +x "$TMPDIR/test_cmd.sh"

local_result=0
_try_preflight_fix "FAIL: test_something" "1" || local_result=$?

if [[ "$local_result" -eq 0 ]]; then
    pass "5.1 returns 0 when fix succeeds on attempt 2"
else
    fail "5.1 returns 0 when fix succeeds on attempt 2 (got exit $local_result)"
fi

if [[ "$_MOCK_RUN_AGENT_CALLS" -eq 2 ]]; then
    pass "5.2 called run_agent exactly twice"
else
    fail "5.2 called run_agent exactly twice (got $_MOCK_RUN_AGENT_CALLS)"
fi

# =============================================================================
# Test Suite 6: Shell runs TEST_CMD independently (agent tools restricted)
# =============================================================================
echo "=== Test Suite 6: Shell-verified testing ==="

# Verify that _try_preflight_fix uses AGENT_TOOLS_BUILD_FIX (no Bash test execution)
# This is a structural check — the function passes AGENT_TOOLS_BUILD_FIX to run_agent
_MOCK_RUN_AGENT_CALLS=0
_MOCK_FIX_ON_ATTEMPT=1
PREFLIGHT_FIX_MAX_ATTEMPTS=1

# Override run_agent to capture the tools argument
_captured_tools=""
run_agent() {
    _MOCK_RUN_AGENT_CALLS=$(( _MOCK_RUN_AGENT_CALLS + 1 ))
    _captured_tools="${6:-}"
    # Fix on configured attempt
    if [[ "$_MOCK_FIX_ON_ATTEMPT" -eq "$_MOCK_RUN_AGENT_CALLS" ]]; then
        cat > "$TMPDIR/test_cmd.sh" <<'EOFTEST'
#!/usr/bin/env bash
echo "All tests passed"
exit 0
EOFTEST
        chmod +x "$TMPDIR/test_cmd.sh"
    fi
    return 0
}

cat > "$TMPDIR/test_cmd.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: test_something"
exit 1
EOF
chmod +x "$TMPDIR/test_cmd.sh"

_try_preflight_fix "FAIL: test_something" "1" || true

if [[ "$_captured_tools" = "$AGENT_TOOLS_BUILD_FIX" ]]; then
    pass "6.1 agent invoked with AGENT_TOOLS_BUILD_FIX (restricted tools)"
else
    fail "6.1 agent invoked with AGENT_TOOLS_BUILD_FIX — got '${_captured_tools}'"
fi

# =============================================================================
# Test Suite 7: Regression detection aborts early
# =============================================================================
echo "=== Test Suite 7: Regression detection ==="

# Restore standard mock
run_agent() {
    _MOCK_RUN_AGENT_CALLS=$(( _MOCK_RUN_AGENT_CALLS + 1 ))
    return 0
}

_MOCK_RUN_AGENT_CALLS=0
_MOCK_FIX_ON_ATTEMPT=-1
PREFLIGHT_FIX_MAX_ATTEMPTS=3

# Create a test command that produces MORE failures each time
cat > "$TMPDIR/test_cmd.sh" <<'BASH'
#!/usr/bin/env bash
echo "FAIL: test_one"
echo "FAIL: test_two"
echo "FAIL: test_three"
echo "FAIL: test_four"
echo "FAIL: test_five"
echo "FAIL: test_six"
echo "FAIL: test_seven"
echo "FAIL: test_eight"
exit 1
BASH
chmod +x "$TMPDIR/test_cmd.sh"

# Initial output has only 1 failure
local_result=0
_try_preflight_fix "FAIL: test_one" "1" || local_result=$?

if [[ "$local_result" -eq 1 ]]; then
    pass "7.1 returns 1 on regression detection"
else
    fail "7.1 returns 1 on regression detection (got exit $local_result)"
fi

# Should abort after first attempt due to regression (8 failures vs 1 initial)
if [[ "$_MOCK_RUN_AGENT_CALLS" -eq 1 ]]; then
    pass "7.2 aborted after 1 attempt (regression detected, not all 3)"
else
    fail "7.2 aborted after 1 attempt — got $_MOCK_RUN_AGENT_CALLS calls"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  preflight fix tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] || exit 1
echo "All preflight fix tests passed"
