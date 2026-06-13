#!/usr/bin/env bash
# m26: Regression guard for Goal 1 — non-run commands must not clear the
# terminal when stdout is a TTY.
#
# Root cause: _tui_restore_terminal() in lib/sidecar_lifecycle.sh calls
# `tput rmcup` unconditionally, which exits the alternate screen even when the
# TUI sidecar was never spawned (i.e. _TUI_ACTIVE=false). Non-run subcommands
# (dag, help, config) never spawn the sidecar, so the EXIT trap calls
# _tui_restore_terminal with _TUI_ACTIVE=false and clears the screen.
#
# Fix shape: guard every terminal-restore action behind
# [[ "${_TUI_ACTIVE:-false}" == "true" ]] so commands that never entered the
# alternate screen never exit it.
#
# Tests:
#   A — inactive TUI: _tui_restore_terminal must NOT call tput rmcup
#   B — active TUI: _tui_restore_terminal must call tput rmcup (happy path)
#   C — PTY: no \e[?1049l / \e[2J / \e[?1049h bytes emitted when _TUI_ACTIVE=false

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── Test A: inactive TUI — _tui_restore_terminal must NOT call tput rmcup ───

_run_test_A() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Fake tput writes its first argument to a log file; we detect if "rmcup"
    # was among the calls.
    cat > "${tmpdir}/tput" <<'STUB'
#!/bin/sh
echo "$1" >> "${TPUT_CALL_LOG}"
exit 0
STUB
    chmod +x "${tmpdir}/tput"

    local log_file="${tmpdir}/tput.log"
    touch "$log_file"
    TPUT_CALL_LOG="$log_file"

    # Run in a subshell so _TUI_ACTIVE, PATH, and stty mock do not leak.
    TPUT_CALL_LOG="$log_file" \
    PATH="${tmpdir}:${PATH}" \
    bash -c "
        set -euo pipefail
        source '${TEKHTON_HOME}/lib/sidecar_lifecycle.sh'
        # Silence stty — it would fail on a non-terminal fd in CI.
        stty() { :; }
        export -f stty
        _TUI_ACTIVE=false
        _tui_restore_terminal
    " 2>/dev/null

    if grep -q '^rmcup$' "$log_file" 2>/dev/null; then
        fail "A: _tui_restore_terminal called tput rmcup when _TUI_ACTIVE=false"
    else
        pass "A: _tui_restore_terminal is a no-op when _TUI_ACTIVE=false"
    fi
}

# ─── Test B: active TUI — _tui_restore_terminal must call tput rmcup ─────────

_run_test_B() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "${tmpdir}/tput" <<'STUB'
#!/bin/sh
echo "$1" >> "${TPUT_CALL_LOG}"
exit 0
STUB
    chmod +x "${tmpdir}/tput"

    local log_file="${tmpdir}/tput.log"
    touch "$log_file"

    TPUT_CALL_LOG="$log_file" \
    PATH="${tmpdir}:${PATH}" \
    bash -c "
        set -euo pipefail
        source '${TEKHTON_HOME}/lib/sidecar_lifecycle.sh'
        stty() { :; }
        export -f stty
        _TUI_ACTIVE=true
        _tui_restore_terminal
    " 2>/dev/null

    if grep -q '^rmcup$' "$log_file" 2>/dev/null; then
        pass "B: _tui_restore_terminal calls tput rmcup when _TUI_ACTIVE=true"
    else
        fail "B: _tui_restore_terminal did NOT call tput rmcup when _TUI_ACTIVE=true"
    fi
}

# ─── Test C: PTY — no alt-screen sequences emitted when TUI is inactive ──────
# Uses Python's pty module to run a bash subshell under a pseudo-TTY.
# tput detects a real terminal and would emit \x1b[?1049l for rmcup.
# After the fix, _tui_restore_terminal must be a no-op when _TUI_ACTIVE=false.

_run_test_C() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "SKIP C: python3 not available (pty test requires python3)"
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Bash script that will run under the pty.
    local inner_script="${tmpdir}/inner.sh"
    cat > "$inner_script" <<INNER
#!/usr/bin/env bash
source '${TEKHTON_HOME}/lib/sidecar_lifecycle.sh'
export _TUI_ACTIVE=false
_tui_restore_terminal
echo DONE
INNER
    chmod +x "$inner_script"

    local captured="${tmpdir}/captured.bin"

    # Run under a pty via Python.
    python3 - "$inner_script" "$captured" <<'PYEOF'
import os, sys, select, subprocess, time

inner_script = sys.argv[1]
captured_path = sys.argv[2]

master_fd, slave_fd = os.openpty()
proc = subprocess.Popen(
    ['bash', inner_script],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
    close_fds=True,
)
os.close(slave_fd)

output = b''
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    rlist, _, _ = select.select([master_fd], [], [], 0.1)
    if rlist:
        try:
            chunk = os.read(master_fd, 4096)
            output += chunk
        except OSError:
            break
    if proc.poll() is not None:
        # Drain remaining
        while True:
            rlist, _, _ = select.select([master_fd], [], [], 0.05)
            if rlist:
                try:
                    chunk = os.read(master_fd, 4096)
                    if chunk:
                        output += chunk
                    else:
                        break
                except OSError:
                    break
            else:
                break
        break

try:
    os.close(master_fd)
except OSError:
    pass
proc.wait()

with open(captured_path, 'wb') as f:
    f.write(output)
PYEOF

    # Check for alt-screen and clear sequences in captured bytes.
    # \e[?1049h = enter alt screen, \e[?1049l = exit alt screen, \e[2J = clear
    local bad_seqs=(
        $'\x1b[?1049h'
        $'\x1b[?1049l'
        $'\x1b[2J'
    )
    local found_bad=0
    for seq in "${bad_seqs[@]}"; do
        if grep -qFe "$seq" "$captured" 2>/dev/null; then
            found_bad=1
            break
        fi
    done

    if [[ $found_bad -eq 1 ]]; then
        fail "C: alt-screen or clear escape sequence detected in pty output when _TUI_ACTIVE=false"
    else
        pass "C: no alt-screen/clear sequences emitted under pty when _TUI_ACTIVE=false"
    fi
}

_run_test_A
_run_test_B
_run_test_C

echo ""
echo "────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
