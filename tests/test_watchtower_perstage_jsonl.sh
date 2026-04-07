#!/usr/bin/env bash
# =============================================================================
# test_watchtower_perstage_jsonl.sh
#
# Test suite for the sed/awk fallback in _parse_run_summaries_from_jsonl()
# that fixes the per-stage breakdown data extraction when Python3 is unavailable.
#
# Bug fix: The fallback path now correctly extracts:
#   - Per-stage turn counts (coder_turns, reviewer_turns, tester_turns, scout_turns)
#   - Per-stage budget values (adjusted_coder, adjusted_reviewer, adjusted_tester)
#   - Only includes stages with turns > 0 (prevents empty rows)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
MOCKDIR="$TMPDIR/mock_bin"
mkdir -p "$MOCKDIR"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

# Create a mock python3 that fails to force sed/awk fallback
cat > "$MOCKDIR/python3" << 'MOCK_EOF'
#!/bin/bash
exit 127  # Command not found
MOCK_EOF
chmod +x "$MOCKDIR/python3"

# Set PATH to prioritize mock bin directory
export PATH="$MOCKDIR:$PATH"

# Source the library under test
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Stub _json_escape for testing
_json_escape() {
    local s="$1"
    printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

# Test helpers
PASS=0
FAIL=0

pass() {
    echo "  ✓ PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ FAIL: $1"
    FAIL=$((FAIL + 1))
}

echo "=== Test Suite: Per-Stage Breakdown JSONL Parsing ==="
echo ""

# =============================================================================
# Test 1: Single run with all stages populated
# =============================================================================
echo "[Test 1] Single run with complete stage data"

METRICS_FILE="$TMPDIR/metrics1.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2025-03-29T10:00:00Z","outcome":"success","task":"Test task","total_turns":15,"total_time_s":600,"task_type":"bug","milestone_mode":false,"coder_turns":5,"reviewer_turns":4,"tester_turns":6,"scout_turns":0,"adjusted_coder":8,"adjusted_reviewer":6,"adjusted_tester":10}
EOF

# Test with sed/awk fallback (python3 is mocked to fail)
RESULT=$(_parse_run_summaries_from_jsonl "$METRICS_FILE" 1)

# Verify result is not empty
if [[ -n "$RESULT" ]]; then
    pass "1.1 Returns non-empty JSON"
else
    fail "1.1 Returns non-empty JSON"
fi

# Verify JSON is valid (has expected structure)
if echo "$RESULT" | grep -q '"stages"'; then
    pass "1.2 JSON contains stages field"
else
    fail "1.2 JSON contains stages field"
fi

# Verify coder stage is present
if echo "$RESULT" | grep -q '"coder"'; then
    pass "1.3 Coder stage present in output"
else
    fail "1.3 Coder stage present in output"
fi

# Verify reviewer stage is present
if echo "$RESULT" | grep -q '"reviewer"'; then
    pass "1.4 Reviewer stage present in output"
else
    fail "1.4 Reviewer stage present in output"
fi

# Verify tester stage is present
if echo "$RESULT" | grep -q '"tester"'; then
    pass "1.5 Tester stage present in output"
else
    fail "1.5 Tester stage present in output"
fi

# Verify scout is NOT present (it had 0 turns)
if ! echo "$RESULT" | grep -q '"scout"'; then
    pass "1.6 Scout stage (0 turns) correctly excluded"
else
    fail "1.6 Scout stage (0 turns) correctly excluded"
fi

# Verify coder turns extracted correctly
if echo "$RESULT" | grep -q '"coder":{"turns":5'; then
    pass "1.7 Coder turns value (5) extracted correctly"
else
    fail "1.7 Coder turns value (5) extracted correctly"
fi

# Verify coder budget extracted correctly
if echo "$RESULT" | grep -q '"coder":{"turns":5,"duration_s":200,"budget":8'; then
    pass "1.8 Coder budget value (8) extracted correctly"
else
    fail "1.8 Coder budget value (8) extracted correctly"
fi

# Verify reviewer turns extracted correctly
if echo "$RESULT" | grep -q '"reviewer":{"turns":4'; then
    pass "1.9 Reviewer turns value (4) extracted correctly"
else
    fail "1.9 Reviewer turns value (4) extracted correctly"
fi

# Verify tester turns extracted correctly
if echo "$RESULT" | grep -q '"tester":{"turns":6'; then
    pass "1.10 Tester turns value (6) extracted correctly"
else
    fail "1.10 Tester turns value (6) extracted correctly"
fi

echo ""

# =============================================================================
# Test 2: Run with zero budget values
# =============================================================================
echo "[Test 2] Stage with zero budget should still include turns"

