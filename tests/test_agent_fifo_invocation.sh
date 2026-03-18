#!/usr/bin/env bash
# =============================================================================
# test_agent_fifo_invocation.sh — FIFO-isolated invocation, activity timeout,
#                                  and Windows detection in lib/agent.sh
#
# Tests:
#   1. FIFO path: run_agent() with mock claude produces correct output + metrics
#   2. Activity timeout: mock claude that hangs triggers activity timeout
#   3. _kill_agent_windows() is a no-op when _AGENT_WINDOWS_CLAUDE=false
#   4. Windows detection variables are set correctly on non-Windows
#   5. Timeout --kill-after flag detection
#   6. Exit code propagation through FIFO path
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# --- Minimal pipeline globals ------------------------------------------------
export PROJECT_DIR="$TEST_TMP"
export PROJECT_NAME="test-project"
LOG_DIR="${TEST_TMP}/logs"
mkdir -p "$LOG_DIR"

# Create a mock bin directory for fake claude
MOCK_BIN="${TEST_TMP}/mock_bin"
mkdir -p "$MOCK_BIN"

# Prepend mock bin to PATH once — run_agent is a shell function, so
# VAR=value func does NOT create a temporary environment (it persists).
export PATH="${MOCK_BIN}:${PATH}"
export TEKHTON_SESSION_DIR="$TEST_TMP"

source "${TEKHTON_HOME}/lib/common.sh"

# Override _AGENT_WINDOWS_CLAUDE before sourcing agent.sh won't work because
# agent.sh sets it at source time. We source agent.sh, then override.
source "${TEKHTON_HOME}/lib/agent.sh"

cd "$TEST_TMP"
git init -q .

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_ge() {
    local name="$1" min="$2" actual="$3"
    if [[ "$actual" -lt "$min" ]]; then
        echo "FAIL: $name — expected >= $min, got '$actual'"
        FAIL=1
    fi
}

assert_file_exists() {
    local name="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        echo "FAIL: $name — file '$path' does not exist"
        FAIL=1
    fi
}

