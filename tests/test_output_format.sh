#!/usr/bin/env bash
# tests/test_output_format.sh — Unit tests for lib/output_format.sh
#
# Covers:
#   - _out_color: NO_COLOR suppression and passthrough
#   - _out_repeat: character repetition including edge cases
#   - _out_term_width: terminal width clamping (min/max)
#   - out_banner: title and key/value pairs appear in NO_COLOR output
#   - out_section: title appears in NO_COLOR output
#   - out_kv: normal/warn/error severities in NO_COLOR mode
#   - out_hr: horizontal rule with and without label
#   - out_progress: fill calculation for 0%, 50%, 100%, and max=0
#   - out_action_item: severity prefixes and [CRITICAL] suffix
#   - _out_append_action_item: JSON array construction and appending
#   - _out_json_escape: backslash, quote, newline, tab, carriage-return
#   - bash -n and shellcheck on lib/output_format.sh
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Stubs for TUI dependencies (must be defined before sourcing output.sh) ───
# _out_emit in output.sh calls _tui_notify unconditionally at the end.
# _tui_strip_ansi is called by out_msg in TUI mode (not exercised here, but
# must exist to avoid unbound-variable errors when output.sh is sourced).
_tui_notify()     { :; }
_tui_strip_ansi() { printf '%s' "${1:-}"; }

# Force non-TUI mode so all tests exercise the CLI output path.
export _TUI_ACTIVE=false

# Set ANSI color codes to real values so _out_color suppression tests are
# meaningful — with NO_COLOR set these should vanish from output.
export BOLD='\033[1m'
export NC='\033[0m'
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'

# Fix COLUMNS so _out_term_width is deterministic (avoids tput in CI).
export COLUMNS=60

# Source output.sh first — provides the _OUT_CTX associative array that
# _out_append_action_item reads and writes.
# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"

# Source the module under test.
# shellcheck source=../lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

# ── Test infrastructure ──────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILURES+=("$1")
    echo "  FAIL: $1"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label (expected='${expected}' actual='${actual}')"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label (expected '${needle}' in: '${haystack}')"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label (unexpected '${needle}' found in: '${haystack}')"
    fi
}

# contains_ansi: return 0 if string contains an ESC (\033) character.
contains_ansi() { [[ "$1" == *$'\033'* ]]; }

# strip_ansi: remove ANSI CSI sequences for plain-text comparison.
strip_ansi() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

echo "=== test_output_format.sh ==="

# ════════════════════════════════════════
# _out_color
# ════════════════════════════════════════

# 1. Returns empty when NO_COLOR is set (evaluated at call time).
result=$(NO_COLOR=1 _out_color "${BOLD}")
assert_eq "_out_color: empty when NO_COLOR=1" "" "$result"

# 2. Returns the ANSI code as actual ESC bytes when NO_COLOR is not set.
# _out_color uses printf '%b' so single-quoted color literals from common.sh
# (e.g. BOLD='\033[1m') are emitted as real ESC sequences, not the literal
# 4-character backslash-octal form.
unset NO_COLOR
result=$(_out_color "${BOLD}")
expected=$(printf '%b' "${BOLD}")
assert_eq "_out_color: emits interpreted ESC bytes when NO_COLOR unset" "$expected" "$result"
if contains_ansi "$result"; then
    pass "_out_color: result contains real ESC byte (0x1b)"
else
    fail "_out_color: result missing real ESC byte (got literal '${result}')"
fi
assert_not_contains "_out_color: result has no literal \\\\033" '\033' "$result"

# 3. Returns empty string for empty input (no crash).
result=$(_out_color "")
assert_eq "_out_color: empty input → empty output" "" "$result"

# ════════════════════════════════════════
# _out_repeat
# ════════════════════════════════════════

# 4. Correct output for N=5.
result=$(_out_repeat "─" 5)
assert_eq "_out_repeat: 5 dashes" "─────" "$result"

# 5. Empty output for N=0 (no chars printed).
result=$(_out_repeat "─" 0)
assert_eq "_out_repeat: N=0 → empty" "" "$result"

