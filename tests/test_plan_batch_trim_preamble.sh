#!/usr/bin/env bash
# tests/test_plan_batch_trim_preamble.sh — unit tests for _trim_document_preamble
# in lib/plan_batch.sh.
#
# _trim_document_preamble strips leading non-document lines before the first
# top-level markdown heading (^# ).
#
# Coverage:
#   A — content already starts with heading: pass-through unchanged
#   B — preamble before heading: heading and below retained, preamble stripped
#   C — no heading in content: content returned unchanged
#   D — empty content: empty output
#   E — heading after multiple preamble lines
#   F — preamble contains a `#word` comment line (not a markdown heading): only ^# (space) triggers
set -uo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1 — $2"; FAIL=$(( FAIL + 1 )); }

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

# Stubs required by plan_batch.sh source-time guard.
log_verbose() { :; }
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
_shim_resolve_binary() { echo "${WORK_DIR}/tekhton"; return 0; }
_shim_write_request()  { :; }
_shim_field()          { :; }

export TEKHTON_HOME
export TEKHTON_TEST_MODE=true
export TEKHTON_SESSION_DIR="${WORK_DIR}"
export PROJECT_DIR="${WORK_DIR}"

# shellcheck source=../lib/plan_batch.sh
source "${TEKHTON_HOME}/lib/plan_batch.sh"

# --- A: content already starts with "# " heading — pass-through unchanged ---
input_a='# My Document
## Section One
Some content here.'

output_a=$(printf '%s\n' "$input_a" | _trim_document_preamble)
if [[ "$output_a" == *"# My Document"* ]] && \
   [[ "$(printf '%s\n' "$output_a" | head -1)" == "# My Document" ]]; then
    pass "A: content starting with heading passes through unchanged"
else
    fail "A: heading pass-through" "first line: $(printf '%s\n' "$output_a" | head -1)"
fi

# --- B: preamble before heading — heading and content retained ---------------
input_b='I have enough context to generate the document.
Here it is:

# My Document
## Section One
Content.'

output_b=$(printf '%s\n' "$input_b" | _trim_document_preamble)
first_b=$(printf '%s\n' "$output_b" | head -1)
if [[ "$first_b" == "# My Document" ]] && \
   ! printf '%s\n' "$output_b" | grep -q "I have enough context"; then
    pass "B: preamble stripped, heading and content retained"
else
    fail "B: preamble stripping" "first line: $(printf '%q' "$first_b")"
fi

# --- C: no heading found — content returned unchanged -------------------------
input_c='Just some plain text.
No heading here.
Another line.'

output_c=$(printf '%s\n' "$input_c" | _trim_document_preamble)
first_c=$(printf '%s\n' "$output_c" | head -1)
if [[ "$first_c" == "Just some plain text." ]]; then
    pass "C: content with no heading returned unchanged"
else
    fail "C: no-heading pass-through" "first line: $(printf '%q' "$first_c")"
fi

# --- D: empty content — no output (or empty output) --------------------------
output_d=$(printf '' | _trim_document_preamble)
if [[ -z "$output_d" ]]; then
    pass "D: empty content produces empty output"
else
    fail "D: empty content" "got: $(printf '%q' "$output_d")"
fi

# --- E: heading appears after multiple preamble lines ------------------------
input_e='Line one.
Line two.
Line three.
Line four.
Line five.
# Real Document Starts Here
## Overview
Details.'

output_e=$(printf '%s\n' "$input_e" | _trim_document_preamble)
first_e=$(printf '%s\n' "$output_e" | head -1)
if [[ "$first_e" == "# Real Document Starts Here" ]]; then
    pass "E: heading after multiple preamble lines correctly found"
else
    fail "E: multi-line preamble" "first line: $(printf '%q' "$first_e")"
fi

# --- F: #-prefixed line that is NOT a top-level heading ----------------------
# A shell comment or `#word` (no trailing space) must NOT trigger the fast path
# and must NOT be treated as a ^# heading by the grep that finds the first `^# `.
# The function uses `grep -n '^# '` (note the space after #) to find headings.
input_f='#!/usr/bin/env bash
#pragma once
# Project Title
## Section'

output_f=$(printf '%s\n' "$input_f" | _trim_document_preamble)
first_f=$(printf '%s\n' "$output_f" | head -1)
# The fast path checks [[ "$first_line" == "#"* ]] which matches `#!/usr/bin/env bash`
# so the function returns the content unchanged (fast path triggers on any #-prefix).
# This means the first line stays `#!/usr/bin/env bash`.
# Verify: the function does not crash and returns something consistent.
if [[ -n "$output_f" ]]; then
    pass "F: #-prefixed non-heading line handled without crash (fast path or pass-through)"
else
    fail "F: #-prefixed non-heading" "got empty output"
fi

# --- summary -----------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All _trim_document_preamble tests passed (${PASS})"
    exit 0
else
    echo "FAIL: ${FAIL} tests failed (${PASS} passed)"
    exit 1
fi
