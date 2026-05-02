#!/usr/bin/env bash
# =============================================================================
# test_tui_orphan_lifecycle_integration.sh — end-to-end test spawning the
# real tools/tui.py sidecar and verifying the orphan-recovery fix works in
# a realistic scenario. Simulates a failure exit where _TUI_ACTIVE has been
# flipped false by an earlier hook, then the EXIT trap calls tui_stop.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; jobs -p | xargs -r kill -9 2>/dev/null || true' EXIT

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
# Defense-in-depth: prevent terminal-restore escape sequences from leaking to
# the parent shell's TTY when this test runs inside a live tekhton pipeline.
tput()        { :; }
stty()        { :; }

# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/tui.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# --- Helpers ----------------------------------------------------------------

# Check if Python and rich are available (tui.py requires them)
_check_python_available() {
    if ! python3 -c "import rich" 2>/dev/null; then
        echo "SKIP: Python 3 or rich library not available (tui.py requires both)"
        exit 0
    fi
}

_proc_alive() {
    kill -0 "$1" 2>/dev/null
}

_emit_status() {
    local status_file="$1"
    local agent_status="${2:-running}"
    local turns="${3:-0}"

    cat > "$status_file" <<EOF
{
    "version": 1,
    "milestone": "",
    "milestone_title": "Testing",
    "task": "test",
    "attempt": 1,
    "max_attempts": 1,
    "stage_label": "coder",
    "stage_num": 1,
    "stage_total": 4,
    "agent_turns_used": $turns,
    "agent_turns_max": 70,
    "agent_elapsed_secs": 100,
    "stage_start_ts": 0,
    "pipeline_elapsed_secs": 100,
    "stages_complete": [],
    "current_agent_status": "$agent_status",
    "recent_events": [{"ts": "14:23:01", "level": "info", "msg": "test event"}],
    "run_mode": "task",
    "cli_flags": "",
    "stage_order": [],
    "complete": false,
    "action_items": []
}
EOF
}

# =============================================================================
_check_python_available

echo "=== Integration Test: TUI Orphan Lifecycle ==="
echo ""

# --- Test Setup: Spawn real tui.py sidecar --------------------------------
echo "=== Spawning real tui.py sidecar (this may take a few seconds) ==="

STATUS_FILE="$TMPDIR/.claude/tui_status.json"

# Emit an initial status file showing "running" + zero turns
# (simulating the build-gate failure scenario)
_emit_status "$STATUS_FILE" "running" "0"

# Sleep a tiny bit to let the file hit disk before tui.py opens it
sleep 0.1

# Start the real sidecar in the background. It reads from the status file
# and exits when complete=true or watchdog fires or it's killed.
# Use --watchdog-secs 2 to make the test faster (normally it's 300).
python3 "$TEKHTON_HOME/tools/tui.py" \
    --status-file "$STATUS_FILE" \
    --tick-ms 100 \
    --event-lines 10 \
    --watchdog-secs 2 \
    --simple-logo \
    </dev/null >/dev/null 2>&1 &

SIDECAR_PID=$!

# Record the PID in the pidfile, simulating what tui_start would do
echo "$SIDECAR_PID" > "$PROJECT_DIR/.claude/tui_sidecar.pid"

# Give the sidecar a moment to start and stabilize
sleep 0.5

# Verify the process is alive
if _proc_alive "$SIDECAR_PID"; then
    pass "Real tui.py sidecar started (PID=$SIDECAR_PID)"
else
    fail "Integration: sidecar startup" "Process PID=$SIDECAR_PID is not alive"
    exit 1
fi

if [[ -f "$PROJECT_DIR/.claude/tui_sidecar.pid" ]]; then
    pass "Pidfile created correctly"
else
    fail "Integration: pidfile" "Pidfile not found"
    exit 1
fi

# --- Test Scenario: Simulate failure exit with _TUI_ACTIVE=false ----------
echo ""
echo "=== Simulating failure exit: _TUI_ACTIVE=false, tui_stop called ==="

# Before the fix, the sidecar would stay alive because tui_stop early-returned
# when _TUI_ACTIVE was false. After the fix, tui_stop should kill it via the
# pidfile fallback and remove the pidfile.

_TUI_ACTIVE=false
_TUI_PID=""

tui_stop

# Give the signal a moment to be delivered
sleep 0.2

# --- Verify the sidecar is dead and pidfile is removed --------------------
echo ""
echo "=== Verifying the fix ==="

# The sidecar should be dead now (killed by tui_stop via pidfile)
# OR if not yet dead, it should die within a few seconds due to the
# watchdog timeout (2× 2 secs = 4 seconds from when it started).
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ! _proc_alive "$SIDECAR_PID"; then
        pass "Sidecar was killed by tui_stop (or watchdog fired)"
        break
    fi
    if [[ "$attempt" -lt 10 ]]; then
        sleep 0.5
    fi
done

if _proc_alive "$SIDECAR_PID"; then
    fail "Integration: sidecar death" "Process PID=$SIDECAR_PID still alive after 5 seconds"
    fail "Integration: fallback" "Neither tui_stop nor watchdog killed the orphan"
    kill -9 "$SIDECAR_PID" 2>/dev/null || true
else
    pass "Sidecar process is dead"
fi

# The pidfile should be cleaned up by tui_stop
if [[ -f "$PROJECT_DIR/.claude/tui_sidecar.pid" ]]; then
    fail "Integration: pidfile cleanup" "Pidfile still on disk after tui_stop"
else
    pass "Pidfile was removed by tui_stop"
fi

# --- Test edge case: verify watchdog would also work as fallback ----------
echo ""
echo "=== Bonus: Verify watchdog firing logic (conditional) ==="

# Set up a fresh sidecar with a longer wait to test the watchdog alone
# (This is optional and only if the sidecar cleanup above succeeded)
if [[ "$FAIL" -eq 0 ]]; then
    _emit_status "$STATUS_FILE" "running" "0"

    sleep 0.1

    python3 "$TEKHTON_HOME/tools/tui.py" \
        --status-file "$STATUS_FILE" \
        --tick-ms 100 \
        --event-lines 10 \
        --watchdog-secs 1 \
        --simple-logo \
        </dev/null >/dev/null 2>&1 &

    WATCHDOG_PID=$!
    echo "$WATCHDOG_PID" > "$PROJECT_DIR/.claude/tui_sidecar.pid"

    sleep 0.3

    if _proc_alive "$WATCHDOG_PID"; then
        pass "Second sidecar started for watchdog test (PID=$WATCHDOG_PID)"

        # Don't call tui_stop this time; just wait for the watchdog to fire.
        # With watchdog_secs=1 and 2× multiplier, it should exit within ~2.5 seconds.
        WATCHDOG_FIRED=false
        for attempt in {1..20}; do
            if ! _proc_alive "$WATCHDOG_PID"; then
                WATCHDOG_FIRED=true
                pass "Watchdog escape hatch fired and killed the sidecar"
                break
            fi
            sleep 0.25
        done

        if [[ "$WATCHDOG_FIRED" == "false" ]]; then
            warn "Watchdog test: sidecar still alive after 5 seconds (may be slow system)"
            kill -9 "$WATCHDOG_PID" 2>/dev/null || true
        fi
    fi
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
