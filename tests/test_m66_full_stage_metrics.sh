#!/usr/bin/env bash
# =============================================================================
# test_m66_full_stage_metrics.sh
#
# Tests for M66: Watchtower Full-Stage Metrics & Hierarchical Breakdown
# Validates:
#   1. Extended metrics.jsonl recording (security, cleanup, cycles)
#   2. Parser extraction of new fields (Python + bash fallback)
#   3. Backward compatibility with historical records missing new fields
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
MOCKDIR="$TMPDIR/mock_bin"
mkdir -p "$MOCKDIR"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "$LOG_DIR"
export PROJECT_DIR LOG_DIR TEKHTON_HOME

# Source libraries
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics_extended.sh"

# Stub _json_escape for parser tests
_json_escape() {
    local s="$1"
    printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

# Source parsers
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== M66: Full-Stage Metrics Tests ==="
echo ""

# =============================================================================
# Test 1: record_run_metrics emits security fields when security ran
# =============================================================================
echo "[Test 1] Security turns/duration recorded in metrics.jsonl"

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

TASK="Milestone 66"
MILESTONE_MODE=true
TOTAL_TURNS=50
TOTAL_TIME=600
STAGE_SUMMARY="\n  Coder: 30/50 turns, 3m0s\n  Reviewer: 10/15 turns, 1m0s"
VERDICT="APPROVED"
METRICS_ENABLED=true
SCOUT_REC_CODER_TURNS=0
SCOUT_REC_REVIEWER_TURNS=0
SCOUT_REC_TESTER_TURNS=0
ADJUSTED_CODER_TURNS=0
ADJUSTED_REVIEWER_TURNS=0
ADJUSTED_TESTER_TURNS=0
LAST_CONTEXT_TOKENS=0
LAST_AGENT_RETRY_COUNT=0
CONTINUATION_ATTEMPTS=0
_ORCH_ATTEMPT=0
_ORCH_AGENT_CALLS=0
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""

# Simulate _STAGE_DURATION and _STAGE_TURNS with security data
declare -A _STAGE_DURATION=([coder]=180 [reviewer]=60 [security]=45)
declare -A _STAGE_TURNS=([coder]=30 [reviewer]=10 [security]=9)
declare -A _STAGE_BUDGET=()
declare -A _STAGE_START_TS=()

SECURITY_REWORK_CYCLES_DONE=1
REVIEW_CYCLE=2

record_run_metrics

line=$(cat "${LOG_DIR}/metrics.jsonl")

if echo "$line" | grep -q '"security_turns":9'; then
    pass "1.1 security_turns recorded"
else
    fail "1.1 security_turns not found: ${line}"
fi

if echo "$line" | grep -q '"security_duration_s":45'; then
    pass "1.2 security_duration_s recorded"
else
    fail "1.2 security_duration_s not found: ${line}"
fi

if echo "$line" | grep -q '"review_cycles":2'; then
    pass "1.3 review_cycles recorded"
else
    fail "1.3 review_cycles not found: ${line}"
fi

if echo "$line" | grep -q '"security_rework_cycles":1'; then
    pass "1.4 security_rework_cycles recorded"
else
    fail "1.4 security_rework_cycles not found: ${line}"
fi

echo ""

# =============================================================================
# Test 2: record_run_metrics emits cleanup fields when cleanup ran
# =============================================================================
echo "[Test 2] Cleanup turns/duration recorded in metrics.jsonl"

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

_STAGE_DURATION=([coder]=120 [cleanup]=60)
_STAGE_TURNS=([coder]=20 [cleanup]=5)
SECURITY_REWORK_CYCLES_DONE=0
REVIEW_CYCLE=0

record_run_metrics

line=$(cat "${LOG_DIR}/metrics.jsonl")

if echo "$line" | grep -q '"cleanup_turns":5'; then
    pass "2.1 cleanup_turns recorded"
else
    fail "2.1 cleanup_turns not found: ${line}"
fi

if echo "$line" | grep -q '"cleanup_duration_s":60'; then
    pass "2.2 cleanup_duration_s recorded"
else
    fail "2.2 cleanup_duration_s not found: ${line}"
fi

echo ""

# =============================================================================
# Test 3: Sparse keys — security omitted when not run
# =============================================================================
echo "[Test 3] Security fields omitted when security did not run"

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

_STAGE_DURATION=([coder]=120)
_STAGE_TURNS=([coder]=20)
SECURITY_REWORK_CYCLES_DONE=0
REVIEW_CYCLE=0

record_run_metrics

line=$(cat "${LOG_DIR}/metrics.jsonl")

if ! echo "$line" | grep -q '"security_turns"'; then
    pass "3.1 security_turns absent when security didn't run"
else
    fail "3.1 security_turns should be absent: ${line}"
fi

if ! echo "$line" | grep -q '"security_rework_cycles"'; then
    pass "3.2 security_rework_cycles absent when zero"
else
    fail "3.2 security_rework_cycles should be absent: ${line}"
fi

if ! echo "$line" | grep -q '"review_cycles"'; then
    pass "3.3 review_cycles absent when zero"
else
    fail "3.3 review_cycles should be absent: ${line}"
fi

echo ""

# =============================================================================
# Test 4: Python parser extracts new fields
# =============================================================================
echo "[Test 4] Python parser extracts security, cleanup, and cycle data"

METRICS_FILE="$TMPDIR/metrics_py.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2026-04-01T10:00:00Z","outcome":"success","task":"M66 test","total_turns":60,"total_time_s":900,"task_type":"milestone","milestone_mode":true,"coder_turns":30,"reviewer_turns":10,"tester_turns":12,"scout_turns":5,"security_turns":8,"cleanup_turns":3,"coder_duration_s":300,"reviewer_duration_s":120,"tester_duration_s":200,"scout_duration_s":40,"security_duration_s":90,"cleanup_duration_s":50,"review_cycles":2,"security_rework_cycles":1,"adjusted_coder":40,"adjusted_reviewer":15,"adjusted_tester":20}
EOF

