#!/usr/bin/env bash
# =============================================================================
# test_output_bus.sh — M103 — full Output Bus unit coverage.
#
# Covers the gaps left by test_output_bus_context_store.sh (which exercises
# only the _OUT_CTX API):
#   - _out_emit routing in CLI mode and TUI mode
#   - log/warn/header wrappers preserve pre-M99 output
#   - NO_COLOR=1 produces no ANSI escapes
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected substring '${needle}' in '${haystack}'"
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected='${expected}' actual='${actual}'"
    fi
}

# Ensure TUI is off by default; individual tests flip it explicitly.
export _TUI_ACTIVE=false

# Source common.sh to get the real log/warn/error/header wrappers and the
# _tui_strip_ansi / _tui_notify helpers the bus depends on. common.sh in turn
# sources output.sh and output_format.sh, so _OUT_CTX + _out_emit are also
# defined after this line.
# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"

# =============================================================================
echo "=== TC-OB-01: out_init populates all keys with safe defaults ==="
out_init

assert_eq "mode default is empty"        ""  "$(out_ctx mode)"
assert_eq "attempt default is 1"         "1" "$(out_ctx attempt)"
assert_eq "max_attempts default is 1"    "1" "$(out_ctx max_attempts)"
assert_eq "action_items default is empty" "" "$(out_ctx action_items)"

# =============================================================================
echo "=== TC-OB-02: out_set_context / out_ctx round-trip ==="
out_init
out_set_context mode "fix-nb"
assert_eq "set and get mode" "fix-nb" "$(out_ctx mode)"

out_set_context milestone_title "Output Bus"
assert_eq "set and get milestone_title" "Output Bus" "$(out_ctx milestone_title)"

# =============================================================================
echo "=== TC-OB-03: out_ctx on unset key returns empty, no error under set -u ==="
out_init
rc=0
out_ctx nonexistent_key >/dev/null 2>&1 || rc=$?
assert_eq "missing key exit code is 0" "0" "$rc"
result=$(out_ctx nonexistent_key 2>&1)
assert_eq "missing key returns empty string" "" "$result"

# =============================================================================
echo "=== TC-OB-04: out_set_context overwrites previous value ==="
out_init
out_set_context attempt 1
out_set_context attempt 3
assert_eq "second set overwrites first" "3" "$(out_ctx attempt)"

# =============================================================================
echo "=== TC-OB-05: _out_emit in CLI mode writes prefix + message to stdout ==="
_TUI_ACTIVE=false
output=$(LOG_FILE="" _out_emit info "hello from CLI" 2>/dev/null)
assert_contains "info emits [tekhton] prefix"  "[tekhton]"       "$output"
assert_contains "info emits message body"     "hello from CLI"   "$output"

# error level routes through same path with its own prefix
err_out=$(LOG_FILE="" _out_emit error "boom" 2>/dev/null)
assert_contains "error emits [✗] prefix" "[✗]"   "$err_out"
assert_contains "error emits message"   "boom"  "$err_out"

# =============================================================================
echo "=== TC-OB-06: _out_emit in TUI mode writes nothing to stdout ==="
_TUI_ACTIVE=true
tui_log="${TMPDIR_TEST}/tui_emit.log"
: > "$tui_log"
stdout=$(LOG_FILE="$tui_log" _out_emit info "silent in TUI" 2>/dev/null)
assert_eq "TUI mode: stdout is empty" "" "$stdout"
file_content=$(cat "$tui_log")
assert_contains "TUI mode: message in LOG_FILE" "silent in TUI" "$file_content"
_TUI_ACTIVE=false

# =============================================================================
echo "=== TC-OB-07: log() wrapper preserves pre-M99 output format ==="
_TUI_ACTIVE=false
output=$(LOG_FILE="" log "test message" 2>/dev/null)
assert_contains "log() prefix preserved"  "[tekhton]"     "$output"
assert_contains "log() message preserved" "test message"  "$output"

# =============================================================================
echo "=== TC-OB-08: warn() wrapper produces [!] prefix ==="
_TUI_ACTIVE=false
output=$(LOG_FILE="" warn "bad thing" 2>/dev/null)
assert_contains "warn() prefix preserved" "[!]"        "$output"
assert_contains "warn() message preserved" "bad thing" "$output"

# =============================================================================
echo "=== TC-OB-09: header() produces a bordered banner with title ==="
_TUI_ACTIVE=false
output=$(LOG_FILE="" header "Section" 2>/dev/null)
assert_contains "header has border glyph" "══"     "$output"
assert_contains "header has title"        "Section" "$output"

# =============================================================================
echo "=== TC-OB-10: NO_COLOR=1 suppresses ANSI escapes in _out_emit output ==="
# Reload output.sh with NO_COLOR so the module sees the setting at sourcing
# time — some downstream formatters capture color vars at _out_color() call
# time and would otherwise hold onto the ANSI bytes from the outer test env.
_TUI_ACTIVE=false
# shellcheck disable=SC2034
NO_COLOR=1
# shellcheck disable=SC2034
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""

output=$(LOG_FILE="" _out_emit info "plain output" 2>/dev/null)
# Verify no ESC byte (0x1b) appears in the captured output.
if printf '%s' "$output" | grep -qP '\x1b' 2>/dev/null; then
    fail "NO_COLOR=1 ANSI escape leak" "ESC byte present in _out_emit output"
else
    pass "NO_COLOR=1 produces no ESC bytes in _out_emit output"
fi
assert_contains "NO_COLOR preserves message body" "plain output" "$output"

unset NO_COLOR

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