# 6. Single char for N=1.
result=$(_out_repeat "X" 1)
assert_eq "_out_repeat: N=1 → single char" "X" "$result"

# ════════════════════════════════════════
# _out_term_width
# ════════════════════════════════════════

# 7. Uses COLUMNS when it is in the valid range.
result=$(COLUMNS=60 _out_term_width)
assert_eq "_out_term_width: COLUMNS=60 → 60" "60" "$result"

# 8. Clamps to max 80 when COLUMNS is large.
result=$(COLUMNS=200 _out_term_width)
assert_eq "_out_term_width: COLUMNS=200 → clamp to 80" "80" "$result"

# 9. Falls back to default 60 when COLUMNS is below minimum (< 20).
result=$(COLUMNS=5 _out_term_width)
assert_eq "_out_term_width: COLUMNS=5 → default 60" "60" "$result"

# 10. Uses default 60 when COLUMNS is empty.
result=$(COLUMNS="" _out_term_width)
# When COLUMNS is empty tput may or may not be available; clamp ensures >=20 <=80.
if [[ "$result" -ge 20 && "$result" -le 80 ]]; then
    pass "_out_term_width: empty COLUMNS → valid range 20..80 (got ${result})"
else
    fail "_out_term_width: empty COLUMNS → '${result}' not in 20..80"
fi

# ════════════════════════════════════════
# out_banner (NO_COLOR mode)
# ════════════════════════════════════════

# 11. Title appears in output.
export NO_COLOR=1
output=$(out_banner "My Pipeline Banner")
stripped=$(strip_ansi "$output")
assert_contains "out_banner: title present in output" "My Pipeline Banner" "$stripped"

# 12. No ANSI escape sequences in output when NO_COLOR=1.
if ! contains_ansi "$output"; then
    pass "out_banner: no ANSI sequences when NO_COLOR=1"
else
    fail "out_banner: ANSI sequences found despite NO_COLOR=1"
fi

# 13. Key/value pairs appear when provided.
output=$(out_banner "Banner Title" "Version" "3.0.0" "Task" "build feature")
stripped=$(strip_ansi "$output")
assert_contains "out_banner: key label appears" "Version:" "$stripped"
assert_contains "out_banner: key value appears" "3.0.0" "$stripped"
assert_contains "out_banner: second key label appears" "Task:" "$stripped"

# ════════════════════════════════════════
# out_section (NO_COLOR mode)
# ════════════════════════════════════════

# 14. Title appears in output.
output=$(out_section "Build Results")
stripped=$(strip_ansi "$output")
assert_contains "out_section: title present in output" "Build Results" "$stripped"

# 15. No ANSI escape sequences when NO_COLOR=1.
if ! contains_ansi "$output"; then
    pass "out_section: no ANSI sequences when NO_COLOR=1"
else
    fail "out_section: ANSI sequences found despite NO_COLOR=1"
fi

# ════════════════════════════════════════
# out_kv (NO_COLOR mode)
# ════════════════════════════════════════

# 16. Normal severity: label and value present, no [CRITICAL].
output=$(out_kv "Status" "running")
stripped=$(strip_ansi "$output")
assert_contains "out_kv normal: label present" "Status:" "$stripped"
assert_contains "out_kv normal: value present" "running" "$stripped"
assert_not_contains "out_kv normal: no [CRITICAL] suffix" "[CRITICAL]" "$stripped"

# 17. Warn severity: label and value present, no [CRITICAL].
output=$(out_kv "Alert" "something happened" "warn")
stripped=$(strip_ansi "$output")
assert_contains "out_kv warn: label present" "Alert:" "$stripped"
assert_contains "out_kv warn: value present" "something happened" "$stripped"
assert_not_contains "out_kv warn: no [CRITICAL] suffix" "[CRITICAL]" "$stripped"

# 18. Error severity: label, value, and [CRITICAL] suffix all present.
output=$(out_kv "Failure" "pipeline broken" "error")
stripped=$(strip_ansi "$output")
assert_contains "out_kv error: label present" "Failure:" "$stripped"
assert_contains "out_kv error: value present" "pipeline broken" "$stripped"
assert_contains "out_kv error: [CRITICAL] suffix" "[CRITICAL]" "$stripped"

