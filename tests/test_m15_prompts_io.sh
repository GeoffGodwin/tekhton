#!/usr/bin/env bash
# Test: lib/prompts_io.sh — _wrap_file_content, _safe_read_file, load_intake_template_vars
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stub warn so _safe_read_file can emit its over-limit warning without
# requiring the full common.sh stack. Writes to a file so the message is
# visible from the parent shell even when warn() fires inside a $() subshell.
WARN_FILE="${TMPDIR}/warn_output.txt"
warn() { echo "$*" >> "$WARN_FILE"; }

# Source the library under test
# shellcheck source=../lib/prompts_io.sh
source "${TEKHTON_HOME}/lib/prompts_io.sh"

# =============================================================================
# _wrap_file_content
# =============================================================================
echo "=== _wrap_file_content ==="

result=$(_wrap_file_content "ARCH" "some content here")
if echo "$result" | grep -q "BEGIN FILE CONTENT: ARCH"; then
    pass "_wrap_file_content: adds BEGIN delimiter with label"
else
    fail "_wrap_file_content: missing BEGIN delimiter; got: $result"
fi

if echo "$result" | grep -q "END FILE CONTENT: ARCH"; then
    pass "_wrap_file_content: adds END delimiter with label"
else
    fail "_wrap_file_content: missing END delimiter; got: $result"
fi

if echo "$result" | grep -q "some content here"; then
    pass "_wrap_file_content: preserves content between delimiters"
else
    fail "_wrap_file_content: content missing from output; got: $result"
fi

# Empty content should return empty, no delimiters
empty_result=$(_wrap_file_content "LABEL" "")
if [ -z "$empty_result" ]; then
    pass "_wrap_file_content: empty content returns empty (no delimiters)"
else
    fail "_wrap_file_content: expected empty for empty input, got: $empty_result"
fi

# =============================================================================
# _safe_read_file
# =============================================================================
echo "=== _safe_read_file ==="

# Happy path: existing file returns its content
echo "hello world" > "${TMPDIR}/test.txt"
content=$(_safe_read_file "${TMPDIR}/test.txt" "TEST")
if [ "$content" = "hello world" ]; then
    pass "_safe_read_file: reads file content correctly"
else
    fail "_safe_read_file: expected 'hello world', got: $content"
fi

# Missing file returns empty (no error exit)
missing=$(_safe_read_file "${TMPDIR}/nonexistent.txt" "MISSING")
if [ -z "$missing" ]; then
    pass "_safe_read_file: missing file returns empty string"
else
    fail "_safe_read_file: expected empty for missing file, got: $missing"
fi

# File exceeding size limit: warn emitted, returns empty
big_file="${TMPDIR}/big.txt"
# Write just over 100 bytes, use a 50-byte limit to trigger the guard
printf '%0.s.' {1..200} > "$big_file"
: > "$WARN_FILE"  # reset before this sub-test
oversized=$(_safe_read_file "$big_file" "BIG" 50)
if [ -z "$oversized" ]; then
    pass "_safe_read_file: oversized file returns empty"
else
    fail "_safe_read_file: expected empty for oversized file, got content of length ${#oversized}"
fi
if grep -q "exceeds size limit" "$WARN_FILE" 2>/dev/null; then
    pass "_safe_read_file: oversized file emits size-limit warning"
else
    fail "_safe_read_file: expected size-limit warning, got nothing in warn output"
fi

# Multi-line file
printf 'line1\nline2\nline3\n' > "${TMPDIR}/multi.txt"
multi=$(_safe_read_file "${TMPDIR}/multi.txt")
if echo "$multi" | grep -q "line2"; then
    pass "_safe_read_file: multi-line file content preserved"
else
    fail "_safe_read_file: multi-line content missing; got: $multi"
fi

# =============================================================================
# load_intake_template_vars
# =============================================================================
echo "=== load_intake_template_vars ==="

# With no INTAKE_REPORT_FILE set, INTAKE_REPORT_CONTENT should be empty
unset INTAKE_REPORT_FILE 2>/dev/null || true
load_intake_template_vars
if [ -z "${INTAKE_REPORT_CONTENT:-}" ]; then
    pass "load_intake_template_vars: INTAKE_REPORT_CONTENT empty when no report file"
else
    fail "load_intake_template_vars: expected empty INTAKE_REPORT_CONTENT, got: ${INTAKE_REPORT_CONTENT}"
fi

# With a real file, INTAKE_REPORT_CONTENT is populated
intake_file="${TMPDIR}/INTAKE_REPORT.md"
printf '# Intake Report\nVerdict: APPROVED\n' > "$intake_file"
export INTAKE_REPORT_FILE="$intake_file"
load_intake_template_vars
if echo "${INTAKE_REPORT_CONTENT:-}" | grep -q "Verdict: APPROVED"; then
    pass "load_intake_template_vars: INTAKE_REPORT_CONTENT populated from file"
else
    fail "load_intake_template_vars: expected file content in INTAKE_REPORT_CONTENT, got: ${INTAKE_REPORT_CONTENT:-}"
fi

# INTAKE_TWEAKS_BLOCK and INTAKE_HISTORY_BLOCK are exported (defaulting to empty)
load_intake_template_vars
if [[ -v INTAKE_TWEAKS_BLOCK && -v INTAKE_HISTORY_BLOCK ]]; then
    pass "load_intake_template_vars: INTAKE_TWEAKS_BLOCK and INTAKE_HISTORY_BLOCK are exported"
else
    fail "load_intake_template_vars: expected INTAKE_TWEAKS_BLOCK and INTAKE_HISTORY_BLOCK to be set"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
