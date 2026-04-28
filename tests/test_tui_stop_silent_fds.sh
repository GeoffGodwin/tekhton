#!/usr/bin/env bash
# =============================================================================
# test_tui_stop_silent_fds.sh — regression coverage for the alt-screen flicker
# bug. When tui_stop runs in a child shell that shares /dev/tty with a live
# parent (e.g. a test invoked by tests/run_tests.sh while a pipeline TUI is
# rendering), it must not emit ANY bytes to fd 1 or fd 2 — including the
# tput rmcup / cnorm + stty icrnl escape sequences that previously leaked
# from the safety-net path. Terminal restoration now lives in
# _tui_restore_terminal, owned by tekhton.sh's EXIT trap; tui_stop itself
# must stay byte-silent on all paths a test might reach.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"
export TEKHTON_SESSION_DIR="$TMPDIR/session"
mkdir -p "$TEKHTON_SESSION_DIR"
mkdir -p "$TMPDIR/.claude"

log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }
# These stubs are part of the contract this test enforces: even if a future
# refactor reintroduces tput/stty into tui_stop, the test must still observe
# zero bytes on fd 1/fd 2. Real tput/stty would write escape sequences to
# the controlling TTY (bypassing fd 1/2), so the no-op stubs make the leak
# visible on the captured stream.
tput()        { printf 'TPUT_LEAK:%s\n' "$*"; }
stty()        { printf 'STTY_LEAK:%s\n' "$*"; }

# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/tui.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# _measure_tui_stop — invoke tui_stop in a subshell and capture any bytes
# emitted on fd 1 and fd 2. Echoes "<stdout_size>:<stderr_size>" so the
# caller can assert both are zero. A non-zero size indicates the contract
# was violated and a future test running concurrently with a live TUI
# would corrupt the alt-screen.
_measure_tui_stop() {
    local out err
    out="$TMPDIR/stop.out"
    err="$TMPDIR/stop.err"
    : > "$out"
    : > "$err"
    # Run tui_stop with fd 1/2 redirected to capture files. The redirection
    # is what a malicious leak would write to in the parent shell where
    # fd 1/2 are bound to the rich.live alt-screen.
    ( tui_stop ) >"$out" 2>"$err" || true
    printf '%s:%s\n' "$(wc -c < "$out" | tr -d ' ')" "$(wc -c < "$err" | tr -d ' ')"
}

# =============================================================================
echo "=== Test 1: tui_stop with no _TUI_PID and no pidfile is byte-silent ==="
# Cleanup-trap idempotency path: a fresh shell that never spawned a sidecar.
rm -f "$PROJECT_DIR/.claude/tui_sidecar.pid"
_TUI_ACTIVE=false
_TUI_PID=""

result=$(_measure_tui_stop)
if [[ "$result" == "0:0" ]]; then
    pass "tui_stop emits zero bytes to fd 1/2 when no sidecar is registered"
else
    fail "Test 1: byte-silence" "captured ${result} bytes (stdout:stderr); expected 0:0"
    echo "    --- stdout capture ---"
    sed 's/^/    /' < "$TMPDIR/stop.out" || true
    echo "    --- stderr capture ---"
    sed 's/^/    /' < "$TMPDIR/stop.err" || true
fi

# =============================================================================
echo "=== Test 2: tui_stop with stale pidfile (dead pid) is byte-silent ==="
# Pidfile from a prior crashed run, but the process is gone. Must not emit
# escape sequences while reaping the dead pidfile.
echo "999999" > "$PROJECT_DIR/.claude/tui_sidecar.pid"
_TUI_ACTIVE=false
_TUI_PID=""

result=$(_measure_tui_stop)
if [[ "$result" == "0:0" ]]; then
    pass "tui_stop emits zero bytes when reaping a stale pidfile"
else
    fail "Test 2: byte-silence (stale)" "captured ${result} bytes (stdout:stderr); expected 0:0"
fi

# =============================================================================
echo "=== Test 3: tui_stop with _TUI_ACTIVE=false but live pid is byte-silent ==="
# The orphan-recovery scenario: _TUI_ACTIVE was flipped false by an earlier
# hook but a real sidecar is still alive. tui_stop must reap it without
# emitting any bytes that would corrupt the parent's alt-screen.
sleep 60 &
fake_pid=$!
echo "$fake_pid" > "$PROJECT_DIR/.claude/tui_sidecar.pid"
_TUI_ACTIVE=false
_TUI_PID=""

result=$(_measure_tui_stop)
if [[ "$result" == "0:0" ]]; then
    pass "tui_stop emits zero bytes when reaping an orphan via pidfile"
else
    fail "Test 3: byte-silence (orphan)" "captured ${result} bytes (stdout:stderr); expected 0:0"
fi
# Reap the fake sidecar in case tui_stop did not (test isolation).
kill -9 "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true

# =============================================================================
echo "=== Test 4: tui_stop normal path with _TUI_ACTIVE=true is byte-silent ==="
# The happy-path teardown should also be silent so finalize_run can call
# tui_stop without contaminating the captured run log.
sleep 60 &
fake_pid=$!
echo "$fake_pid" > "$PROJECT_DIR/.claude/tui_sidecar.pid"
_TUI_ACTIVE=true
_TUI_PID="$fake_pid"

result=$(_measure_tui_stop)
if [[ "$result" == "0:0" ]]; then
    pass "tui_stop emits zero bytes on the normal teardown path"
else
    fail "Test 4: byte-silence (normal)" "captured ${result} bytes (stdout:stderr); expected 0:0"
fi
kill -9 "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true

# =============================================================================
echo "=== Test 5: tui_stop never invokes tput or stty on any path ==="
# Direct contract assertion: even if our byte-counter misses something,
# the stubs above would emit "TPUT_LEAK:" / "STTY_LEAK:" on fd 1 if the
# safety-net path is ever resurrected inside tui_stop. Sweep every
# scenario one more time with grep to catch the literal marker.
all_output="$TMPDIR/all.out"
: > "$all_output"
{
    rm -f "$PROJECT_DIR/.claude/tui_sidecar.pid"
    _TUI_ACTIVE=false
    _TUI_PID=""
    tui_stop

    echo "999999" > "$PROJECT_DIR/.claude/tui_sidecar.pid"
    tui_stop

    sleep 60 &
    fake_pid=$!
    echo "$fake_pid" > "$PROJECT_DIR/.claude/tui_sidecar.pid"
    _TUI_ACTIVE=true
    _TUI_PID="$fake_pid"
    tui_stop
    kill -9 "$fake_pid" 2>/dev/null || true
    wait "$fake_pid" 2>/dev/null || true
} >"$all_output" 2>&1 || true

if grep -qE 'TPUT_LEAK|STTY_LEAK' "$all_output"; then
    fail "Test 5: terminal-restore call site" "tui_stop invoked tput or stty on at least one path"
    echo "    --- captured ---"
    sed 's/^/    /' < "$all_output" || true
else
    pass "tui_stop never invokes tput or stty on any tested path"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
