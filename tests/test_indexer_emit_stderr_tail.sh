#!/usr/bin/env bash
# =============================================================================
# test_indexer_emit_stderr_tail.sh — Unit tests for _indexer_emit_stderr_tail()
#
# Tests the new M122 helper that surfaces the last few lines of repo_map.py
# stderr in the warning block when run_repo_map encounters a fatal exit.
#
# Tests:
#   1. Non-existent file → no output, returns 0
#   2. Empty file → no output, returns 0
#   3. File with 3 lines → header + all 3 lines emitted (≤5 lines)
#   4. File with 8 lines → header + only last 5 lines emitted (tail behaviour)
#   5. Each emitted line is prefixed with "[indexer]   "
#   6. Header line is exactly "[indexer] Last lines of repo_map.py stderr:"
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# --- Stubs for functions referenced by indexer_helpers.sh -------------------
log()         { :; }
log_verbose() { :; }

# Capture warn calls so tests can assert on them.
_WARN_OUTPUT=""
warn() { _WARN_OUTPUT="${_WARN_OUTPUT}${*}"$'\n'; }

# Minimal exports required by indexer_helpers.sh at source time.
export PROJECT_DIR="$WORK_DIR"
export REPO_MAP_CACHE_DIR=".claude/index"

# --- Source the library under test ------------------------------------------
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"

# --- Test 1: non-existent file → silent return 0 ----------------------------
echo "=== Test 1: non-existent file → silent, returns 0 ==="
_WARN_OUTPUT=""
_indexer_emit_stderr_tail "${WORK_DIR}/does_not_exist.txt"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "returns 0 for non-existent file"
else
    fail "expected exit 0, got $rc"
fi
if [[ -z "$_WARN_OUTPUT" ]]; then
    pass "no warn output for non-existent file"
else
    fail "unexpected warn output: $_WARN_OUTPUT"
fi

# --- Test 2: empty file → silent return 0 ------------------------------------
echo "=== Test 2: empty file → silent, returns 0 ==="
EMPTY_FILE="${WORK_DIR}/empty.txt"
: > "$EMPTY_FILE"
_WARN_OUTPUT=""
_indexer_emit_stderr_tail "$EMPTY_FILE"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "returns 0 for empty file"
else
    fail "expected exit 0, got $rc"
fi
if [[ -z "$_WARN_OUTPUT" ]]; then
    pass "no warn output for empty file"
else
    fail "unexpected warn output: $_WARN_OUTPUT"
fi

# --- Test 3: file with 3 lines → header + 3 prefixed lines ------------------
echo "=== Test 3: file with 3 lines → all 3 emitted ==="
SHORT_FILE="${WORK_DIR}/short.txt"
printf 'line alpha\nline beta\nline gamma\n' > "$SHORT_FILE"
_WARN_OUTPUT=""
_indexer_emit_stderr_tail "$SHORT_FILE"
# Check header
if echo "$_WARN_OUTPUT" | grep -q "\[indexer\] Last lines of repo_map.py stderr:"; then
    pass "header line emitted"
else
    fail "header line missing from warn output"
fi
# Check all 3 lines appear (prefixed)
if echo "$_WARN_OUTPUT" | grep -q "\[indexer\]   line alpha"; then
    pass "line 1 emitted with correct prefix"
else
    fail "line 1 missing or not prefixed; output: $_WARN_OUTPUT"
fi
if echo "$_WARN_OUTPUT" | grep -q "\[indexer\]   line beta"; then
    pass "line 2 emitted with correct prefix"
else
    fail "line 2 missing or not prefixed; output: $_WARN_OUTPUT"
fi
if echo "$_WARN_OUTPUT" | grep -q "\[indexer\]   line gamma"; then
    pass "line 3 emitted with correct prefix"
else
    fail "line 3 missing or not prefixed; output: $_WARN_OUTPUT"
fi

# --- Test 4: file with 8 lines → only last 5 lines emitted -------------------
echo "=== Test 4: file with 8 lines → only last 5 emitted ==="
LONG_FILE="${WORK_DIR}/long.txt"
{
    echo "first 1"
    echo "first 2"
    echo "first 3"
    echo "line 4"
    echo "line 5"
    echo "line 6"
    echo "line 7"
    echo "line 8"
} > "$LONG_FILE"
_WARN_OUTPUT=""
_indexer_emit_stderr_tail "$LONG_FILE"
# Lines 1-3 must NOT appear (they are before the tail window).
if echo "$_WARN_OUTPUT" | grep -q "\[indexer\]   first 1"; then
    fail "line 1 (outside tail window) should not be emitted"
else
    pass "line 1 correctly excluded by tail"
fi
if echo "$_WARN_OUTPUT" | grep -q "\[indexer\]   first 2"; then
    fail "line 2 (outside tail window) should not be emitted"
else
    pass "line 2 correctly excluded by tail"
fi
if echo "$_WARN_OUTPUT" | grep -q "\[indexer\]   first 3"; then
    fail "line 3 (outside tail window) should not be emitted"
else
    pass "line 3 correctly excluded by tail"
fi
# Lines 4-8 must appear.
for n in 4 5 6 7 8; do
    if echo "$_WARN_OUTPUT" | grep -q "\[indexer\]   line ${n}"; then
        pass "line $n (inside tail window) emitted"
    else
        fail "line $n (inside tail window) missing; output: $_WARN_OUTPUT"
    fi
done

# --- Test 5: prefix is exactly "[indexer]   " (3 spaces) ---------------------
echo "=== Test 5: each content line has the exact '[indexer]   ' prefix ==="
PREFIX_FILE="${WORK_DIR}/prefix_check.txt"
echo "Warning: no files could be parsed" > "$PREFIX_FILE"
_WARN_OUTPUT=""
_indexer_emit_stderr_tail "$PREFIX_FILE"
# The sed rule is: s/^/[indexer]   / — three spaces after the closing ]
if echo "$_WARN_OUTPUT" | grep -Fq "[indexer]   Warning: no files could be parsed"; then
    pass "content line prefixed with exactly '[indexer]   ' (3 spaces)"
else
    fail "content line prefix wrong; output: $_WARN_OUTPUT"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
