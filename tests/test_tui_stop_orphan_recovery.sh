#!/usr/bin/env bash
# =============================================================================
# test_tui_stop_orphan_recovery.sh — bug-fix coverage for the build-gate-
# failure orphan sidecar. Verifies that tui_stop reaps a sidecar even when
# _TUI_ACTIVE has been flipped false by an earlier hook (so the EXIT trap
# in tekhton.sh can still kill the process via the pidfile fallback).
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
# Defense-in-depth: even though tui_stop no longer issues terminal-restore
# escape sequences, stub tput/stty here so any future regression cannot leak
# RMCUP / cnorm / icrnl to the parent shell's TTY when this test runs inside
# a live tekhton pipeline (which keeps a rich.live alt-screen open).
tput()        { :; }
stty()        { :; }

# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/tui.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# --- Helpers ----------------------------------------------------------------

# Spawn a long-lived process to act as a fake orphaned sidecar. Returns the
# pid via stdout; the trap on EXIT reaps it if it survives the test.
_spawn_fake_sidecar() {
    sleep 60 &
    echo "$!"
}

_proc_alive() {
    kill -0 "$1" 2>/dev/null
}

# =============================================================================
echo "=== Test 1: tui_stop kills sidecar via pidfile when _TUI_ACTIVE=false ==="
# Reproduce the orphan condition: _TUI_ACTIVE has been flipped false (e.g. by
# an earlier hook) but the sidecar process is still alive and the pidfile is
# still present from tui_start. Pre-fix: tui_stop early-returned and left
# the sidecar running; post-fix: pidfile fallback kills it.
fake_pid=$(_spawn_fake_sidecar)
echo "$fake_pid" > "$PROJECT_DIR/.claude/tui_sidecar.pid"

_TUI_ACTIVE=false
_TUI_PID=""

tui_stop

# Wait briefly for SIGTERM to take effect — tui_stop already polls 5×100ms.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    _proc_alive "$fake_pid" || break
    sleep 0.1
done

if _proc_alive "$fake_pid"; then
    fail "Test 1: orphan kill" "fake sidecar pid=$fake_pid still alive"
    kill -9 "$fake_pid" 2>/dev/null || true
else
    pass "tui_stop killed orphan sidecar despite _TUI_ACTIVE=false"
fi

if [[ -f "$PROJECT_DIR/.claude/tui_sidecar.pid" ]]; then
    fail "Test 1: pidfile removal" "pidfile still on disk after tui_stop"
else
    pass "tui_stop removed pidfile despite _TUI_ACTIVE=false"
fi

# =============================================================================
echo "=== Test 2: tui_stop is a safe no-op when no pidfile and no _TUI_PID ==="
# Idempotency check: cleanup trap may call tui_stop on a fresh shell that
# never spawned a sidecar. Must not raise, must not leave artifacts.
rm -f "$PROJECT_DIR/.claude/tui_sidecar.pid"
_TUI_ACTIVE=false
_TUI_PID=""

if tui_stop; then
    pass "tui_stop is a no-op when nothing to clean up"
else
    fail "Test 2: no-op idempotency" "tui_stop returned non-zero"
fi

# =============================================================================
echo "=== Test 3: tui_stop normal path with _TUI_ACTIVE=true and _TUI_PID set ==="
# Verify the normal teardown path is unchanged by the fix.
fake_pid=$(_spawn_fake_sidecar)
echo "$fake_pid" > "$PROJECT_DIR/.claude/tui_sidecar.pid"
_TUI_ACTIVE=true
_TUI_PID="$fake_pid"

tui_stop

for _ in 1 2 3 4 5 6 7 8 9 10; do
    _proc_alive "$fake_pid" || break
    sleep 0.1
done

if _proc_alive "$fake_pid"; then
    fail "Test 3: normal kill" "fake sidecar pid=$fake_pid still alive"
    kill -9 "$fake_pid" 2>/dev/null || true
else
    pass "tui_stop normal path still kills sidecar"
fi

if [[ "$_TUI_ACTIVE" != "false" ]]; then
    fail "Test 3: state flip" "_TUI_ACTIVE=$_TUI_ACTIVE (expected false)"
else
    pass "tui_stop flips _TUI_ACTIVE to false"
fi

# =============================================================================
echo "=== Test 4: tui_stop tolerates stale pidfile pointing to a dead pid ==="
# Pidfile exists from a prior crashed run, but the process is long gone and
# its PID has not been recycled. Must not crash; must clean up the pidfile.
echo "999999" > "$PROJECT_DIR/.claude/tui_sidecar.pid"
_TUI_ACTIVE=false
_TUI_PID=""

if tui_stop; then
    pass "tui_stop tolerates stale pidfile (dead pid)"
else
    fail "Test 4: stale pidfile" "tui_stop returned non-zero"
fi

if [[ -f "$PROJECT_DIR/.claude/tui_sidecar.pid" ]]; then
    fail "Test 4: stale cleanup" "pidfile still on disk after tui_stop"
else
    pass "tui_stop removes stale pidfile even when its pid is dead"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
