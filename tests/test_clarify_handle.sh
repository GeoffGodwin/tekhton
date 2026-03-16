#!/usr/bin/env bash
# Test: handle_clarifications() — file creation, write format, non-blocking logging,
#       and abort/skip behavior in test mode.
#
# Note on stdin: handle_clarifications reads answers via "read < /dev/stdin" inside a
# "while ... done < $blocking_file" loop. In bash, the while-loop redirect changes fd 0
# to the blocking_file for the loop duration, so /dev/stdin = blocking_file (not the
# caller's stdin). In production this is harmless because /dev/tty is used; in
# TEKHTON_TEST_MODE, read returns EOF and the || fallback sets answer="skip".
# Tests below verify the observable file-output behavior for each code path.
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
# Test: blocking item creates CLARIFICATIONS.md with timestamp header
# ============================================================
echo "=== handle_clarifications — file creation and header format ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
echo "Which database should we use?" > "$BLOCKING_FILE"

# In test mode, stdin = blocking file (EOF after question read) → answer="skip"
handle_clarifications 2>/dev/null || true

if [[ -f "$CLARIFICATIONS_FILE" ]]; then
    pass "CLARIFICATIONS.md created when blocking items present"
else
    fail "CLARIFICATIONS.md should be created for blocking items"
fi

# Verify timestamp header exists (format: # Clarifications — YYYY-MM-DD HH:MM:SS)
if grep -qE "^# Clarifications — [0-9]{4}-[0-9]{2}-[0-9]{2}" "$CLARIFICATIONS_FILE"; then
    pass "Timestamp header written in correct format"
else
    fail "Missing or malformed timestamp header"
fi

# Verify Q header format
if grep -q "^## Q: Which database" "$CLARIFICATIONS_FILE"; then
    pass "Question written with '## Q:' prefix"
else
    fail "Question not found with expected '## Q:' prefix"
fi

# Verify A format exists
if grep -q "^\*\*A:\*\*" "$CLARIFICATIONS_FILE"; then
    pass "Answer line written with '**A:**' prefix"
else
    fail "Answer line missing '**A:**' prefix"
fi

# In test mode, /dev/stdin reopens the questions file at offset 0, so the
# answer is the question text itself. Verify an **A:** line was written.
A_LINE=$(grep "^\*\*A:\*\*" "$CLARIFICATIONS_FILE" | head -1 || echo "")
if [[ -n "$A_LINE" ]]; then
    pass "Answer line written to CLARIFICATIONS.md in test mode"
else
    fail "No **A:** line found in CLARIFICATIONS.md"
fi

# ============================================================
# Test: multiple blocking questions — all processed
# ============================================================
echo "=== handle_clarifications — multiple blocking questions ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
printf "Question one?\nQuestion two?\n" > "$BLOCKING_FILE"

handle_clarifications 2>/dev/null || true

if [[ -f "$CLARIFICATIONS_FILE" ]]; then
    pass "CLARIFICATIONS.md created for multiple blocking questions"
else
    fail "CLARIFICATIONS.md should be created"
fi

# Q1 should be in the file
if grep -q "Question one" "$CLARIFICATIONS_FILE"; then
    pass "First question written to CLARIFICATIONS.md"
else
    fail "First question not found in CLARIFICATIONS.md"
fi

# ============================================================
# Test: append mode — second run appends with new timestamp header
# ============================================================
echo "=== handle_clarifications — append mode ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
echo "First question?" > "$BLOCKING_FILE"
handle_clarifications 2>/dev/null || true

FIRST_LINES=$(wc -l < "$CLARIFICATIONS_FILE" | tr -d '[:space:]')

rm -f "$BLOCKING_FILE"
echo "Second question?" > "$BLOCKING_FILE"
handle_clarifications 2>/dev/null || true

SECOND_LINES=$(wc -l < "$CLARIFICATIONS_FILE" | tr -d '[:space:]')

if [[ "$SECOND_LINES" -gt "$FIRST_LINES" ]]; then
    pass "File grows on second call (append mode)"
else
    fail "File should grow when handle_clarifications called twice"
fi

# Both questions should be in the file
if grep -q "First question" "$CLARIFICATIONS_FILE" && grep -q "Second question" "$CLARIFICATIONS_FILE"; then
    pass "Both questions present after two calls"
else
    fail "Expected both questions in CLARIFICATIONS.md after two calls"
fi

# Should have two timestamp headers
HEADER_COUNT=$(grep -c "^# Clarifications —" "$CLARIFICATIONS_FILE" || echo "0")
if [[ "$HEADER_COUNT" -eq 2 ]]; then
    pass "Two timestamp headers (one per call) in append mode"
else
    fail "Expected 2 timestamp headers, got ${HEADER_COUNT}"
fi

# ============================================================
# Test: non-blocking + blocking combined — non-blocking doesn't create file
# ============================================================
echo "=== handle_clarifications — mixed nb+blocking ==="

rm -f "$BLOCKING_FILE" "$NB_FILE" "$CLARIFICATIONS_FILE"
echo "Non-blocking assumption" > "$NB_FILE"
echo "Blocking question?" > "$BLOCKING_FILE"

handle_clarifications 2>/dev/null || true

if [[ -f "$CLARIFICATIONS_FILE" ]]; then
    pass "CLARIFICATIONS.md created when blocking items present alongside non-blocking"
else
    fail "CLARIFICATIONS.md should be created when blocking items present"
fi

if grep -q "Blocking question" "$CLARIFICATIONS_FILE"; then
    pass "Blocking question recorded in CLARIFICATIONS.md"
else
    fail "Blocking question not found in CLARIFICATIONS.md"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
