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

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
