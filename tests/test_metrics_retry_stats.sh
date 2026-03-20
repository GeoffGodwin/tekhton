#!/usr/bin/env bash
# =============================================================================
# test_metrics_retry_stats.sh — Verify retry stats display in summarize_metrics()
#
# Tests:
#   1. Retry stats appear when metrics have non-zero retry_count
#   2. Retry stats show total retries, run count, and per-100 average
#   3. Retry stats do NOT appear when all records have retry_count=0
#   4. Retry stats handle multiple records with different retry counts
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/.claude/logs"
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/.claude/logs"
export PROJECT_DIR LOG_DIR

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/metrics.sh"
source "${TEKHTON_HOME}/lib/metrics_dashboard.sh"

PASS=0
FAIL=0

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Test 1: Retry stats appear when metrics have non-zero retry_count
# =============================================================================
echo "=== Test 1: Retry stats appear with non-zero retry_count ==="

cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2024-01-15T10:00:00Z","task":"Fix login bug","task_type":"bug","milestone_mode":false,"total_turns":42,"total_time_s":120,"coder_turns":15,"reviewer_turns":10,"tester_turns":8,"scout_turns":9,"scout_est_coder":12,"scout_est_reviewer":8,"scout_est_tester":6,"adjusted_coder":15,"adjusted_reviewer":10,"adjusted_tester":8,"context_tokens":8500,"retry_count":2,"verdict":"APPROVED","outcome":"success"}
EOF

output=$(summarize_metrics 50)

if echo "$output" | grep -q "Retries:"; then
    pass "1.1: Retry stats section appears"
else
    fail "1.1: Retry stats section should appear when retry_count > 0"
fi

if echo "$output" | grep "Retries:" | grep -q "2 total"; then
    pass "1.2: Total retries (2) displayed correctly"
else
    fail "1.2: Total retries should show '2 total'"
fi

if echo "$output" | grep "Retries:" | grep -q "1 runs"; then
    pass "1.3: Run count (1) displayed correctly"
else
    fail "1.3: Run count should show '1 runs'"
fi

if echo "$output" | grep "Retries:" | grep -qE "per 100 invocations"; then
    pass "1.4: Per-100 average text appears"
else
    fail "1.4: Should show 'per 100 invocations' phrase"
fi

# =============================================================================
# Test 2: Retry stats show correct calculations with multiple records
# =============================================================================
echo "=== Test 2: Correct calculations with multiple records ==="

cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2024-01-15T10:00:00Z","task":"Fix bug 1","task_type":"bug","milestone_mode":false,"total_turns":42,"total_time_s":120,"coder_turns":15,"reviewer_turns":10,"tester_turns":8,"scout_turns":9,"scout_est_coder":12,"scout_est_reviewer":8,"scout_est_tester":6,"adjusted_coder":15,"adjusted_reviewer":10,"adjusted_tester":8,"context_tokens":8500,"retry_count":2,"verdict":"APPROVED","outcome":"success"}
{"timestamp":"2024-01-15T10:30:00Z","task":"Add feature","task_type":"feature","milestone_mode":false,"total_turns":55,"total_time_s":180,"coder_turns":20,"reviewer_turns":12,"tester_turns":10,"scout_turns":13,"scout_est_coder":18,"scout_est_reviewer":10,"scout_est_tester":8,"adjusted_coder":20,"adjusted_reviewer":12,"adjusted_tester":10,"context_tokens":9200,"retry_count":3,"verdict":"APPROVED","outcome":"success"}
{"timestamp":"2024-01-15T11:00:00Z","task":"Fix bug 2","task_type":"bug","milestone_mode":false,"total_turns":38,"total_time_s":100,"coder_turns":12,"reviewer_turns":8,"tester_turns":6,"scout_turns":12,"scout_est_coder":10,"scout_est_reviewer":6,"scout_est_tester":4,"adjusted_coder":12,"adjusted_reviewer":8,"adjusted_tester":6,"context_tokens":7800,"retry_count":0,"verdict":"APPROVED","outcome":"success"}
EOF

output=$(summarize_metrics 50)

# Total retries: 2 + 3 + 0 = 5
# Records with retries: 2
# Record count: 3
# Per-100: 5 * 100 / 3 = 166 (integer division)