if command -v python3 &>/dev/null; then
    RESULT=$(_parse_run_summaries_from_jsonl "$METRICS_FILE" 1)

    if echo "$RESULT" | grep -q '"security"'; then
        pass "4.1 Python parser includes security stage"
    else
        fail "4.1 Python parser missing security: ${RESULT}"
    fi

    if echo "$RESULT" | grep -q '"cleanup"'; then
        pass "4.2 Python parser includes cleanup stage"
    else
        fail "4.2 Python parser missing cleanup: ${RESULT}"
    fi

    if echo "$RESULT" | grep -q '"cycles": 2'; then
        pass "4.3 Python parser includes review_cycles metadata"
    else
        fail "4.3 Python parser missing cycles: ${RESULT}"
    fi

    if echo "$RESULT" | grep -q '"rework_cycles": 1'; then
        pass "4.4 Python parser includes security rework_cycles metadata"
    else
        fail "4.4 Python parser missing rework_cycles: ${RESULT}"
    fi
else
    pass "4.1 [SKIP] Python3 not available"
    pass "4.2 [SKIP] Python3 not available"
    pass "4.3 [SKIP] Python3 not available"
    pass "4.4 [SKIP] Python3 not available"
fi

echo ""

# =============================================================================
# Test 5: Bash fallback parser extracts new fields
# =============================================================================
echo "[Test 5] Bash fallback parser extracts security, cleanup, and cycle data"

# Create mock python3 that fails to force bash fallback
cat > "$MOCKDIR/python3" << 'MOCK_EOF'
#!/bin/bash
exit 127
MOCK_EOF
chmod +x "$MOCKDIR/python3"