# ════════════════════════════════════════
# out_hr (NO_COLOR mode)
# ════════════════════════════════════════

# 19. Without label: non-empty line of dashes.
output=$(out_hr)
stripped=$(strip_ansi "$output")
if [[ -n "${stripped// /}" ]]; then
    pass "out_hr: non-empty output without label"
else
    fail "out_hr: empty output without label"
fi

# 20. With label: label appears in output.
output=$(out_hr "Section Label")
stripped=$(strip_ansi "$output")
assert_contains "out_hr with label: label present" "Section Label" "$stripped"

# ════════════════════════════════════════
# out_progress — fill calculation (primary reviewer concern)
# ════════════════════════════════════════

# bar_w=20 for all tests so arithmetic is straightforward.

# 21. 0% fill: no filled chars (█), all empty chars (░).
output=$(out_progress "Loading" 0 10 20)
stripped=$(strip_ansi "$output")
assert_contains "out_progress 0/10: label present" "Loading" "$stripped"
assert_contains "out_progress 0/10: count 0/10" "0/10" "$stripped"
assert_not_contains "out_progress 0/10: zero filled chars" "█" "$stripped"
assert_contains "out_progress 0/10: 20 empty chars" "░░░░░░░░░░░░░░░░░░░░" "$stripped"

# 22. 50% fill: 10 filled + 10 empty (5*20/10 = 10).
output=$(out_progress "Loading" 5 10 20)
stripped=$(strip_ansi "$output")
assert_contains "out_progress 5/10: 10 filled chars" "██████████" "$stripped"
assert_contains "out_progress 5/10: 10 empty chars" "░░░░░░░░░░" "$stripped"
assert_contains "out_progress 5/10: count 5/10" "5/10" "$stripped"
# Also confirm exactly 10 filled (not 11+): 11 filled would be ███████████.
assert_not_contains "out_progress 5/10: not 11 filled" "███████████" "$stripped"

# 23. 100% fill: all 20 chars filled, no empty chars.
output=$(out_progress "Done" 10 10 20)
stripped=$(strip_ansi "$output")
assert_contains "out_progress 10/10: 20 filled chars" "████████████████████" "$stripped"
assert_not_contains "out_progress 10/10: no empty chars" "░" "$stripped"
assert_contains "out_progress 10/10: count 10/10" "10/10" "$stripped"

# 24. max=0: does not crash; output contains 0/0.
set +e
output=$(out_progress "Idle" 0 0 20)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    pass "out_progress max=0: does not crash"
else
    fail "out_progress max=0: crashed with rc=${rc}"
fi
stripped=$(strip_ansi "$output")
assert_contains "out_progress max=0: shows 0/0" "0/0" "$stripped"

# 25. cur > max: clamps filled to bar_w, no empty chars.
output=$(out_progress "Over" 15 10 20)
stripped=$(strip_ansi "$output")
assert_not_contains "out_progress cur>max: no empty chars" "░" "$stripped"
assert_contains "out_progress cur>max: count 15/10" "15/10" "$stripped"

# ════════════════════════════════════════
# out_action_item (NO_COLOR mode)
# ════════════════════════════════════════

# 26. Normal severity: ℹ prefix, message present, no [CRITICAL].
output=$(out_action_item "Check your config" "normal")
stripped=$(strip_ansi "$output")
assert_contains "out_action_item normal: ℹ prefix" "ℹ" "$stripped"
assert_contains "out_action_item normal: message present" "Check your config" "$stripped"
assert_not_contains "out_action_item normal: no [CRITICAL]" "[CRITICAL]" "$stripped"

# 27. Warning severity: ⚠ prefix, message present, no [CRITICAL].
output=$(out_action_item "Review dependencies" "warning")
stripped=$(strip_ansi "$output")
assert_contains "out_action_item warning: ⚠ prefix" "⚠" "$stripped"
assert_contains "out_action_item warning: message present" "Review dependencies" "$stripped"
assert_not_contains "out_action_item warning: no [CRITICAL]" "[CRITICAL]" "$stripped"