assert_file_not_exists() {
    local name="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "FAIL: $name — file '$path' should not exist"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: Windows detection — on non-Windows, _AGENT_WINDOWS_CLAUDE is false
# =============================================================================

# 1.1: On a standard Linux/macOS system (or WSL with native claude),
# _AGENT_WINDOWS_CLAUDE should be false
assert_eq "1.1 _AGENT_WINDOWS_CLAUDE is false on non-Windows claude" "false" "$_AGENT_WINDOWS_CLAUDE"

# =============================================================================
# Phase 2: _kill_agent_windows() no-op when not Windows
# =============================================================================

# 2.1: _kill_agent_windows should return immediately without error
_AGENT_WINDOWS_CLAUDE=false
_kill_agent_windows
assert_eq "2.1 _kill_agent_windows is no-op when not Windows" "0" "$?"

# =============================================================================
# Phase 3: Timeout --kill-after flag detection
# =============================================================================

# 3.1: On Linux with GNU coreutils, the flag should be set (non-empty)
# On macOS/BSD without GNU timeout, it may be empty — both are valid.
# We just verify the variable exists and is a string.
if command -v timeout &>/dev/null && timeout --help 2>&1 | grep -q 'kill-after'; then
    assert_eq "3.1 _TIMEOUT_KILL_AFTER_FLAG set on GNU coreutils" "--kill-after=60" "$_TIMEOUT_KILL_AFTER_FLAG"
else
    assert_eq "3.1 _TIMEOUT_KILL_AFTER_FLAG empty without GNU timeout" "" "$_TIMEOUT_KILL_AFTER_FLAG"
fi

# =============================================================================
# Phase 4: FIFO path — run_agent() with mock claude
# =============================================================================

# Create a mock claude that outputs JSON lines and exits successfully.
# Simulates claude CLI with --output-format json.
cat > "${MOCK_BIN}/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
# Mock claude: output a text message then a result object with num_turns
echo '{"type":"text","text":"Hello from mock claude"}'
sleep 0.2
echo '{"type":"result","num_turns":5,"exit_code":0}'
exit 0
MOCK_EOF
chmod +x "${MOCK_BIN}/claude"

# 4.1: Run agent with mock claude — verify it completes and sets metrics
AGENT_TIMEOUT=30
AGENT_ACTIVITY_TIMEOUT=10
LOG_FILE="${LOG_DIR}/test_fifo_normal.log"

# Put mock claude first on PATH
run_agent "TestFIFO" "test-model" "10" "test prompt" "$LOG_FILE" 2>/dev/null

assert_eq "4.1a LAST_AGENT_EXIT_CODE is 0" "0" "$LAST_AGENT_EXIT_CODE"
assert_eq "4.1b LAST_AGENT_TURNS is 5" "5" "$LAST_AGENT_TURNS"
assert_eq "4.1c LAST_AGENT_NULL_RUN is false" "false" "$LAST_AGENT_NULL_RUN"
assert_ge "4.1d LAST_AGENT_ELAPSED >= 0" "0" "$LAST_AGENT_ELAPSED"
assert_file_exists "4.1e log file created" "$LOG_FILE"

# 4.2: Log file should contain the mock claude output
if grep -q '"type":"text"' "$LOG_FILE"; then
    assert_eq "4.2 log file has JSON output" "0" "0"
else
    echo "FAIL: 4.2 log file should contain JSON output from mock claude"
    FAIL=1
fi

# =============================================================================
# Phase 5: FIFO path — non-zero exit code propagation
# =============================================================================

# Create a mock claude that exits with error
cat > "${MOCK_BIN}/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
echo '{"type":"text","text":"Error scenario"}'
echo '{"type":"result","num_turns":1,"exit_code":1}'
exit 1
MOCK_EOF
chmod +x "${MOCK_BIN}/claude"

LOG_FILE="${LOG_DIR}/test_fifo_error.log"
run_agent "TestError" "test-model" "10" "test prompt" "$LOG_FILE" 2>/dev/null

assert_eq "5.1 LAST_AGENT_EXIT_CODE is 1" "1" "$LAST_AGENT_EXIT_CODE"
assert_eq "5.2 LAST_AGENT_TURNS is 1" "1" "$LAST_AGENT_TURNS"
assert_eq "5.3 LAST_AGENT_NULL_RUN is true (1 turn + error)" "true" "$LAST_AGENT_NULL_RUN"

# =============================================================================
# Phase 6: Activity timeout — mock claude that hangs
# =============================================================================

# Create a mock claude that outputs one line then goes silent.
# trap EXIT ensures child processes are cleaned up when the mock is killed.
cat > "${MOCK_BIN}/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
trap 'kill $(jobs -p) 2>/dev/null; exit' TERM
echo '{"type":"text","text":"Starting..."}'
# Hang indefinitely — activity timeout should kill us
sleep 300 &
wait
MOCK_EOF
chmod +x "${MOCK_BIN}/claude"

# Use a very short activity timeout + poll interval to keep tests fast.
# AGENT_TIMEOUT=0 disables the outer timeout wrapper so only the activity
# timeout mechanism is exercised.
LOG_FILE="${LOG_DIR}/test_fifo_timeout.log"
AGENT_ACTIVITY_TIMEOUT=2
AGENT_ACTIVITY_POLL=1
AGENT_TIMEOUT=0

run_agent "TestTimeout" "test-model" "10" "test prompt" "$LOG_FILE" 2>/dev/null

assert_eq "6.1 LAST_AGENT_EXIT_CODE is 124 (timeout)" "124" "$LAST_AGENT_EXIT_CODE"
assert_eq "6.2 LAST_AGENT_NULL_RUN is true on timeout" "true" "$LAST_AGENT_NULL_RUN"

# Check log contains activity timeout message
if grep -q "ACTIVITY TIMEOUT" "$LOG_FILE"; then
    assert_eq "6.3 log contains ACTIVITY TIMEOUT message" "0" "0"
else
    echo "FAIL: 6.3 log should contain ACTIVITY TIMEOUT message"
    FAIL=1
fi

# Reset timeouts for remaining tests so each phase is self-contained
unset AGENT_ACTIVITY_POLL
AGENT_TIMEOUT=30

# =============================================================================
# Phase 7: Zero-turn mock — null run detection through FIFO
# =============================================================================

# Create a mock claude that outputs no num_turns in result
cat > "${MOCK_BIN}/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
echo '{"type":"text","text":"Did nothing"}'
echo '{"type":"result","exit_code":0}'
exit 0
MOCK_EOF
chmod +x "${MOCK_BIN}/claude"

LOG_FILE="${LOG_DIR}/test_fifo_zero_turns.log"
AGENT_ACTIVITY_TIMEOUT=10

run_agent "TestZeroTurns" "test-model" "10" "test prompt" "$LOG_FILE" 2>/dev/null

assert_eq "7.1 LAST_AGENT_TURNS is 0 when num_turns missing" "0" "$LAST_AGENT_TURNS"
assert_eq "7.2 LAST_AGENT_NULL_RUN is true for 0 turns" "true" "$LAST_AGENT_NULL_RUN"

# =============================================================================
# Phase 8: Metrics accumulation across multiple runs
# =============================================================================

TOTAL_TURNS=0
TOTAL_TIME=0
STAGE_SUMMARY=""

cat > "${MOCK_BIN}/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
echo '{"type":"result","num_turns":3}'
exit 0
MOCK_EOF
chmod +x "${MOCK_BIN}/claude"

LOG_FILE="${LOG_DIR}/test_accum_1.log"
run_agent "Accum1" "test-model" "10" "prompt1" "$LOG_FILE" 2>/dev/null

LOG_FILE="${LOG_DIR}/test_accum_2.log"
run_agent "Accum2" "test-model" "10" "prompt2" "$LOG_FILE" 2>/dev/null

assert_eq "8.1 TOTAL_TURNS accumulated from 2 runs" "6" "$TOTAL_TURNS"
assert_ge "8.2 TOTAL_TIME >= 0 after 2 runs" "0" "$TOTAL_TIME"

# =============================================================================
# Phase 9: FIFO cleanup — the FIFO for our PID should not exist
# =============================================================================

# The FIFO path uses $$ (our PID). After run_agent() returns, it should be cleaned up.
_our_fifo="/tmp/tekhton_agent_fifo_$$"
assert_file_not_exists "9.1 FIFO for our PID cleaned up" "$_our_fifo"
# Belt-and-suspenders: clean up any stale FIFOs from this test run
rm -f "/tmp/tekhton_agent_fifo_$$" 2>/dev/null || true

# =============================================================================
# Done
# =============================================================================

if [[ "$FAIL" -ne 0 ]]; then
    echo "FAILURES: $FAIL"
    exit 1
fi
echo "All agent FIFO invocation tests passed."
exit 0
