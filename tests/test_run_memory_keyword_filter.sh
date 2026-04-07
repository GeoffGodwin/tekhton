#!/usr/bin/env bash
# Test: run_memory.sh — keyword matching logic for intake history filtering
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

# shellcheck source=../lib/run_memory.sh
source "${TEKHTON_HOME}/lib/run_memory.sh"

# Create a sample RUN_MEMORY.jsonl with diverse entries
memory_file="${LOG_DIR}/RUN_MEMORY.jsonl"

cat > "$memory_file" << 'JSONL'
{"run_id":"run_001","milestone":"m40","task":"Add user authentication","files_touched":["lib/auth.sh"],"decisions":["Added OAuth flow"],"rework_reasons":[],"test_outcomes":{"passed":10,"failed":0,"skipped":0},"duration_seconds":200,"agent_calls":3,"verdict":"PASS"}
{"run_id":"run_002","milestone":"m41","task":"Fix dashboard rendering bug","files_touched":["lib/dashboard.sh"],"decisions":["Fixed CSS injection"],"rework_reasons":["Missing escaping"],"test_outcomes":{"passed":8,"failed":1,"skipped":0},"duration_seconds":150,"agent_calls":2,"verdict":"FAIL"}
{"run_id":"run_003","milestone":"m42","task":"Improve test coverage for gates","files_touched":["tests/test_gates.sh","lib/gates.sh"],"decisions":[],"rework_reasons":[],"test_outcomes":{"passed":20,"failed":0,"skipped":1},"duration_seconds":300,"agent_calls":4,"verdict":"PASS"}
{"run_id":"run_004","milestone":"m43","task":"Refactor milestone splitting logic","files_touched":["lib/milestone_split.sh"],"decisions":["Extracted helper"],"rework_reasons":[],"test_outcomes":{"passed":15,"failed":0,"skipped":0},"duration_seconds":250,"agent_calls":3,"verdict":"PASS"}
JSONL

# =============================================================================
# Test 1: Matching task returns relevant entries
# =============================================================================
echo "=== Test 1: keyword match on 'authentication' ==="

TASK="Add authentication to the API"
result=$(build_intake_history_from_memory "$TASK")

if echo "$result" | grep -q "user authentication"; then
    pass "Matched 'authentication' entry"
else
    fail "Did not match authentication entry. Got: $result"
fi

# =============================================================================
# Test 2: Non-matching task returns nothing
# =============================================================================
echo "=== Test 2: no match for unrelated task ==="

result=$(build_intake_history_from_memory "Deploy to production server")

if [[ -z "$result" ]]; then
    pass "No matches for unrelated task"
else
    fail "Unexpected matches: $result"
fi

# =============================================================================
# Test 3: Case-insensitive matching
# =============================================================================
echo "=== Test 3: case-insensitive ==="

result=$(build_intake_history_from_memory "DASHBOARD rendering fix")

if echo "$result" | grep -q "dashboard rendering"; then
    pass "Case-insensitive match works"
else
    fail "Case-insensitive match failed. Got: $result"
fi

# =============================================================================
# Test 4: Stop words excluded from matching
# =============================================================================
echo "=== Test 4: stop words excluded ==="

# "the" and "for" are stop words; without real content words, no match
result=$(build_intake_history_from_memory "the for and")

if [[ -z "$result" ]]; then
    pass "Stop words alone produce no matches"
else
    fail "Stop words matched something: $result"
fi

# =============================================================================
# Test 5: Match on file path content
# =============================================================================
echo "=== Test 5: match via file path ==="

result=$(build_intake_history_from_memory "Fix gates validation")

if echo "$result" | grep -q "test coverage for gates"; then
    pass "Matched via 'gates' in file path"
else
    fail "File path match failed. Got: $result"
fi

# =============================================================================
# Test 6: Verdict appears in output
# =============================================================================
echo "=== Test 6: verdict in output ==="

result=$(build_intake_history_from_memory "milestone splitting")

if echo "$result" | grep -q "\[PASS\]"; then
    pass "Verdict PASS shown in output"
else
    fail "Verdict not in output. Got: $result"
fi

# =============================================================================
# Test 7: Empty memory file produces no output
# =============================================================================
echo "=== Test 7: empty memory file ==="

> "$memory_file"
result=$(build_intake_history_from_memory "anything")

if [[ -z "$result" ]]; then
    pass "Empty file produces no output"
else
    fail "Empty file produced output: $result"
fi

# =============================================================================
# Test 8: Missing memory file produces no output (no error)
# =============================================================================
echo "=== Test 8: missing memory file ==="

rm -f "$memory_file"
result=$(build_intake_history_from_memory "anything")

if [[ -z "$result" ]]; then
    pass "Missing file produces no output and no error"
else
    fail "Missing file produced output: $result"
fi

# =============================================================================
# Test 9: Empty task produces no output
# =============================================================================
echo "=== Test 9: empty task ==="

cat > "$memory_file" << 'JSONL'
{"run_id":"run_001","milestone":"m40","task":"Add auth","files_touched":[],"decisions":[],"rework_reasons":[],"test_outcomes":{"passed":0,"failed":0,"skipped":0},"duration_seconds":100,"agent_calls":1,"verdict":"PASS"}
JSONL

TASK=""
result=$(build_intake_history_from_memory "")

if [[ -z "$result" ]]; then
    pass "Empty task produces no output"
else
    fail "Empty task produced output: $result"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
