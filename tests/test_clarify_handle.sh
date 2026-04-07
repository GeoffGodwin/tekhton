#!/usr/bin/env bash
# Test: handle_clarifications() — file creation, write format, non-blocking logging,
#       and abort behavior when no terminal is available.
#
# Note on stdin: handle_clarifications reads answers via "read < $input_fd" inside a
# "while ... done < $blocking_file" loop. The while-loop redirect replaces fd 0 with
# the blocking file, so /dev/stdin would re-open the blocking file and read question
# text as answers — a known bug that was fixed. Now, when /dev/tty is unavailable
# (TEKHTON_TEST_MODE or non-interactive context), handle_clarifications returns 1
# (abort) instead of producing garbage answers.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME
export TEKHTON_SESSION_DIR="$TMPDIR"
export TEKHTON_TEST_MODE="true"

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
_safe_read_file() { cat "$1" 2>/dev/null || true; }

BOLD=""
NC=""

# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true

log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# shellcheck source=../lib/clarify.sh
source "${TEKHTON_HOME}/lib/clarify.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

CLARIFICATIONS_FILE="${TMPDIR}/CLARIFICATIONS.md"
BLOCKING_FILE="${TEKHTON_SESSION_DIR}/clarify_blocking.txt"
NB_FILE="${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"

# ============================================================
# Test: no blocking file — returns 0 immediately
# ============================================================
echo "=== handle_clarifications — no blocking file ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"

if handle_clarifications 2>/dev/null; then
    pass "Returns 0 when no blocking file present"
else
    fail "Should return 0 when no blocking items"
fi

if [[ ! -f "$CLARIFICATIONS_FILE" ]]; then
    pass "CLARIFICATIONS.md not created when no blocking items"
else
    fail "CLARIFICATIONS.md should not be created when no blocking items"
fi

# ============================================================
# Test: empty blocking file (0 bytes) — returns 0 without prompting
# ============================================================
echo "=== handle_clarifications — empty blocking file ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
touch "$BLOCKING_FILE"  # empty file

if handle_clarifications 2>/dev/null; then
    pass "Returns 0 for empty blocking file"
else
    fail "Should return 0 for empty blocking file"
fi

if [[ ! -f "$CLARIFICATIONS_FILE" ]]; then
    pass "CLARIFICATIONS.md not created for empty blocking file"
else
    fail "CLARIFICATIONS.md should not be created for empty blocking file"
fi

# ============================================================
# Test: non-blocking items only — logs and returns 0, no CLARIFICATIONS.md
# ============================================================
echo "=== handle_clarifications — non-blocking only ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
echo "Is Redis preferred for caching?" > "$NB_FILE"

if handle_clarifications 2>/dev/null; then
    pass "Returns 0 when only non-blocking items"
else
    fail "Should return 0 with only non-blocking items"
fi

if [[ ! -f "$CLARIFICATIONS_FILE" ]]; then
    pass "CLARIFICATIONS.md not created for non-blocking only"
else
    fail "CLARIFICATIONS.md should not be created for non-blocking only"
fi

# ============================================================
# Test: blocking items without /dev/tty — returns 1 (abort)
# ============================================================
echo "=== handle_clarifications — no terminal aborts ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
echo "Which database should we use?" > "$BLOCKING_FILE"

# In test mode, /dev/tty is not used → handle_clarifications returns 1
if handle_clarifications 2>/dev/null; then
    fail "Should return 1 when no terminal available for blocking items"
else
    pass "Returns 1 (abort) when no terminal available"
fi

# CLARIFICATIONS.md should NOT be created (aborted before writing)
if [[ ! -f "$CLARIFICATIONS_FILE" ]]; then
    pass "CLARIFICATIONS.md not created when no terminal (correct abort)"
else
    fail "CLARIFICATIONS.md should not be created on abort"
fi

# ============================================================
# Test: multiple blocking questions without /dev/tty — returns 1
# ============================================================
echo "=== handle_clarifications — multiple questions, no terminal ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
printf "Question one?\nQuestion two?\n" > "$BLOCKING_FILE"

if handle_clarifications 2>/dev/null; then
    fail "Should return 1 with multiple blocking questions and no terminal"
else
    pass "Returns 1 (abort) for multiple blocking questions without terminal"
fi

# ============================================================
# Test: non-blocking + blocking combined without /dev/tty — returns 1
# ============================================================
echo "=== handle_clarifications — mixed nb+blocking, no terminal ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
echo "Non-blocking assumption" > "$NB_FILE"
echo "Blocking question?" > "$BLOCKING_FILE"

if handle_clarifications 2>/dev/null; then
    fail "Should return 1 when blocking items present without terminal"
else
    pass "Returns 1 (abort) for mixed items without terminal"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