if echo "$output" | grep "Retries:" | grep -q "5 total"; then
    pass "2.1: Total retries (5) calculated correctly"
else
    fail "2.1: Total retries should be 5 (2+3+0)"
fi

if echo "$output" | grep "Retries:" | grep -q "2 runs"; then
    pass "2.2: Run count (2) with retries calculated correctly"
else
    fail "2.2: Run count should be 2 (only records with retry_count > 0)"
fi

# =============================================================================
# Test 3: Retry stats do NOT appear when all records have retry_count=0
# =============================================================================
echo "=== Test 3: Retry stats omitted when all retry_count=0 ==="

cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2024-01-15T10:00:00Z","task":"Task 1","task_type":"bug","milestone_mode":false,"total_turns":42,"total_time_s":120,"coder_turns":15,"reviewer_turns":10,"tester_turns":8,"scout_turns":9,"scout_est_coder":12,"scout_est_reviewer":8,"scout_est_tester":6,"adjusted_coder":15,"adjusted_reviewer":10,"adjusted_tester":8,"context_tokens":8500,"retry_count":0,"verdict":"APPROVED","outcome":"success"}
{"timestamp":"2024-01-15T10:30:00Z","task":"Task 2","task_type":"feature","milestone_mode":false,"total_turns":55,"total_time_s":180,"coder_turns":20,"reviewer_turns":12,"tester_turns":10,"scout_turns":13,"scout_est_coder":18,"scout_est_reviewer":10,"scout_est_tester":8,"adjusted_coder":20,"adjusted_reviewer":12,"adjusted_tester":10,"context_tokens":9200,"retry_count":0,"verdict":"APPROVED","outcome":"success"}
EOF

output=$(summarize_metrics 50)

if ! echo "$output" | grep -q "Retries:"; then
    pass "3.1: Retry stats section does NOT appear when total_retries=0"
else
    fail "3.1: Retry stats should not appear when all retry_count=0"
fi

# =============================================================================
# Test 4: Retry stats handle single record with retries
# =============================================================================
echo "=== Test 4: Single record with retries ==="

cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2024-01-15T10:00:00Z","task":"Single retry test","task_type":"milestone","milestone_mode":true,"total_turns":100,"total_time_s":300,"coder_turns":50,"reviewer_turns":20,"tester_turns":15,"scout_turns":15,"scout_est_coder":45,"scout_est_reviewer":18,"scout_est_tester":12,"adjusted_coder":50,"adjusted_reviewer":20,"adjusted_tester":15,"context_tokens":15000,"retry_count":1,"verdict":"APPROVED","outcome":"success"}
EOF

output=$(summarize_metrics 50)

if echo "$output" | grep "Retries:" | grep -q "1 total"; then
    pass "4.1: Single retry counted correctly"
else
    fail "4.1: Single retry should show '1 total'"
fi

if echo "$output" | grep "Retries:" | grep -q "1 runs"; then
    pass "4.2: Single run with retry counted correctly"
else
    fail "4.2: Should show '1 runs' for single record with retry"
fi

# =============================================================================
# Test 5: Large retry count edge case
# =============================================================================
echo "=== Test 5: Large retry count edge case ==="

cat > "$LOG_DIR/metrics.jsonl" << 'EOF'
{"timestamp":"2024-01-15T10:00:00Z","task":"High retry task","task_type":"feature","milestone_mode":false,"total_turns":120,"total_time_s":400,"coder_turns":60,"reviewer_turns":30,"tester_turns":20,"scout_turns":10,"scout_est_coder":50,"scout_est_reviewer":25,"scout_est_tester":15,"adjusted_coder":60,"adjusted_reviewer":30,"adjusted_tester":20,"context_tokens":18000,"retry_count":5,"verdict":"APPROVED","outcome":"success"}
EOF

output=$(summarize_metrics 50)

if echo "$output" | grep "Retries:" | grep -q "5 total"; then
    pass "5.1: Large retry count (5) handled correctly"
else
    fail "5.1: Should show '5 total' for large retry count"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "Test Results: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
    exit 1
fi

echo "PASS"
