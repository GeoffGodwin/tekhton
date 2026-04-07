#!/usr/bin/env bash
# Test: run_memory.sh — JSONL integrity under special characters in task strings
# Covers the coverage gap identified in REVIEWER_REPORT.md (M49):
#   _json_escape handles \, ", \n, \r, \t but $ and backticks in task names
#   that reference shell variables are a specific concern for JSONL validity.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

LOG_DIR="$TEST_TMPDIR/logs"
PROJECT_DIR="$TEST_TMPDIR"
mkdir -p "$LOG_DIR"

# Stubs
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
git()     { return 1; }

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

export LOG_DIR PROJECT_DIR
_CURRENT_MILESTONE="m49"
_ORCH_ELAPSED=10
_ORCH_AGENT_CALLS=1
TIMESTAMP="20260401_120000"

# shellcheck source=../lib/run_memory.sh
source "${TEKHTON_HOME}/lib/run_memory.sh"

memory_file="${LOG_DIR}/RUN_MEMORY.jsonl"

# Helper: parse and validate a JSONL line using python3 or a basic check
# Returns 0 if valid JSON, 1 otherwise.
_is_valid_json() {
    local line="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "import json,sys; json.loads(sys.argv[1])" "$line" 2>/dev/null
    else
        # Fallback: confirm line starts with { and ends with }
        [[ "$line" == "{"* && "$line" == *"}" ]]
    fi
}

# =============================================================================
# Test 1: Dollar sign in task string does not break JSONL
# =============================================================================
echo "=== Test 1: dollar sign in task ==="

TASK='Migrate $HOME variable handling in config loader'
rm -f "$memory_file"
_hook_emit_run_memory 0

line=$(head -1 "$memory_file")
if _is_valid_json "$line"; then
    pass "JSONL is valid with \$ in task"
else
    fail "JSONL invalid with \$ in task. Line: $line"
fi

# Confirm the task content was emitted (dollar sign present in raw file)
if grep -q '\$HOME' "$memory_file"; then
    pass "Dollar sign preserved in JSONL output"
else
    fail "Dollar sign not found in JSONL output"
fi

# =============================================================================
# Test 2: Backtick in task string does not break JSONL
# =============================================================================
echo "=== Test 2: backtick in task ==="

TASK='Fix \`run_agent\` timeout handling in agent.sh'
rm -f "$memory_file"
_hook_emit_run_memory 0

line=$(head -1 "$memory_file")
if _is_valid_json "$line"; then
    pass "JSONL is valid with backtick in task"
else
    fail "JSONL invalid with backtick in task. Line: $line"
fi

# =============================================================================
# Test 3: Single quote in task string does not break JSONL
# =============================================================================
echo "=== Test 3: single quote in task ==="

TASK="Add coder's turn limit to scout estimation"
rm -f "$memory_file"
_hook_emit_run_memory 0

line=$(head -1 "$memory_file")
if _is_valid_json "$line"; then
    pass "JSONL is valid with single quote in task"
else
    fail "JSONL invalid with single quote in task. Line: $line"
fi

# =============================================================================
# Test 4: Double quote in task string is escaped in JSONL
# =============================================================================
echo "=== Test 4: double quote in task ==="

TASK='Set default TASK="empty" when no task given'
rm -f "$memory_file"
_hook_emit_run_memory 0

line=$(head -1 "$memory_file")
if _is_valid_json "$line"; then
    pass "JSONL is valid with double quote in task"
else
    fail "JSONL invalid with double quote in task. Line: $line"
fi

# Double quote must be escaped as \" inside the JSON string
if echo "$line" | grep -q '\\"'; then
    pass "Double quote escaped as \\\" in JSONL"
else
    fail "Double quote not properly escaped in JSONL"
fi

# =============================================================================
# Test 5: Newline embedded in task string does not produce multi-line JSONL
# =============================================================================
echo "=== Test 5: newline in task ==="

# Use printf to embed a real newline
TASK="$(printf 'Line one\nLine two')"
rm -f "$memory_file"
_hook_emit_run_memory 0

line_count=$(wc -l < "$memory_file" | tr -d '[:space:]')
if [[ "$line_count" -eq 1 ]]; then
    pass "Newline in task does not produce multi-line JSONL record (1 line)"
else
    fail "Newline in task produced ${line_count} lines instead of 1"
fi

line=$(head -1 "$memory_file")
if _is_valid_json "$line"; then
    pass "JSONL is valid despite newline in task"
else
    fail "JSONL invalid with newline in task. Line: $line"
fi

# =============================================================================
# Test 6: Backslash in task string is properly escaped
# =============================================================================
echo "=== Test 6: backslash in task ==="

TASK='Update path C:\Users\geoff\config handling'
rm -f "$memory_file"
_hook_emit_run_memory 0

line=$(head -1 "$memory_file")
if _is_valid_json "$line"; then
    pass "JSONL is valid with backslash in task"
else
    fail "JSONL invalid with backslash in task. Line: $line"
fi

# =============================================================================
# Test 7: Combined adversarial task string
# =============================================================================
echo "=== Test 7: combined special characters ==="

# Combines $, backtick, single quote, double quote, backslash
TASK='Fix $PATH and `which bash` in "coder'\''s" C:\scripts handler'
rm -f "$memory_file"
_hook_emit_run_memory 0

line=$(head -1 "$memory_file")
if _is_valid_json "$line"; then
    pass "JSONL is valid with combined special chars in task"
else
    fail "JSONL invalid with combined special chars. Line: $line"
fi

line_count=$(wc -l < "$memory_file" | tr -d '[:space:]')
if [[ "$line_count" -eq 1 ]]; then
    pass "Combined special chars produce exactly one JSONL record"
else
    fail "Combined special chars produced ${line_count} lines"
fi

# =============================================================================
# Test 8: Special chars in task are preserved through keyword extraction
#         (keyword filter must not fail on adversarial input)
# =============================================================================
echo "=== Test 8: keyword filter handles special chars in task ==="

# Pre-populate memory file with an entry whose task has special chars
cat > "$memory_file" << 'JSONL'
{"run_id":"run_sc1","milestone":"m49","task":"Add $HOME variable and `exec` support","files_touched":[],"decisions":[],"rework_reasons":[],"test_outcomes":{"passed":0,"failed":0,"skipped":0},"duration_seconds":50,"agent_calls":1,"verdict":"PASS"}
JSONL

# Query with a task that includes $ and backtick
result=$(build_intake_history_from_memory 'Add $HOME support')

# Should not error out (function completed) and may or may not match
# depending on whether "add" passes the 3-char filter. The critical check
# is that it does not crash or produce shell errors.
pass "Keyword filter completed without error on special-char query task"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
