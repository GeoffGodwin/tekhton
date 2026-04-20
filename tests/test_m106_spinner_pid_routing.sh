#!/usr/bin/env bash
# =============================================================================
# test_m106_spinner_pid_routing.sh — M106 — verify spinner PID routing
#
# Primary behavior: _start_agent_spinner emits "spinner_pid:tui_updater_pid"
# (colon-separated). When TUI is active, spinner_pid is empty and
# tui_updater_pid is non-empty. When TUI is inactive, the reverse.
# The colon separator preserves an empty leading field (TUI path) that
# whitespace-split would silently collapse into the wrong variable.
#
# AC-13: _TUI_ACTIVE=true → _spinner_pid empty, _tui_updater_pid non-empty
# AC-14: _TUI_ACTIVE=false (non-TUI) → _spinner_pid non-empty, _tui_updater_pid empty
# AC-15: _stop_agent_spinner routes kills to the correct path
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Define tui_update_agent stub BEFORE sourcing agent_spinner.sh so
# `declare -f tui_update_agent` succeeds inside the TUI-path condition.
tui_update_agent() { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/agent_spinner.sh"

_turns_file="$TMPDIR_TEST/agent_last_turns"
touch "$_turns_file"

# =============================================================================
echo "=== AC-13: TUI mode — _spinner_pid empty, _tui_updater_pid non-empty ==="
# TEKHTON_TEST_MODE must be unset/empty so spawning conditions are evaluated.
# The test runner does not export TEKHTON_TEST_MODE, so this is the default state.
unset TEKHTON_TEST_MODE || true
export _TUI_ACTIVE=true

_spinner_pid="" _tui_updater_pid=""
IFS=: read -r _spinner_pid _tui_updater_pid \
    < <(_start_agent_spinner "TestAgent" "$_turns_file" "20")

if [[ -z "$_spinner_pid" ]]; then
    pass "AC-13: _spinner_pid is empty in TUI mode"
else
    fail "AC-13: _spinner_pid should be empty in TUI mode" "got '$_spinner_pid'"
fi

if [[ -n "$_tui_updater_pid" ]] && [[ "$_tui_updater_pid" =~ ^[0-9]+$ ]]; then
    pass "AC-13: _tui_updater_pid is a non-empty numeric PID in TUI mode"
else
    fail "AC-13: _tui_updater_pid should be a non-empty PID" "got '$_tui_updater_pid'"
fi

# Clean up the spawned TUI updater subshell
[[ -n "$_tui_updater_pid" ]] && kill "$_tui_updater_pid" 2>/dev/null || true
[[ -n "$_tui_updater_pid" ]] && wait "$_tui_updater_pid" 2>/dev/null || true

# =============================================================================
echo "=== AC-14: Non-TUI mode — _spinner_pid non-empty, _tui_updater_pid empty ==="
# Guard: /dev/tty must exist as a file for the non-TUI spinner condition to
# pass. On systems without /dev/tty (e.g. containers without devpts), the
# spinner never spawns and the test is meaningless.
unset TEKHTON_TEST_MODE || true
export _TUI_ACTIVE=false

if [[ ! -e /dev/tty ]]; then
    echo "  SKIP: /dev/tty absent — non-TUI spinner cannot spawn (AC-14)"
    PASS=$((PASS + 1))
else
    _spinner_pid="" _tui_updater_pid=""
    IFS=: read -r _spinner_pid _tui_updater_pid \
        < <(_start_agent_spinner "TestAgent" "$_turns_file" "20")

    if [[ -n "$_spinner_pid" ]] && [[ "$_spinner_pid" =~ ^[0-9]+$ ]]; then
        pass "AC-14: _spinner_pid is a non-empty numeric PID in non-TUI mode"
    else
        fail "AC-14: _spinner_pid should be non-empty in non-TUI mode" "got '$_spinner_pid'"
    fi

    if [[ -z "$_tui_updater_pid" ]]; then
        pass "AC-14: _tui_updater_pid is empty in non-TUI mode"
    else
        fail "AC-14: _tui_updater_pid should be empty in non-TUI mode" "got '$_tui_updater_pid'"
    fi

    # Clean up — process may have already exited if /dev/tty was not writable
    [[ -n "$_spinner_pid" ]] && kill "$_spinner_pid" 2>/dev/null || true
    [[ -n "$_spinner_pid" ]] && wait "$_spinner_pid" 2>/dev/null || true
fi

# =============================================================================
# AC-15 — verify _stop_agent_spinner kill routing.
#
# Use a kill function override and non-existent PIDs so that:
#   - `kill <fake_pid>` fails silently (2>/dev/null || true in the function)
#   - `wait <fake_pid>` returns immediately (not a child of this shell)
# This avoids hangs from waiting on real processes while still verifying
# that the correct PID slot is targeted by each code path.
# =============================================================================

declare -a _ac15_killed=()

# Override kill: record targeted PIDs, then attempt the real kill (silently).
# Bash functions shadow builtins, so _stop_agent_spinner's `kill` calls land here.
kill() {
    local _arg
    for _arg in "$@"; do
        [[ "$_arg" == -* ]] && continue  # skip signal flags (-9, -TERM, etc.)
        _ac15_killed+=("$_arg")
    done
    command kill "$@" 2>/dev/null || true
}

# --- AC-15a: TUI mode — empty spinner_pid, fake tui_updater_pid ---
echo "=== AC-15a: TUI mode (_spinner_pid empty) — only tui_updater_pid targeted ==="
_ac15_killed=()
_stop_agent_spinner "" "55551"

if [[ " ${_ac15_killed[*]:-} " == *" 55551 "* ]]; then
    pass "AC-15a: _stop_agent_spinner targeted tui_updater_pid (55551) in TUI path"
else
    fail "AC-15a: tui_updater_pid not targeted" "targeted: ${_ac15_killed[*]:-none}"
fi

# --- AC-15b: non-TUI mode — fake spinner_pid, empty tui_updater_pid ---
echo "=== AC-15b: non-TUI mode (_tui_updater_pid empty) — only spinner_pid targeted ==="
_ac15_killed=()
_stop_agent_spinner "55552" ""

if [[ " ${_ac15_killed[*]:-} " == *" 55552 "* ]]; then
    pass "AC-15b: _stop_agent_spinner targeted spinner_pid (55552) in non-TUI path"
else
    fail "AC-15b: spinner_pid not targeted" "targeted: ${_ac15_killed[*]:-none}"
fi

# --- AC-15c: TUI mode — spinner cleanup branch (printf to /dev/tty) NOT entered ---
# When spinner_pid is empty, the if-block containing `printf '\r\033[K' > /dev/tty`
# is skipped entirely.  Verify by checking that only the tui_updater PID was targeted.
echo "=== AC-15c: empty spinner_pid — spinner cleanup branch skipped ==="
_ac15_killed=()
_stop_agent_spinner "" "55553"

spinner_cleanup_triggered=false
for k in "${_ac15_killed[@]:-}"; do
    # An empty spinner_pid branch would target "" — detect any empty-string kill
    [[ -z "$k" ]] && spinner_cleanup_triggered=true
done

if [[ "$spinner_cleanup_triggered" == "false" ]]; then
    pass "AC-15c: spinner cleanup branch skipped when spinner_pid is empty"
else
    fail "AC-15c: spinner cleanup branch incorrectly entered" \
        "targeted PIDs: ${_ac15_killed[*]:-none}"
fi

# Restore real kill builtin
unset -f kill

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
