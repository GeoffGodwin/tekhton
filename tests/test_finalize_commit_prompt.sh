#!/usr/bin/env bash
# =============================================================================
# test_finalize_commit_prompt.sh — Regression for the M25 autoskip bug.
#
# M25's pipeline finished, displayed the y/e/n prompt, the read returned
# empty (cause: TUI sidecar / claude CLI consuming stdin during a 2.6-hour
# run, or a stray Enter), and the case statement fell through to "skip"
# silently — 28 files of Notes/Drift/Clarify port work stranded
# uncommitted. _prompt_commit_choice now retries on empty input and warns
# loudly on the final fallback.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stub the bash logging primitives. Tests assert on returned values, not
# on the prompt text itself.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=lib/finalize_commit_prompt.sh
source "${TEKHTON_HOME}/lib/finalize_commit_prompt.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then pass "$name"
    else fail "$name — want '${want}', got '${got}'"
    fi
}

echo "=== Suite 1: explicit choices via stdin pipe ==="
result=$(printf 'y\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "1.1 'y' on first attempt returns y" "y" "$result"

result=$(printf 'e\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "1.2 'e' returns e" "e" "$result"

result=$(printf 'n\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "1.3 'n' returns n" "n" "$result"

echo "=== Suite 2: whitespace trim ==="
result=$(printf '  y  \n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "2.1 '  y  ' trims to y" "y" "$result"

result=$(printf 'y\r\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "2.2 'y\\r\\n' (Windows line ending) trims to y" "y" "$result"

echo "=== Suite 3: empty input retries ==="
# Single empty line then a real choice — should retry once and return.
result=$(printf '\ny\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "3.1 empty then y returns y on attempt 2" "y" "$result"

# Two empty lines then a real choice — retry twice.
result=$(printf '\n\nn\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "3.2 two empty then n returns n on attempt 3" "n" "$result"

echo "=== Suite 4: all-empty input defaults to skip ==="
# Three empty lines — fully drain, no real input. Caller used to treat
# this as "skip" silently; the regression fix makes it explicit but the
# end state must still be "n" (skip) so the pipeline doesn't hang on a
# contaminated terminal.
result=$(printf '\n\n\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "4.1 three empty inputs default to n" "n" "$result"

# EOF (no input at all) — same default.
result=$(printf '' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>/dev/null)
assert_eq "4.2 EOF on stdin defaults to n" "n" "$result"

echo "=== Suite 5: prompt output goes to stderr, choice to stdout ==="
# Captures stdout (the returned choice) AND stderr (the prompt text)
# separately. The user-visible prompt must NOT pollute the captured
# choice — that's why the helper redirects log/echo to >&2.
stdout=$(printf 'y\n' | TEKHTON_TEST_FORCE_STDIN=1 _prompt_commit_choice 2>"$TMP/stderr.txt")
stderr=$(cat "$TMP/stderr.txt")
assert_eq "5.1 stdout contains only the choice" "y" "$stdout"
if [[ -z "$stderr" ]]; then
    fail "5.2 stderr should contain prompt text"
else
    pass "5.2 stderr has prompt text (${#stderr} chars)"
fi

echo "=== Suite 6: read timeout returns SKIP without hanging ==="
# Regression for M27.2 hang: when stdin is connected but no input is
# arriving (test contexts where /dev/tty is inherited from the user's
# terminal but no human is typing), `read` would block forever.
# Now bounded by TEKHTON_PROMPT_TIMEOUT_SECS. Cap to 2s for the test so
# the suite stays fast.
#
# Use a FIFO opened in rw mode (3<>$_fifo). Read sees an open file with
# no data but also no EOF — exactly mimicking the M27.2 scenario where
# /dev/tty was connected but no human was typing. `read -t 2` times out
# instead of blocking.
_t6_fifo=$(mktemp -u "$TMP/prompt_fifo.XXXXXX")
mkfifo "$_t6_fifo"
exec 6<>"$_t6_fifo"
_t6_start=$(date +%s)
result=$(TEKHTON_TEST_FORCE_STDIN=1 TEKHTON_PROMPT_TIMEOUT_SECS=2 \
    _prompt_commit_choice <&6 2>/dev/null)
_t6_elapsed=$(( $(date +%s) - _t6_start ))
exec 6<&-
rm -f "$_t6_fifo"
assert_eq "6.1 timeout returns 'n' (default SKIP)" "n" "$result"
if (( _t6_elapsed < 5 )); then
    pass "6.2 returned within ${_t6_elapsed}s (timeout fired, did not block on the FIFO)"
else
    fail "6.2 timeout took too long: ${_t6_elapsed}s — should be ~2s, suggests timeout did not fire"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