# 28. Critical severity: ✗ prefix, message present, [CRITICAL] suffix.
output=$(out_action_item "Build failed" "critical")
stripped=$(strip_ansi "$output")
assert_contains "out_action_item critical: ✗ prefix" "✗" "$stripped"
assert_contains "out_action_item critical: message present" "Build failed" "$stripped"
assert_contains "out_action_item critical: [CRITICAL] suffix" "[CRITICAL]" "$stripped"

# ════════════════════════════════════════
# _out_append_action_item — JSON construction
# ════════════════════════════════════════

# Reset the context store before JSON tests.
_OUT_CTX[action_items]=""

# 29. First call: creates a valid JSON array with msg and severity fields.
_out_append_action_item "First action" "normal"
result="${_OUT_CTX[action_items]}"
assert_contains "_out_append_action_item 1st: starts with [" "[" "${result:0:1}"
assert_contains "_out_append_action_item 1st: ends with ]" "]" "${result: -1}"
assert_contains "_out_append_action_item 1st: msg field" '"msg":"First action"' "$result"
assert_contains "_out_append_action_item 1st: severity field" '"severity":"normal"' "$result"

# 30. Second call: appends new object; first item is retained.
_out_append_action_item "Second action" "warning"
result="${_OUT_CTX[action_items]}"
assert_contains "_out_append_action_item 2nd: first item retained" '"msg":"First action"' "$result"
assert_contains "_out_append_action_item 2nd: second item added" '"msg":"Second action"' "$result"
assert_contains "_out_append_action_item 2nd: second severity" '"severity":"warning"' "$result"

# 31. Special chars in msg are JSON-escaped so the array stays valid.
_OUT_CTX[action_items]=""
_out_append_action_item 'Fix "critical" issue' "critical"
result="${_OUT_CTX[action_items]}"
assert_contains "_out_append_action_item: quotes escaped in msg" '\"critical\"' "$result"

# ════════════════════════════════════════
# _out_json_escape — special character escaping
# ════════════════════════════════════════

# 32. Escapes double quotes.
result=$(_out_json_escape 'say "hello"')
assert_eq '_out_json_escape: double quotes' 'say \"hello\"' "$result"

# 33. Escapes backslashes (backslash must be doubled).
result=$(_out_json_escape 'path\to\file')
assert_eq '_out_json_escape: backslashes' 'path\\to\\file' "$result"

# 34. Escapes newlines as \n.
result=$(_out_json_escape $'line1\nline2')
assert_eq '_out_json_escape: newline' 'line1\nline2' "$result"

# 35. Escapes tab characters as \t.
result=$(_out_json_escape $'col1\tcol2')
assert_eq '_out_json_escape: tab' 'col1\tcol2' "$result"

# 36. Escapes carriage returns as \r.
result=$(_out_json_escape $'line\r')
assert_eq '_out_json_escape: carriage return' 'line\r' "$result"

# 37. Passthrough for plain strings (no escaping needed).
result=$(_out_json_escape "plain text")
assert_eq '_out_json_escape: plain text unchanged' "plain text" "$result"

# ════════════════════════════════════════
# Syntax and static analysis
# ════════════════════════════════════════

# 38. bash -n syntax check.
bash -n "${TEKHTON_HOME}/lib/output_format.sh" && rc=0 || rc=$?
assert_eq "bash -n lib/output_format.sh" "0" "$rc"

# 39. shellcheck (skip gracefully when not installed).
if command -v shellcheck &>/dev/null; then
    shellcheck "${TEKHTON_HOME}/lib/output_format.sh" && rc=0 || rc=$?
    assert_eq "shellcheck lib/output_format.sh" "0" "$rc"
else
    echo "  SKIP: shellcheck not available"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: Passed=${PASS} Failed=${FAIL}"
if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
fi

[[ "$FAIL" -eq 0 ]]