METRICS_FILE="$TMPDIR/metrics2.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2025-03-29T11:00:00Z","outcome":"success","task":"Another task","total_turns":10,"total_time_s":500,"task_type":"feature","milestone_mode":false,"coder_turns":3,"reviewer_turns":2,"tester_turns":5,"scout_turns":0,"adjusted_coder":0,"adjusted_reviewer":0,"adjusted_tester":0}
EOF

RESULT=$(_parse_run_summaries_from_jsonl "$METRICS_FILE" 1)

# Verify coder still present with zero budget
if echo "$RESULT" | grep -q '"coder":{"turns":3,"duration_s":150,"budget":0'; then
    pass "2.1 Coder stage with zero budget still included"
else
    fail "2.1 Coder stage with zero budget still included"
fi

# Verify reviewer with zero budget
if echo "$RESULT" | grep -q '"reviewer":{"turns":2,"duration_s":100,"budget":0'; then
    pass "2.2 Reviewer stage with zero budget still included"
else
    fail "2.2 Reviewer stage with zero budget still included"
fi

echo ""

# =============================================================================
# Test 3: Run with some stages having zero turns (should be excluded)
# =============================================================================
echo "[Test 3] Stages with zero turns should be excluded"

METRICS_FILE="$TMPDIR/metrics3.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2025-03-29T12:00:00Z","outcome":"success","task":"Partial task","total_turns":5,"total_time_s":300,"task_type":"polish","milestone_mode":false,"coder_turns":3,"reviewer_turns":0,"tester_turns":2,"scout_turns":0,"adjusted_coder":5,"adjusted_reviewer":8,"adjusted_tester":4}
EOF

RESULT=$(_parse_run_summaries_from_jsonl "$METRICS_FILE" 1)

# Verify coder is present
if echo "$RESULT" | grep -q '"coder":{"turns":3'; then
    pass "3.1 Coder stage with turns present"
else
    fail "3.1 Coder stage with turns present"
fi

# Verify reviewer is NOT present (zero turns)
if ! echo "$RESULT" | grep -q '"reviewer"'; then
    pass "3.2 Reviewer stage (0 turns) correctly excluded"
else
    fail "3.2 Reviewer stage (0 turns) correctly excluded"
fi

# Verify tester is present
if echo "$RESULT" | grep -q '"tester":{"turns":2'; then
    pass "3.3 Tester stage with turns present"
else
    fail "3.3 Tester stage with turns present"
fi

# Verify scout is NOT present
if ! echo "$RESULT" | grep -q '"scout"'; then
    pass "3.4 Scout stage (0 turns) correctly excluded"
else
    fail "3.4 Scout stage (0 turns) correctly excluded"
fi

echo ""

# =============================================================================
# Test 4: Multiple runs in JSONL (should reverse order, newest first)
# =============================================================================
echo "[Test 4] Multiple runs parsed in reverse order (newest first)"

METRICS_FILE="$TMPDIR/metrics4.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2025-03-29T09:00:00Z","outcome":"success","task":"Run 1","total_turns":10,"total_time_s":400,"task_type":"bug","milestone_mode":false,"coder_turns":5,"reviewer_turns":3,"tester_turns":2,"scout_turns":0,"adjusted_coder":8,"adjusted_reviewer":6,"adjusted_tester":4}
{"timestamp":"2025-03-29T10:00:00Z","outcome":"success","task":"Run 2","total_turns":12,"total_time_s":450,"task_type":"feature","milestone_mode":false,"coder_turns":4,"reviewer_turns":4,"tester_turns":4,"scout_turns":0,"adjusted_coder":7,"adjusted_reviewer":7,"adjusted_tester":6}
EOF

RESULT=$(_parse_run_summaries_from_jsonl "$METRICS_FILE" 2)

# Parse the JSON to get the order of runs
# Since bash is handling the JSON, we'll check task labels in order
if echo "$RESULT" | grep -o '"task_label":"[^"]*"' | head -1 | grep -q 'Run 2'; then
    pass "4.1 First run in output is Run 2 (newest, from second line)"
else
    fail "4.1 First run in output is Run 2 (newest, from second line)"
fi

# Verify we got both runs
if echo "$RESULT" | grep -q '"task_label":"Run 1"'; then
    pass "4.2 Second run in output is Run 1 (older)"
else
    fail "4.2 Second run in output is Run 1 (older)"
fi

echo ""

# =============================================================================
# Test 5: Run with milestone_mode=true
# =============================================================================
echo "[Test 5] Run with milestone_mode should be identified correctly"

METRICS_FILE="$TMPDIR/metrics5.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2025-03-29T13:00:00Z","outcome":"success","task":"Milestone task","total_turns":20,"total_time_s":800,"task_type":"unknown","milestone_mode":true,"coder_turns":8,"reviewer_turns":6,"tester_turns":6,"scout_turns":0,"adjusted_coder":12,"adjusted_reviewer":10,"adjusted_tester":10}
EOF

