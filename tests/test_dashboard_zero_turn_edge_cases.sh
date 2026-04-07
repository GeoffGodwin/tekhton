#!/usr/bin/env bash
# =============================================================================
# test_dashboard_zero_turn_edge_cases.sh — Edge case coverage for zero-turn filtering
#
# Comprehensive edge case testing for the dashboard parser zero-turn crash filtering.
# These tests verify behavior in corner cases not explicitly covered by the main suite:
# - All records are zero-turn
# - Single zero-turn record
# - Mixed patterns of zero-turn and valid records
# - Boundary conditions at depth limits
# - Very large metrics.jsonl files
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

# Source necessary libraries
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Helper for JSON escaping
_json_escape() {
    local s="$1"
    printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/
/\\n/g'
}

# Test helpers
PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

# =============================================================================
# Test Suite 7: All-zero-turn records (complete filtering)
# =============================================================================
echo "=== Test Suite 7: All-zero-turn records ==="

mkdir -p "$TMPDIR/.claude/logs_all_zero"
cat > "$TMPDIR/.claude/logs_all_zero/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-01T21:12:08Z","task":"","task_type":"feature","milestone_mode":false,"total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-01T21:26:16Z","task":"","task_type":"feature","milestone_mode":false,"total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-01T22:04:47Z","task":"","task_type":"feature","milestone_mode":false,"total_turns":0,"total_time_s":0,"outcome":"crashed"}
JSONL

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_all_zero" 50)

if [ "$result" = "[]" ]; then
    pass "7.1 All-zero-turn records produce empty array"
else
    fail "7.1 All-zero-turn records should produce empty array (got: $result)"
fi

# Verify it's still valid JSON (not malformed)
if echo "$result" | python3 -m json.tool > /dev/null 2>&1 || [ "$result" = "[]" ]; then
    pass "7.2 All-zero-turn result is valid JSON"
else
    fail "7.2 All-zero-turn result is not valid JSON (got: $result)"
fi

# =============================================================================
# Test Suite 8: Single zero-turn record
# =============================================================================
echo "=== Test Suite 8: Single zero-turn record ==="

mkdir -p "$TMPDIR/.claude/logs_single_zero"
cat > "$TMPDIR/.claude/logs_single_zero/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-01T21:12:08Z","task":"","task_type":"feature","milestone_mode":false,"total_turns":0,"total_time_s":0,"outcome":"crashed"}
JSONL

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_single_zero" 50)

if [ "$result" = "[]" ]; then
    pass "8.1 Single zero-turn record is filtered completely"
else
    fail "8.1 Single zero-turn should produce empty array (got: $result)"
fi

# =============================================================================
# Test Suite 9: Zero-turn records at end of file (depth boundary)
# =============================================================================
echo "=== Test Suite 9: Zero-turn records at depth boundary ==="

mkdir -p "$TMPDIR/.claude/logs_end_zeros"
cat > "$TMPDIR/.claude/logs_end_zeros/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-01T20:00:00Z","task":"Real work 1","task_type":"bug","milestone_mode":false,"total_turns":10,"total_time_s":100,"outcome":"success"}
{"timestamp":"2026-04-01T21:00:00Z","task":"Real work 2","task_type":"feature","milestone_mode":false,"total_turns":15,"total_time_s":150,"outcome":"success"}
{"timestamp":"2026-04-01T22:00:00Z","task":"","task_type":"feature","milestone_mode":false,"total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-01T23:00:00Z","task":"","task_type":"feature","milestone_mode":false,"total_turns":0,"total_time_s":0,"outcome":"crashed"}
JSONL

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_end_zeros" 50)

# Should only have 2 real runs (first 2), not 4
if command -v python3 &>/dev/null; then
    entry_count=$(python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" <<< "$result" 2>/dev/null || echo "-1")
else
    entry_count=$(echo "$result" | grep -o '"outcome"' | wc -l)
fi

if [ "$entry_count" = "2" ]; then
    pass "9.1 Zero-turn records at end are filtered (depth=50 returns 2 real runs)"
else
    fail "9.1 Expected 2 entries, got $entry_count (got: $result)"
fi

# =============================================================================
# Test Suite 10: Depth limit with mixed zero-turn and valid
# =============================================================================
echo "=== Test Suite 10: Depth limit interaction ==="

mkdir -p "$TMPDIR/.claude/logs_depth_mixed"
# Create 5 records: 2 zero-turn, 3 valid
cat > "$TMPDIR/.claude/logs_depth_mixed/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-01T20:00:00Z","task":"Real 1","task_type":"bug","total_turns":5,"total_time_s":50,"outcome":"success"}
{"timestamp":"2026-04-01T21:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-01T22:00:00Z","task":"Real 2","task_type":"feature","total_turns":10,"total_time_s":100,"outcome":"success"}
{"timestamp":"2026-04-01T23:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-02T00:00:00Z","task":"Real 3","task_type":"polish","total_turns":8,"total_time_s":80,"outcome":"success"}
JSONL

