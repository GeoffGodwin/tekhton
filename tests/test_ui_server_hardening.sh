#!/usr/bin/env bash
# =============================================================================
# test_ui_server_hardening.sh — M30 coverage gaps: _start_ui_server curl probe
#                               timeout and _stop_ui_server process group kill
#
# Tests:
#   10. _start_ui_server() curl probe timeout: a hanging curl is cut off at 5s
#       and the startup loop eventually gives up rather than hanging forever.
#   11. _stop_ui_server() process group kill: kill -TERM "-$_UI_SERVER_PID"
#       terminates both the server process and its child processes.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

MOCK_BIN="${TMPDIR_ROOT}/mock_bin"
mkdir -p "$MOCK_BIN"

PROJECT_DIR="$TMPDIR_ROOT"
cd "$TMPDIR_ROOT"

# Minimal pipeline environment
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/ui_validate.sh"

FAIL=0

assert_true() {
    local name="$1" cond="$2"
    if eval "$cond"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — condition false: $cond"
        FAIL=1
    fi
}

assert_false() {
    local name="$1" cond="$2"
    if ! eval "$cond"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — condition unexpectedly true: $cond"
        FAIL=1
    fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# =============================================================================
# Test 10: _start_ui_server() curl probe timeout does not cause indefinite hang
#
# Strategy:
#   - Replace curl with a mock that sleeps 30s (simulating a slow/stuck endpoint).
#   - Set UI_SERVER_STARTUP_TIMEOUT=1 so the startup loop makes exactly one probe
#     attempt before giving up.
#   - Verify the function returns in < 12s (5s curl timeout + 1s sleep + 1s buffer),
#     proving the per-probe timeout fired and the loop did not block on curl.
# =============================================================================

# Create a mock curl that simulates a connection that accepts but never responds.
cat > "${MOCK_BIN}/curl" << 'MOCKEOF'
#!/usr/bin/env bash
# Simulates a curl that hangs for 30 seconds (e.g. a server that accepts the
# TCP connection but never sends an HTTP response).
sleep 30
echo "000"
MOCKEOF
chmod +x "${MOCK_BIN}/curl"

# Reset server state
_UI_SERVER_PID=0
_UI_SERVER_PORT_ACTUAL=0

UI_SERVE_CMD="sleep 300"
UI_SERVE_PORT=19871
UI_SERVER_STARTUP_TIMEOUT=1  # One probe iteration then give up

OLD_PATH="$PATH"
export PATH="${MOCK_BIN}:${PATH}"

_t10_start=$(date +%s)
_t10_rc=0
_start_ui_server 2>/dev/null || _t10_rc=$?
_t10_end=$(date +%s)
_t10_elapsed=$(( _t10_end - _t10_start ))

# Clean up the background server (sleep 300) if it was launched
if [[ "$_UI_SERVER_PID" -gt 0 ]]; then
    kill "$_UI_SERVER_PID" 2>/dev/null || true
    wait "$_UI_SERVER_PID" 2>/dev/null || true
    _UI_SERVER_PID=0
fi

export PATH="$OLD_PATH"

# The function must fail (server never becomes ready)
assert_eq "10a. _start_ui_server returns 1 when server never ready" "1" "$_t10_rc"

# The function must complete in under 12 seconds.
# Without the timeout 5 guard, curl would block the full 30s per probe, making
# this test take >> 12s.  With the guard, one probe takes <= 5s + 1s sleep = 6s.
if [[ "$_t10_elapsed" -lt 12 ]]; then
    echo "PASS: 10b. _start_ui_server completed in ${_t10_elapsed}s (< 12s — curl probe timeout enforced)"
else
    echo "FAIL: 10b. _start_ui_server took ${_t10_elapsed}s (>= 12s — curl probe likely not timed out)"
    FAIL=1
fi

# =============================================================================
# Test 11: _stop_ui_server() kills the process group, not just the server PID
#
# Strategy (requires setsid):
#   - Start a mock server with setsid so it has its own process group.
#   - The mock server spawns a child (simulating a headless browser or worker).
#   - Call _stop_ui_server() to exercise the kill -TERM "-$_UI_SERVER_PID" path.
#   - Verify both the server process and its child are dead after the call.
#
# This tests a different code path from Test 9 (which exercises _run_smoke_test's
# two-phase TERM/KILL sequence via _smoke_pid). _stop_ui_server uses _UI_SERVER_PID
# and a single-step kill with a fallback but no SIGKILL follow-up.
# =============================================================================
if command -v setsid &>/dev/null; then
    CHILD_PID_FILE="${TMPDIR_ROOT}/child_pid_t11.txt"
    MOCK_SERVER="${TMPDIR_ROOT}/mock_server_t11.sh"
    rm -f "$CHILD_PID_FILE"

    # A mock server script that spawns a long-lived child process, then blocks.
    # This simulates a node server that spawns a headless browser instance.
    cat > "$MOCK_SERVER" << MOCKEOF
#!/usr/bin/env bash
# Write child PID to a file so the test can check it later.
sleep 300 &
echo \$! > "${CHILD_PID_FILE}"
# Parent sleeps indefinitely, waiting to be killed
sleep 300
MOCKEOF
    chmod +x "$MOCK_SERVER"

    # Reset server state
    _UI_SERVER_PID=0

    # Start mock server in its own process group, exactly as _start_ui_server does.
    setsid bash "$MOCK_SERVER" &>/dev/null &
    _UI_SERVER_PID=$!

    # Give the mock server a moment to fork its child and write the PID file.
    sleep 1

    _t11_child_pid=""
    _t11_child_pid=$(cat "$CHILD_PID_FILE" 2>/dev/null || true)

    # Verify the server and its child are running before we call _stop_ui_server.
    _t11_server_alive=false
    _t11_child_alive=false
    kill -0 "$_UI_SERVER_PID" 2>/dev/null && _t11_server_alive=true || true
    if [[ -n "$_t11_child_pid" ]]; then
        kill -0 "$_t11_child_pid" 2>/dev/null && _t11_child_alive=true || true
    fi

    if [[ "$_t11_server_alive" != "true" ]]; then
        echo "SKIP: 11. Mock server did not start — cannot test _stop_ui_server process group kill"
    elif [[ -z "$_t11_child_pid" ]] || [[ "$_t11_child_alive" != "true" ]]; then
        echo "SKIP: 11. Mock server child did not start — cannot test process group cleanup"
    else
        # Save original PID before _stop_ui_server resets it to 0
        _t11_orig_server_pid="$_UI_SERVER_PID"

        # Both running — now exercise _stop_ui_server()
        _stop_ui_server 2>/dev/null

        # _stop_ui_server resets _UI_SERVER_PID to 0
        assert_eq "11a. _stop_ui_server resets _UI_SERVER_PID to 0" "0" "$_UI_SERVER_PID"

        # Give processes a moment to be reaped — some environments (containers,
        # sandboxes) are slow to propagate SIGTERM to process group children.
        sleep 2

        # Verify the server process itself is dead (using saved original PID)
        if ! kill -0 "$_t11_orig_server_pid" 2>/dev/null; then
            echo "PASS: 11b. Server process (PID ${_t11_orig_server_pid}) terminated by _stop_ui_server"
        else
            echo "FAIL: 11b. Server process ${_t11_orig_server_pid} still alive after _stop_ui_server"
            FAIL=1
            kill "$_t11_orig_server_pid" 2>/dev/null || true
        fi

        # Verify the child process is also dead (process group kill worked)
        if [[ -n "$_t11_child_pid" ]]; then
            if ! kill -0 "$_t11_child_pid" 2>/dev/null; then
                echo "PASS: 11c. _stop_ui_server process group kill terminated orphaned child (PID ${_t11_child_pid})"
            else
                echo "FAIL: 11c. Child process ${_t11_child_pid} still alive after _stop_ui_server — process group kill did not propagate"
                FAIL=1
                # Clean up the orphan so it doesn't pollute the environment
                kill "$_t11_child_pid" 2>/dev/null || true
            fi
        else
            echo "FAIL: 11c. Child PID file not written — cannot verify process group cleanup"
            FAIL=1
        fi
    fi
else
    echo "SKIP: 11. setsid not available — _stop_ui_server process group kill test skipped"
fi

# =============================================================================
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All UI server hardening tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAIL"
