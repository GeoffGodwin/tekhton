#!/usr/bin/env bash
# =============================================================================
# test_run_final_checks_test_fix.sh — FINAL_FIX_ENABLED retry loop verification
#
# Tests the run_final_checks() function's FINAL_FIX_ENABLED behavior:
# - Retry loop terminates on success (test passes after fix)
# - Retry loop terminates on exhausted attempts (test still fails)
# - Loop respects FINAL_FIX_MAX_ATTEMPTS config
# - FINAL_FIX_ENABLED=false skips the fix agent entirely
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Setup test environment ---
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/logs"
LOG_FILE="$TMPDIR/test.log"
TIMESTAMP="20260329_120000"
TASK="test task"
CODER_MAX_TURNS=50
CLAUDE_CODER_MODEL="claude-sonnet-4-6"
CLAUDE_JR_CODER_MODEL="claude-sonnet-4-6"
AGENT_TOOLS_BUILD_FIX=""

# Test variables
FINAL_FIX_ENABLED=true
FINAL_FIX_MAX_ATTEMPTS=2
FINAL_FIX_MAX_TURNS=$((CODER_MAX_TURNS / 3))

# Setup config for defaults
ANALYZE_CMD="true"
TEST_CMD="bash /tmp/test_cmd.sh"

export PROJECT_DIR LOG_DIR TIMESTAMP LOG_FILE TASK
export FINAL_FIX_ENABLED FINAL_FIX_MAX_ATTEMPTS FINAL_FIX_MAX_TURNS
export CODER_MAX_TURNS CLAUDE_CODER_MODEL CLAUDE_JR_CODER_MODEL
export ANALYZE_CMD TEST_CMD AGENT_TOOLS_BUILD_FIX

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
cd "$TMPDIR"

# --- Source dependencies ---
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/hooks.sh"
source "${TEKHTON_HOME}/lib/hooks_final_checks.sh"

# --- Mock render_prompt ---
render_prompt() {
    echo "# Mock test fix prompt"
}

# --- Mock print_run_summary ---
print_run_summary() {
    return 0
}

# --- Mock run_agent ---
# Tracks call count and can be configured to succeed/fail
declare -g _RUN_AGENT_CALL_COUNT=0
declare -g _RUN_AGENT_SUCCESS_ON_ATTEMPT=-1  # -1 = never succeeds, N = succeed on attempt N

run_agent() {
    _RUN_AGENT_CALL_COUNT=$(((_RUN_AGENT_CALL_COUNT + 1)))
    local attempt_name="$1"

    # If configured to succeed on this attempt, set the test to pass
    if [ "$_RUN_AGENT_SUCCESS_ON_ATTEMPT" -eq "$_RUN_AGENT_CALL_COUNT" ]; then
        cat > /tmp/test_cmd.sh <<'EOFTEST'
#!/usr/bin/env bash
exit 0
EOFTEST
        chmod +x /tmp/test_cmd.sh
    fi
    return 0
}

# --- Test 1: Test passes on first try (no fix needed) ---
test_no_fix_needed() {
    _RUN_AGENT_CALL_COUNT=0

    # Create a test command that passes
    cat > /tmp/test_cmd.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x /tmp/test_cmd.sh

    > "$LOG_FILE"

    local result=0
    run_final_checks "$LOG_FILE" || result=$?

    # Should succeed without calling fix agent
    if [ $result -ne 0 ]; then
        echo "FAIL: run_final_checks should return 0 when tests pass"
        return 1
    fi

    if [ $_RUN_AGENT_CALL_COUNT -gt 0 ]; then
        echo "FAIL: run_agent should not be called when tests pass (called $_RUN_AGENT_CALL_COUNT times)"
        return 1
    fi

    echo "PASS: test_no_fix_needed"
    return 0
}

