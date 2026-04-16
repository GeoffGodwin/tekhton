#!/usr/bin/env bash
# Test: run_memory.sh — FIFO pruning when file exceeds RUN_MEMORY_MAX_ENTRIES
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

# Need to source common.sh first to get file defaults
source "${TEKHTON_HOME}/lib/common.sh"

# shellcheck source=../lib/run_memory.sh
source "${TEKHTON_HOME}/lib/run_memory.sh"

memory_file="${LOG_DIR}/RUN_MEMORY.jsonl"

# =============================================================================
# Test 1: No pruning when under limit
# =============================================================================
echo "=== Test 1: under limit ==="

RUN_MEMORY_MAX_ENTRIES=5
# Write 3 entries
for i in 1 2 3; do
    echo "{\"run_id\":\"run_${i}\",\"task\":\"task ${i}\"}" >> "$memory_file"
done

_prune_run_memory "$memory_file"
count=$(wc -l < "$memory_file" | tr -d '[:space:]')

if [[ "$count" -eq 3 ]]; then
    pass "No pruning when under limit (3 <= 5)"
else
    fail "Expected 3 lines, got $count"
fi

# =============================================================================
# Test 2: Pruning removes oldest when over limit
# =============================================================================
echo "=== Test 2: over limit ==="

# Add more entries to go over limit
for i in 4 5 6 7; do
    echo "{\"run_id\":\"run_${i}\",\"task\":\"task ${i}\"}" >> "$memory_file"
done
# Now 7 entries, limit is 5

_prune_run_memory "$memory_file"
count=$(wc -l < "$memory_file" | tr -d '[:space:]')

if [[ "$count" -eq 5 ]]; then
    pass "Pruned to max entries (5)"
else
    fail "Expected 5 lines after prune, got $count"
fi

# Verify oldest entries were removed (FIFO)
if grep -q '"run_id":"run_1"' "$memory_file"; then
    fail "run_1 should have been pruned"
else
    pass "run_1 correctly pruned (FIFO)"
fi

if grep -q '"run_id":"run_2"' "$memory_file"; then
    fail "run_2 should have been pruned"
else
    pass "run_2 correctly pruned (FIFO)"
fi

if grep -q '"run_id":"run_7"' "$memory_file"; then
    pass "run_7 retained (newest)"
else
    fail "run_7 should have been retained"
fi

# =============================================================================
# Test 3: Exactly at limit — no pruning
# =============================================================================
echo "=== Test 3: exactly at limit ==="

rm -f "$memory_file"
RUN_MEMORY_MAX_ENTRIES=3
for i in 1 2 3; do
    echo "{\"run_id\":\"run_${i}\"}" >> "$memory_file"
done

_prune_run_memory "$memory_file"
count=$(wc -l < "$memory_file" | tr -d '[:space:]')

if [[ "$count" -eq 3 ]]; then
    pass "No pruning at exact limit"
else
    fail "Expected 3 lines at exact limit, got $count"
fi

# =============================================================================
# Test 4: Pruning via _hook_emit_run_memory with small limit
# =============================================================================
echo "=== Test 4: emission triggers prune ==="

rm -f "$memory_file"
RUN_MEMORY_MAX_ENTRIES=2
_CURRENT_MILESTONE="m1"
_ORCH_ELAPSED=10
_ORCH_AGENT_CALLS=1
TASK="test task"
TIMESTAMP="20260101_000001"

# Emit 3 records
for i in 1 2 3; do
    TIMESTAMP="20260101_00000${i}"
    _hook_emit_run_memory 0
done

count=$(wc -l < "$memory_file" | tr -d '[:space:]')

if [[ "$count" -eq 2 ]]; then
    pass "Auto-pruned after emission to max 2"
else
    fail "Expected 2 lines after auto-prune, got $count"
fi

# =============================================================================
# Test 5: Missing file handled gracefully
# =============================================================================
echo "=== Test 5: prune missing file ==="

rm -f "$memory_file"
_prune_run_memory "$memory_file"
# Should not error
pass "Pruning missing file does not error"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
