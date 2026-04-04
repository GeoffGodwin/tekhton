#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_prompt_tempfile.sh — Regression: prompts use temp files, not CLI args
#
# Verifies the fix for MAX_ARG_STRLEN (128KB) on Linux. All three call sites
# that invoke `claude` must write the prompt to a temp file and feed it via
# stdin instead of passing it as a positional argument.
#
# What we test:
#   1. _call_planning_batch writes prompt to temp file, passes via stdin
#   2. _invoke_and_monitor (FIFO path) writes prompt to temp file
#   3. _invoke_and_monitor (fallback path) writes prompt to temp file
#   4. Temp files are cleaned up after use
#   5. Abort traps include temp file cleanup
#
# Approach: source the files and inspect the code patterns. We cannot invoke
# the actual `claude` CLI in tests, but we CAN verify the code structure by
# grepping for the fixed patterns and asserting the old vulnerable pattern is
# gone. We also create a mock `claude` to exercise the temp-file path.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Test 1: Code pattern — no call sites pass prompt as `-p "$prompt"`
# =============================================================================
echo "=== Test 1: No call sites use -p \"\$prompt\" pattern ==="

# The old vulnerable pattern: -p "$prompt" (prompt as positional arg to -p)
# After the fix, all sites should use: -p \ (newline) < "$_prompt_file"
# Check agent_monitor.sh
# shellcheck disable=SC2016
if grep -n '\-p "\$prompt"' "${TEKHTON_HOME}/lib/agent_monitor.sh" >/dev/null 2>&1; then
    fail "agent_monitor.sh still has -p \"\$prompt\" pattern"
else
    pass "agent_monitor.sh: no -p \"\$prompt\" pattern"
fi

# Check plan.sh
# shellcheck disable=SC2016
if grep -n '\-p "\$prompt"' "${TEKHTON_HOME}/lib/plan.sh" >/dev/null 2>&1; then
    fail "plan.sh still has -p \"\$prompt\" pattern"
else
    pass "plan.sh: no -p \"\$prompt\" pattern"
fi

# =============================================================================
# Test 2: Code pattern — all sites write prompt to temp file
# =============================================================================
echo "=== Test 2: All call sites write prompt to temp file ==="

# shellcheck disable=SC2016
if grep -q 'printf.*%s.*\$prompt.*>.*\$_prompt_file' "${TEKHTON_HOME}/lib/agent_monitor.sh"; then
    pass "agent_monitor.sh writes prompt to temp file"
else
    fail "agent_monitor.sh missing prompt-to-temp-file write"
fi

# shellcheck disable=SC2016
if grep -q 'printf.*%s.*\$prompt.*>.*\$_prompt_file' "${TEKHTON_HOME}/lib/plan.sh"; then
    pass "plan.sh writes prompt to temp file"
else
    fail "plan.sh missing prompt-to-temp-file write"
fi

# =============================================================================
# Test 3: Code pattern — all sites redirect temp file as stdin
# =============================================================================
echo "=== Test 3: All call sites use stdin redirect from temp file ==="

# shellcheck disable=SC2016
if grep -q '< "\$_prompt_file"' "${TEKHTON_HOME}/lib/agent_monitor.sh"; then
    pass "agent_monitor.sh redirects temp file as stdin"
else
    fail "agent_monitor.sh missing stdin redirect from temp file"
fi

# shellcheck disable=SC2016
if grep -q '< "\$_prompt_file"' "${TEKHTON_HOME}/lib/plan.sh"; then
    pass "plan.sh redirects temp file as stdin"
else
    fail "plan.sh missing stdin redirect from temp file"
fi

# =============================================================================
# Test 4: Code pattern — abort traps clean up temp file
# =============================================================================
echo "=== Test 4: Abort traps include temp file cleanup ==="

# FIFO path abort trap should rm _prompt_file
# shellcheck disable=SC2016
if grep -q 'rm -f.*\$_prompt_file' "${TEKHTON_HOME}/lib/agent_monitor.sh"; then
    pass "agent_monitor.sh abort trap cleans up prompt file"
else
    fail "agent_monitor.sh abort trap missing prompt file cleanup"
fi

# plan.sh cleans up after the call (no abort trap needed — simple pipeline)
if grep -q 'rm -f "\$_prompt_file"' "${TEKHTON_HOME}/lib/plan.sh"; then
    pass "plan.sh cleans up prompt file after call"
else
    fail "plan.sh missing prompt file cleanup"
fi

# =============================================================================
# Test 5: Functional — mock claude exercises temp-file path with large prompt
# =============================================================================
echo "=== Test 5: Functional — large prompt via temp file (mock claude) ==="

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a mock claude that reads stdin and verifies it got the prompt
cat > "${TMPDIR_TEST}/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
# Mock claude: read stdin, write it to a verification file, output JSON result
input=$(cat)
echo "$input" > "${TEKHTON_VERIFY_DIR}/received_prompt.txt"
echo '{"type":"result","num_turns":1,"text":"ok"}'
exit 0
MOCK_EOF
chmod +x "${TMPDIR_TEST}/claude"

# Generate a prompt larger than 128KB (131073 bytes)
large_prompt=$(python3 -c "print('X' * 200000)" 2>/dev/null || printf '%0.s.' $(seq 1 200000))
prompt_len=${#large_prompt}
if [[ "$prompt_len" -ge 131072 ]]; then
    pass "Generated test prompt of ${prompt_len} bytes (> 128KB)"
else
    fail "Test prompt too small: ${prompt_len} bytes"
fi

# Exercise _call_planning_batch with the large prompt via mock claude
export PATH="${TMPDIR_TEST}:${PATH}"
export TEKHTON_VERIFY_DIR="${TMPDIR_TEST}"
export TEKHTON_TEST_MODE=true

# Source just enough to run _call_planning_batch
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/plan.sh" 2>/dev/null || true

log_file="${TMPDIR_TEST}/test.log"
touch "$log_file"

output=$(_call_planning_batch "test-model" "1" "$large_prompt" "$log_file" 2>/dev/null) || true

if [[ -f "${TMPDIR_TEST}/received_prompt.txt" ]]; then
    received_len=$(wc -c < "${TMPDIR_TEST}/received_prompt.txt")
    # Trim trailing newline from wc
    received_len=$(echo "$received_len" | tr -d '[:space:]')
    # The received prompt should match the original (within a byte for trailing newline)
    if [[ "$received_len" -ge 131072 ]]; then
        pass "Mock claude received ${received_len} bytes via stdin (> 128KB)"
    else
        fail "Mock claude received only ${received_len} bytes (expected >= 131072)"
    fi
else
    fail "Mock claude never received prompt (received_prompt.txt missing)"
fi

# Verify temp file was cleaned up
leftover=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tekhton_prompt_$$.txt" 2>/dev/null || true)
if [[ -z "$leftover" ]]; then
    pass "Temp file cleaned up after _call_planning_batch"
else
    fail "Temp file still exists: $leftover"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
exit "$FAIL"