# --- Test 2: Test fails, fix succeeds on first attempt ---
test_fix_succeeds_on_first_attempt() {
    _RUN_AGENT_CALL_COUNT=0
    _RUN_AGENT_SUCCESS_ON_ATTEMPT=1  # Succeed on 1st fix agent attempt

    # Create a test command that initially fails
    cat > /tmp/test_cmd.sh <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x /tmp/test_cmd.sh

    > "$LOG_FILE"
    FINAL_FIX_ENABLED=true
    FINAL_FIX_MAX_ATTEMPTS=2

    local result=0
    run_final_checks "$LOG_FILE" || result=$?

    # Should succeed after fix agent runs once
    if [ $result -ne 0 ]; then
        echo "FAIL: run_final_checks should return 0 after successful fix"
        return 1
    fi

    if [ $_RUN_AGENT_CALL_COUNT -ne 1 ]; then
        echo "FAIL: run_agent should be called exactly 1 time (called $_RUN_AGENT_CALL_COUNT times)"
        return 1
    fi

    echo "PASS: test_fix_succeeds_on_first_attempt"
    return 0
}

# --- Test 3: Test fails, fix exhausts max attempts ---
test_fix_exhausts_attempts() {
    _RUN_AGENT_CALL_COUNT=0
    _RUN_AGENT_SUCCESS_ON_ATTEMPT=-1  # Never succeed

    # Create a test command that always fails
    cat > /tmp/test_cmd.sh <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x /tmp/test_cmd.sh

    > "$LOG_FILE"
    FINAL_FIX_ENABLED=true
    FINAL_FIX_MAX_ATTEMPTS=2

    local result=0
    run_final_checks "$LOG_FILE" || result=$?

    # Should fail after max attempts exhausted
    if [ $result -eq 0 ]; then
        echo "FAIL: run_final_checks should return non-zero when fix exhausts attempts"
        return 1
    fi

    if [ $_RUN_AGENT_CALL_COUNT -ne 2 ]; then
        echo "FAIL: run_agent should be called exactly 2 times (max attempts), called $_RUN_AGENT_CALL_COUNT times"
        return 1
    fi

    echo "PASS: test_fix_exhausts_attempts"
    return 0
}

# --- Test 4: FINAL_FIX_ENABLED=false skips fix agent ---
test_fix_disabled() {
    _RUN_AGENT_CALL_COUNT=0
    _RUN_AGENT_SUCCESS_ON_ATTEMPT=-1

    # Create a test command that fails
    cat > /tmp/test_cmd.sh <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x /tmp/test_cmd.sh

    > "$LOG_FILE"
    FINAL_FIX_ENABLED=false

    local result=0
    run_final_checks "$LOG_FILE" || result=$?

    # Should fail without calling fix agent
    if [ $result -eq 0 ]; then
        echo "FAIL: run_final_checks should return non-zero when tests fail and fix disabled"
        return 1
    fi

    if [ $_RUN_AGENT_CALL_COUNT -gt 0 ]; then
        echo "FAIL: run_agent should not be called when FINAL_FIX_ENABLED=false (called $_RUN_AGENT_CALL_COUNT times)"
        return 1
    fi

    echo "PASS: test_fix_disabled"
    return 0
}

# --- Test 5: Fix succeeds on second attempt (tests loop condition) ---
test_fix_succeeds_on_second_attempt() {
    _RUN_AGENT_CALL_COUNT=0
    _RUN_AGENT_SUCCESS_ON_ATTEMPT=2  # Succeed on 2nd fix agent attempt

    # Create a test command that initially fails
    cat > /tmp/test_cmd.sh <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x /tmp/test_cmd.sh

    > "$LOG_FILE"
    FINAL_FIX_ENABLED=true
    FINAL_FIX_MAX_ATTEMPTS=2

    local result=0
    run_final_checks "$LOG_FILE" || result=$?

    # Should succeed after fix agent runs twice
    if [ $result -ne 0 ]; then
        echo "FAIL: run_final_checks should return 0 after successful fix on 2nd attempt"
        return 1
    fi

    if [ $_RUN_AGENT_CALL_COUNT -ne 2 ]; then
        echo "FAIL: run_agent should be called exactly 2 times (called $_RUN_AGENT_CALL_COUNT times)"
        return 1
    fi

    echo "PASS: test_fix_succeeds_on_second_attempt"
    return 0
}

# --- Run all tests ---
pass_count=0
fail_count=0

for test_func in test_no_fix_needed test_fix_succeeds_on_first_attempt test_fix_exhausts_attempts test_fix_disabled test_fix_succeeds_on_second_attempt; do
    if $test_func; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
done

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [ $fail_count -gt 0 ]; then
    exit 1
fi

exit 0