RESULT=$(PATH="/no/python:$PATH" bash -c "source '${TEKHTON_HOME}/lib/dashboard_parsers.sh'; _json_escape() { printf '%s' \"\$1\" | sed 's/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g; s/	/\\\\t/g'; }; _parse_run_summaries_from_jsonl '$METRICS_FILE' 1" 2>/dev/null)

# Verify run_type is milestone
if echo "$RESULT" | grep -q '"run_type":"milestone"'; then
    pass "5.1 Run with milestone_mode=true has run_type=milestone"
else
    fail "5.1 Run with milestone_mode=true has run_type=milestone"
fi

# Verify stages are still parsed
if echo "$RESULT" | grep -q '"coder":{"turns":8'; then
    pass "5.2 Milestone run still has per-stage data"
else
    fail "5.2 Milestone run still has per-stage data"
fi

echo ""

# =============================================================================
# Test 6: Run outcome and total_turns preserved
# =============================================================================
echo "[Test 6] Run metadata (outcome, total_turns, total_time_s) correctly preserved"

METRICS_FILE="$TMPDIR/metrics6.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2025-03-29T14:00:00Z","outcome":"rejected","task":"Bad task","total_turns":25,"total_time_s":1200,"task_type":"bug","milestone_mode":false,"coder_turns":10,"reviewer_turns":8,"tester_turns":7,"scout_turns":0,"adjusted_coder":15,"adjusted_reviewer":12,"adjusted_tester":10}
EOF

RESULT=$(PATH="/no/python:$PATH" bash -c "source '${TEKHTON_HOME}/lib/dashboard_parsers.sh'; _json_escape() { printf '%s' \"\$1\" | sed 's/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g; s/	/\\\\t/g'; }; _parse_run_summaries_from_jsonl '$METRICS_FILE' 1" 2>/dev/null)

# Verify outcome is preserved
if echo "$RESULT" | grep -q '"outcome":"rejected"'; then
    pass "6.1 Run outcome preserved"
else
    fail "6.1 Run outcome preserved"
fi

# Verify total_turns is preserved
if echo "$RESULT" | grep -q '"total_turns":25'; then
    pass "6.2 Run total_turns preserved"
else
    fail "6.2 Run total_turns preserved"
fi

# Verify total_time_s is preserved
if echo "$RESULT" | grep -q '"total_time_s":1200'; then
    pass "6.3 Run total_time_s preserved"
else
    fail "6.3 Run total_time_s preserved"
fi

# Verify run_type is human_bug
if echo "$RESULT" | grep -q '"run_type":"human_bug"'; then
    pass "6.4 Run with task_type=bug has run_type=human_bug"
else
    fail "6.4 Run with task_type=bug has run_type=human_bug"
fi

echo ""

# =============================================================================
# Test 7: Task label truncation (first 80 chars)
# =============================================================================
echo "[Test 7] Task label truncation to 80 characters"

LONG_TASK="This is a very long task description that exceeds the eighty character limit and should be truncated to exactly eighty characters or less"
METRICS_FILE="$TMPDIR/metrics7.jsonl"
cat > "$METRICS_FILE" << EOF
{"timestamp":"2025-03-29T15:00:00Z","outcome":"success","task":"$LONG_TASK","total_turns":15,"total_time_s":600,"task_type":"feature","milestone_mode":false,"coder_turns":5,"reviewer_turns":5,"tester_turns":5,"scout_turns":0,"adjusted_coder":8,"adjusted_reviewer":8,"adjusted_tester":8}
EOF

RESULT=$(PATH="/no/python:$PATH" bash -c "source '${TEKHTON_HOME}/lib/dashboard_parsers.sh'; _json_escape() { printf '%s' \"\$1\" | sed 's/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g; s/	/\\\\t/g'; }; _parse_run_summaries_from_jsonl '$METRICS_FILE' 1" 2>/dev/null)

# Extract task_label and check length
TASK_LABEL=$(echo "$RESULT" | sed -n 's/.*"task_label":"\([^"]*\)".*/\1/p' | head -1)
TASK_LEN=${#TASK_LABEL}

if [[ $TASK_LEN -le 80 ]]; then
    pass "7.1 Task label truncated to $TASK_LEN chars (≤ 80)"
else
    fail "7.1 Task label truncated to $TASK_LEN chars (≤ 80)"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL))
echo "========================================"
echo "Test Results: $PASS passed, $FAIL failed out of $TOTAL total"
echo "========================================"

if [[ $FAIL -eq 0 ]]; then
    exit 0
else
    exit 1
fi
