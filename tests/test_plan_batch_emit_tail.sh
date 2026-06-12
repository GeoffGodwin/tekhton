#!/usr/bin/env bash
# tests/test_plan_batch_emit_tail.sh — unit tests for _plan_batch_emit_tail
# in lib/plan_batch.sh.
#
# _plan_batch_emit_tail extracts lines from the stdout_tail JSON array in an
# agent.response.v1 file produced by `tekhton supervise`. It is a pure awk
# function with no external dependencies.
#
# Coverage:
#   A — happy path: multi-line stdout_tail extracted correctly
#   B — stdout_tail is null (absent/no content): no output, returns 0
#   C — missing file: no output, returns 0
#   D1 — escaped double-quote unescaped correctly
#   D2 — escaped backslash unescaped correctly
#   E — only stdout_tail section extracted (not other array fields)
#   F — single-line stdout_tail entry extracted correctly
set -uo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1 — $2"; FAIL=$(( FAIL + 1 )); }

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

# Stubs required by plan_batch.sh source-time guard and function bodies.
log_verbose() { :; }
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
# Prevent the lazy source block from trying to load agent_shim.sh.
_shim_resolve_binary() { echo "${WORK_DIR}/tekhton"; return 0; }
_shim_write_request()  { :; }
_shim_field()          { :; }

export TEKHTON_HOME
export TEKHTON_TEST_MODE=true
export TEKHTON_SESSION_DIR="${WORK_DIR}"
export PROJECT_DIR="${WORK_DIR}"

# Source the file under test.  set -e is intentionally NOT set at the test
# level so individual assertion sub-tests can capture return codes without
# aborting the whole file.
# shellcheck source=../lib/plan_batch.sh
source "${TEKHTON_HOME}/lib/plan_batch.sh"

# --- A: happy path — multi-line stdout_tail ----------------------------------
RESPONSE_A="${WORK_DIR}/response_a.json"
cat > "$RESPONSE_A" << 'JSON'
{
  "exit_code": 0,
  "stdout_tail": [
    "First output line",
    "Second output line",
    "Third output line"
  ]
}
JSON

output_a=$(_plan_batch_emit_tail "$RESPONSE_A")
if [[ "$output_a" == $'First output line\nSecond output line\nThird output line' ]]; then
    pass "A: multi-line stdout_tail extracted correctly"
else
    fail "A: multi-line stdout_tail extraction" "got: $(printf '%q' "$output_a")"
fi

# --- B: stdout_tail is null — no output, returns 0 --------------------------
# When the agent produces no output, supervise may set stdout_tail to null.
# The awk looks for "stdout_tail": [ — null does not match the [ pattern,
# so in_tail is never set and no output is produced.
RESPONSE_B="${WORK_DIR}/response_b.json"
cat > "$RESPONSE_B" << 'JSON'
{
  "exit_code": 0,
  "stdout_tail": null
}
JSON

set +e
output_b=$(_plan_batch_emit_tail "$RESPONSE_B")
rc_b=$?
set -e

if [[ -z "$output_b" ]] && [[ "$rc_b" -eq 0 ]]; then
    pass "B: null stdout_tail produces no output and returns 0"
else
    fail "B: null stdout_tail" "output=$(printf '%q' "$output_b") rc=${rc_b}"
fi

# --- C: missing file — no output, returns 0 ----------------------------------
set +e
output_c=$(_plan_batch_emit_tail "${WORK_DIR}/nonexistent_response.json")
rc_c=$?
set -e

if [[ -z "$output_c" ]] && [[ "$rc_c" -eq 0 ]]; then
    pass "C: missing file produces no output and returns 0"
else
    fail "C: missing file" "output=$(printf '%q' "$output_c") rc=${rc_c}"
fi

# --- D1: escaped double-quote — \\" in JSON → " in output -------------------
# JSON: "line with \"quote\"" → awk output: line with "quote"
# In the file (single-quoted heredoc): \" is two chars: backslash + quote
RESPONSE_D="${WORK_DIR}/response_d.json"
cat > "$RESPONSE_D" << 'JSON'
{
  "exit_code": 0,
  "stdout_tail": [
    "line with \"quoted\" word"
  ]
}
JSON

output_d1=$(_plan_batch_emit_tail "$RESPONSE_D")
if [[ "$output_d1" == 'line with "quoted" word' ]]; then
    pass "D1: escaped double-quote unescaped to literal quote"
else
    fail "D1: escaped double-quote" "got: $(printf '%q' "$output_d1")"
fi

# --- D2: escaped backslash — \\\\ in JSON → \\ in output --------------------
# JSON string "line with \\backslash" (file has \\backslash = 2 chars: \backslash)
# The JSON-encoded form \\ represents a single literal backslash.
# After awk unescaping: line with \backslash (one backslash).
RESPONSE_D2="${WORK_DIR}/response_d2.json"
cat > "$RESPONSE_D2" << 'JSON'
{
  "exit_code": 0,
  "stdout_tail": [
    "line with \\backslash"
  ]
}
JSON

output_d2=$(_plan_batch_emit_tail "$RESPONSE_D2")
# Expected: one literal backslash between "with " and "backslash"
if [[ "$output_d2" == $'line with \\backslash' ]]; then
    pass "D2: escaped backslash unescaped to single backslash"
else
    fail "D2: escaped backslash" "got: $(printf '%q' "$output_d2")"
fi

# --- E: section isolation — only stdout_tail section extracted ---------------
RESPONSE_E="${WORK_DIR}/response_e.json"
cat > "$RESPONSE_E" << 'JSON'
{
  "exit_code": 0,
  "other_array": [
    "should not appear in output"
  ],
  "stdout_tail": [
    "only this line"
  ],
  "yet_another_array": [
    "also not in output"
  ]
}
JSON

output_e=$(_plan_batch_emit_tail "$RESPONSE_E")
if [[ "$output_e" == "only this line" ]]; then
    pass "E: only stdout_tail section extracted (other arrays excluded)"
else
    fail "E: section isolation" "got: $(printf '%q' "$output_e")"
fi

# --- F: single-line stdout_tail entry ----------------------------------------
RESPONSE_F="${WORK_DIR}/response_f.json"
cat > "$RESPONSE_F" << 'JSON'
{
  "exit_code": 0,
  "stdout_tail": [
    "single entry here"
  ]
}
JSON

output_f=$(_plan_batch_emit_tail "$RESPONSE_F")
if [[ "$output_f" == "single entry here" ]]; then
    pass "F: single stdout_tail entry extracted correctly"
else
    fail "F: single entry" "got: $(printf '%q' "$output_f")"
fi

# --- G: empty stdout_tail array — no output, returns 0 ----------------------
# An empty array [] takes a different awk code path from null: in_tail is set
# to 1 on the "[" match then immediately cleared on "]", producing no output.
# This is distinct from the null case (B) and must be covered separately.
RESPONSE_G="${WORK_DIR}/response_g.json"
cat > "$RESPONSE_G" << 'JSON'
{
  "exit_code": 0,
  "stdout_tail": []
}
JSON

set +e
output_g=$(_plan_batch_emit_tail "$RESPONSE_G")
rc_g=$?
set -e

if [[ -z "$output_g" ]] && [[ "$rc_g" -eq 0 ]]; then
    pass "G: empty stdout_tail array produces no output and returns 0"
else
    fail "G: empty stdout_tail array" "output=$(printf '%q' "$output_g") rc=${rc_g}"
fi

# --- summary -----------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All _plan_batch_emit_tail tests passed (${PASS})"
    exit 0
else
    echo "FAIL: ${FAIL} tests failed (${PASS} passed)"
    exit 1
fi