# Request depth=3, reads last 3 JSONL lines:
# - Real 2 (valid)
# - Zero-turn crash (filtered)
# - Real 3 (valid)
# Expected result: 2 valid runs (after filtering)
result=$(_parse_run_summaries "$TMPDIR/.claude/logs_depth_mixed" 3)

if command -v python3 &>/dev/null; then
    entry_count=$(python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" <<< "$result" 2>/dev/null || echo "-1")
else
    entry_count=$(echo "$result" | grep -o '"outcome"' | wc -l)
fi

# Python path filters within last N JSONL lines, so depth=3 reads 3 JSONL lines
# and returns all valid ones after filtering (2 in this case)
if [ "$entry_count" = "2" ]; then
    pass "10.1 Depth limit with mixed records filters correctly (2 valid from last 3 JSONL lines)"
else
    fail "10.1 Expected 2 entries from last 3 JSONL lines, got $entry_count"
fi

# =============================================================================
# Test Suite 11: Single valid record surrounded by zeros
# =============================================================================
echo "=== Test Suite 11: Single valid record surrounded by zeros ==="

mkdir -p "$TMPDIR/.claude/logs_valid_surrounded"
cat > "$TMPDIR/.claude/logs_valid_surrounded/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-01T20:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-01T21:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-01T22:00:00Z","task":"The one real run","task_type":"bug","total_turns":42,"total_time_s":300,"outcome":"success"}
{"timestamp":"2026-04-01T23:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-02T00:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
JSONL

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_valid_surrounded" 50)

if command -v python3 &>/dev/null; then
    entry_count=$(python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" <<< "$result" 2>/dev/null || echo "-1")
else
    entry_count=$(echo "$result" | grep -o '"outcome"' | wc -l)
fi

if [ "$entry_count" = "1" ]; then
    pass "11.1 Single valid record surrounded by zeros is extracted correctly"
else
    fail "11.1 Expected 1 entry, got $entry_count"
fi

# Verify the correct task is present (account for JSON whitespace formatting)
if echo "$result" | grep -qE '"task_label"\s*:\s*"The one real run"'; then
    pass "11.2 Correct valid record is extracted from filtered results"
else
    fail "11.2 Correct task not found in result (got: $result)"
fi

# =============================================================================
# Test Suite 12: Bash fallback with all-zero records
# =============================================================================
echo "=== Test Suite 12: Bash fallback all-zero behavior ==="

stub_bin3="$TMPDIR/stub_bin3"
mkdir -p "$stub_bin3"
cat > "$stub_bin3/python3" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$stub_bin3/python3"

original_path3="$PATH"
export PATH="${stub_bin3}:${original_path3}"

mkdir -p "$TMPDIR/.claude/logs_bash_zero"
cat > "$TMPDIR/.claude/logs_bash_zero/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-01T20:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
{"timestamp":"2026-04-01T21:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}
JSONL

result_bash=$(_parse_run_summaries "$TMPDIR/.claude/logs_bash_zero" 50)

export PATH="$original_path3"

if [ "$result_bash" = "[]" ]; then
    pass "12.1 Bash fallback filters all-zero records to empty array"
else
    fail "12.1 Bash fallback all-zero should produce empty array (got: $result_bash)"
fi

# =============================================================================
# Test Suite 13: Large metrics.jsonl with sparse valid records
# =============================================================================
echo "=== Test Suite 13: Large file with sparse valid records ==="

mkdir -p "$TMPDIR/.claude/logs_large"
# Create 100 records: mostly zero-turn, 5 valid
{
    for i in {1..30}; do
        echo '{"timestamp":"2026-04-01T20:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}'
    done
    echo '{"timestamp":"2026-04-01T20:15:00Z","task":"Real run 1","task_type":"bug","total_turns":20,"total_time_s":150,"outcome":"success"}'
    for i in {31..40}; do
        echo '{"timestamp":"2026-04-01T20:30:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}'
    done
    echo '{"timestamp":"2026-04-01T20:45:00Z","task":"Real run 2","task_type":"feature","total_turns":25,"total_time_s":200,"outcome":"success"}'
    for i in {41..55}; do
        echo '{"timestamp":"2026-04-01T21:00:00Z","task":"","task_type":"feature","total_turns":0,"total_time_s":0,"outcome":"crashed"}'
    done
    echo '{"timestamp":"2026-04-01T21:15:00Z","task":"Real run 3","task_type":"polish","total_turns":15,"total_time_s":120,"outcome":"success"}'
} > "$TMPDIR/.claude/logs_large/metrics.jsonl"

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_large" 50)

if command -v python3 &>/dev/null; then
    entry_count=$(python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" <<< "$result" 2>/dev/null || echo "-1")
else
    entry_count=$(echo "$result" | grep -o '"outcome"' | wc -l)
fi

if [ "$entry_count" = "3" ]; then
    pass "13.1 Large file with sparse valid records filters correctly (3 real runs from 56 records)"
else
    fail "13.1 Expected 3 valid entries in large file, got $entry_count"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  Zero-turn edge cases: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All zero-turn edge case tests passed"