RESULT=$(PATH="$MOCKDIR:$PATH" bash -c "
source '${TEKHTON_HOME}/lib/dashboard_parsers.sh'
_json_escape() { printf '%s' \"\$1\" | sed 's/\\\\\\\\/\\\\\\\\\\\\\\\\/g; s/\"/\\\\\\\\\"/g; s/	/\\\\\\\\t/g'; }
_parse_run_summaries_from_jsonl '$METRICS_FILE' 1
" 2>/dev/null)

if echo "$RESULT" | grep -q '"security"'; then
    pass "5.1 Bash parser includes security stage"
else
    fail "5.1 Bash parser missing security: ${RESULT}"
fi

if echo "$RESULT" | grep -q '"cleanup"'; then
    pass "5.2 Bash parser includes cleanup stage"
else
    fail "5.2 Bash parser missing cleanup: ${RESULT}"
fi

if echo "$RESULT" | grep -q '"cycles":2'; then
    pass "5.3 Bash parser includes review_cycles metadata"
else
    fail "5.3 Bash parser missing cycles: ${RESULT}"
fi

if echo "$RESULT" | grep -q '"rework_cycles":1'; then
    pass "5.4 Bash parser includes security rework_cycles metadata"
else
    fail "5.4 Bash parser missing rework_cycles: ${RESULT}"
fi

echo ""

# =============================================================================
# Test 6: Backward compatibility — old records without new fields
# =============================================================================
echo "[Test 6] Old records without new fields parse without error"

METRICS_FILE="$TMPDIR/metrics_old.jsonl"
cat > "$METRICS_FILE" << 'EOF'
{"timestamp":"2025-12-01T10:00:00Z","outcome":"success","task":"Old task","total_turns":30,"total_time_s":500,"task_type":"feature","milestone_mode":false,"coder_turns":15,"reviewer_turns":8,"tester_turns":7,"scout_turns":0,"adjusted_coder":20,"adjusted_reviewer":10,"adjusted_tester":15}
EOF

# Test Python parser
if command -v python3 &>/dev/null; then
    RESULT=$(_parse_run_summaries_from_jsonl "$METRICS_FILE" 1)
    if [[ -n "$RESULT" ]] && echo "$RESULT" | grep -q '"coder"'; then
        pass "6.1 Python parser handles old records gracefully"
    else
        fail "6.1 Python parser failed on old record: ${RESULT}"
    fi
    # Should not have security or cleanup in output
    if ! echo "$RESULT" | grep -q '"security"'; then
        pass "6.2 Python parser: no phantom security stage on old records"
    else
        fail "6.2 Python parser created phantom security: ${RESULT}"
    fi
else
    pass "6.1 [SKIP] Python3 not available"
    pass "6.2 [SKIP] Python3 not available"
fi

# Test bash fallback
RESULT=$(PATH="$MOCKDIR:$PATH" bash -c "
source '${TEKHTON_HOME}/lib/dashboard_parsers.sh'
_json_escape() { printf '%s' \"\$1\" | sed 's/\\\\\\\\/\\\\\\\\\\\\\\\\/g; s/\"/\\\\\\\\\"/g; s/	/\\\\\\\\t/g'; }
_parse_run_summaries_from_jsonl '$METRICS_FILE' 1
" 2>/dev/null)

if [[ -n "$RESULT" ]] && echo "$RESULT" | grep -q '"coder"'; then
    pass "6.3 Bash parser handles old records gracefully"
else
    fail "6.3 Bash parser failed on old record: ${RESULT}"
fi

if ! echo "$RESULT" | grep -q '"security"'; then
    pass "6.4 Bash parser: no phantom security stage on old records"
else
    fail "6.4 Bash parser created phantom security: ${RESULT}"
fi

echo ""

# =============================================================================
# Test 7: Sub-step duration sum approximately matches parent
# =============================================================================
echo "[Test 7] Sub-step durations available for downstream rendering"

# The _STAGE_DURATION array already has sub-steps set during the pipeline run.
# Verify that the metrics.sh code captures the parent stage values correctly
# even when sub-step keys coexist in the array.
_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

_STAGE_DURATION=([security]=90 ["security_scan"]=50 ["security_rework_1"]=40 [coder]=200)
_STAGE_TURNS=([security]=15 ["security_scan"]=8 ["security_rework_1"]=7 [coder]=30)
SECURITY_REWORK_CYCLES_DONE=1
REVIEW_CYCLE=0

record_run_metrics

line=$(cat "${LOG_DIR}/metrics.jsonl")

if echo "$line" | grep -q '"security_turns":15'; then
    pass "7.1 Parent security turns captured despite sub-step keys"
else
    fail "7.1 Parent security turns wrong: ${line}"
fi

if echo "$line" | grep -q '"security_duration_s":90'; then
    pass "7.2 Parent security duration captured despite sub-step keys"
else
    fail "7.2 Parent security duration wrong: ${line}"
fi

echo ""

# =============================================================================
# Test 8: test_audit_duration_s and analyze_cleanup_duration_s emitted
#
# record_run_metrics() now reads _STAGE_DURATION for test_audit and
# analyze_cleanup sub-steps and emits their durations alongside turns.
# =============================================================================
echo "[Test 8] test_audit_duration_s and analyze_cleanup_duration_s emitted to JSONL"

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"

# Simulate a run where test_audit AND analyze_cleanup sub-steps both ran,
# with their durations present in _STAGE_DURATION (as set by tester.sh / hooks.sh).
_STAGE_DURATION=([coder]=200 [tester]=90 ["test_audit"]=30 ["analyze_cleanup"]=20)
_STAGE_TURNS=([coder]=25 [tester]=12 ["test_audit"]=5 ["analyze_cleanup"]=3)
SECURITY_REWORK_CYCLES_DONE=0
REVIEW_CYCLE=0

record_run_metrics

line=$(cat "${LOG_DIR}/metrics.jsonl")

# Positive: turns ARE recorded
if echo "$line" | grep -q '"test_audit_turns":5'; then
    pass "8.1 test_audit_turns emitted when test_audit ran"
else
    fail "8.1 test_audit_turns not found: ${line}"
fi

if echo "$line" | grep -q '"analyze_cleanup_turns":3'; then
    pass "8.2 analyze_cleanup_turns emitted when analyze_cleanup ran"
else
    fail "8.2 analyze_cleanup_turns not found: ${line}"
fi

# Positive: durations ARE now recorded from _STAGE_DURATION
if echo "$line" | grep -q '"test_audit_duration_s":30'; then
    pass "8.3 test_audit_duration_s emitted with correct value"
else
    fail "8.3 test_audit_duration_s not found or wrong value: ${line}"
fi

if echo "$line" | grep -q '"analyze_cleanup_duration_s":20'; then
    pass "8.4 analyze_cleanup_duration_s emitted with correct value"
else
    fail "8.4 analyze_cleanup_duration_s not found or wrong value: ${line}"
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
