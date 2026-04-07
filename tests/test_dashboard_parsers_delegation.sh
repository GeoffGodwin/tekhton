#!/usr/bin/env bash
# =============================================================================
# test_dashboard_parsers_delegation.sh — Verify file-split delegation pattern
#
# Tests that sourcing dashboard_parsers.sh alone is sufficient to make
# _parse_run_summaries callable. This verifies that the delegation to
# dashboard_parsers_runs.sh works end-to-end without requiring explicit
# sourcing of the companion file.
#
# Coverage gap resolution: REVIEWER_REPORT.md noted that no test explicitly
# verified the source delegation pattern works end-to-end.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

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

# Helper for JSON escaping (required by dashboard_parsers.sh)
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# =============================================================================
# Test Suite 1: Verify delegation pattern — source only dashboard_parsers.sh
# =============================================================================
echo "=== Test Suite 1: File-split delegation verification ==="

# Clear environment to ensure clean sourcing
unset _parse_run_summaries _parse_run_summaries_from_jsonl _parse_run_summaries_from_files 2>/dev/null || true

# SOURCE ONLY dashboard_parsers.sh (not dashboard_parsers_runs.sh)
# If the delegation pattern is correct, sourcing this file should make
# functions from dashboard_parsers_runs.sh available
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Test 1a: Verify _parse_run_summaries is callable
if declare -f _parse_run_summaries &>/dev/null; then
    pass "1a.1 _parse_run_summaries function is defined after sourcing dashboard_parsers.sh"
else
    fail "1a.1 _parse_run_summaries function NOT defined (delegation failed)"
fi

# Test 1b: Verify _parse_run_summaries_from_jsonl is callable
if declare -f _parse_run_summaries_from_jsonl &>/dev/null; then
    pass "1a.2 _parse_run_summaries_from_jsonl function is defined after sourcing dashboard_parsers.sh"
else
    fail "1a.2 _parse_run_summaries_from_jsonl function NOT defined (delegation failed)"
fi

# Test 1c: Verify _parse_run_summaries_from_files is callable
if declare -f _parse_run_summaries_from_files &>/dev/null; then
    pass "1a.3 _parse_run_summaries_from_files function is defined after sourcing dashboard_parsers.sh"
else
    fail "1a.3 _parse_run_summaries_from_files function NOT defined (delegation failed)"
fi

# Test 1d: Verify dashboard_parsers.sh functions are also callable
if declare -f _parse_security_report &>/dev/null; then
    pass "1a.4 _parse_security_report function is defined (dashboard_parsers.sh content)"
else
    fail "1a.4 _parse_security_report function NOT defined (dashboard_parsers.sh not sourced)"
fi

# =============================================================================
# Test Suite 2: End-to-end delegation functionality (primary path: metrics.jsonl)
# =============================================================================
echo "=== Test Suite 2: Delegation end-to-end — metrics.jsonl primary path ==="

# Create a logs directory with metrics.jsonl
mkdir -p "$TMPDIR/.claude/logs"

# Create metrics.jsonl with test data
cat > "$TMPDIR/.claude/logs/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-02T10:00:00Z","task":"Test task 1","task_type":"feature","milestone_mode":false,"total_turns":15,"total_time_s":120,"coder_turns":5,"reviewer_turns":3,"tester_turns":2,"scout_turns":4,"scout_est_coder":20,"scout_est_reviewer":5,"scout_est_tester":10,"adjusted_coder":15,"adjusted_reviewer":3,"adjusted_tester":8,"context_tokens":5000,"retry_count":0,"continuation_attempts":0,"verdict":"APPROVED","outcome":"success"}
{"timestamp":"2026-04-02T11:00:00Z","task":"Test task 2","task_type":"bug","milestone_mode":false,"total_turns":22,"total_time_s":180,"coder_turns":8,"reviewer_turns":4,"tester_turns":3,"scout_turns":5,"scout_est_coder":25,"scout_est_reviewer":6,"scout_est_tester":12,"adjusted_coder":20,"adjusted_reviewer":4,"adjusted_tester":10,"context_tokens":5500,"retry_count":0,"continuation_attempts":0,"verdict":"APPROVED_WITH_NOTES","outcome":"success"}
JSONL

# Call _parse_run_summaries via the delegated function
result=$(_parse_run_summaries "$TMPDIR/.claude/logs" 10 2>/dev/null)

# Verify we got valid JSON output
if echo "$result" | grep -q '^\['; then
    pass "2.1 _parse_run_summaries returns valid JSON array"
else
    fail "2.1 _parse_run_summaries did not return valid JSON (got: $result)"
fi

# Verify we got both entries (parser uses task_label, not task)
if echo "$result" | grep -qE '"task_label"\s*:\s*"Test task 1"'; then
    pass "2.2 _parse_run_summaries includes first metrics entry"
else
    fail "2.2 _parse_run_summaries missing first entry (got: $result)"
fi

if echo "$result" | grep -qE '"task_label"\s*:\s*"Test task 2"'; then
    pass "2.3 _parse_run_summaries includes second metrics entry"
else
    fail "2.3 _parse_run_summaries missing second entry (got: $result)"
fi

# Verify field values are correctly extracted
if echo "$result" | grep -qE '"total_turns".*15|"total_turns": 15'; then
    pass "2.4 _parse_run_summaries extracts total_turns field from metrics.jsonl"
else
    fail "2.4 _parse_run_summaries failed to extract total_turns (got: $result)"
fi

if echo "$result" | grep -qE '"total_time_s".*120|"total_time_s": 120'; then
    pass "2.5 _parse_run_summaries extracts total_time_s field from metrics.jsonl"
else
    fail "2.5 _parse_run_summaries failed to extract total_time_s (got: $result)"
fi

# =============================================================================
# Test Suite 3: End-to-end delegation functionality (fallback path: RUN_SUMMARY files)
# =============================================================================
echo "=== Test Suite 3: Delegation end-to-end — RUN_SUMMARY files fallback ==="

# Clean up metrics.jsonl to force fallback path
rm "$TMPDIR/.claude/logs/metrics.jsonl"

# Create RUN_SUMMARY files instead
cat > "$TMPDIR/.claude/logs/RUN_SUMMARY_20260402_100000.json" << 'EOF'
{
  "outcome": "success",
  "total_agent_calls": 10,
  "wall_clock_seconds": 90,
  "milestone": "m05_test",
  "task": "Fallback test 1"
}
EOF

cat > "$TMPDIR/.claude/logs/RUN_SUMMARY_20260402_110000.json" << 'EOF'
{
  "outcome": "success",
  "total_agent_calls": 18,
  "wall_clock_seconds": 150,
  "milestone": "m06_test",
  "task": "Fallback test 2"
}
EOF

# Call _parse_run_summaries (should use fallback path now)
result_fallback=$(_parse_run_summaries "$TMPDIR/.claude/logs" 10 2>/dev/null)

# Verify we got valid JSON output from fallback
if echo "$result_fallback" | grep -q '^\['; then
    pass "3.1 _parse_run_summaries fallback path returns valid JSON array"
else
    fail "3.1 _parse_run_summaries fallback did not return valid JSON (got: $result_fallback)"
fi

# Verify fallback included entries from RUN_SUMMARY files
if echo "$result_fallback" | grep -qE '"total_turns".*10|"total_turns": 10'; then
    pass "3.2 _parse_run_summaries fallback extracts total_agent_calls"
else
    fail "3.2 _parse_run_summaries fallback failed to extract total_agent_calls (got: $result_fallback)"
fi

if echo "$result_fallback" | grep -qE '"total_time_s".*90|"total_time_s": 90'; then
    pass "3.3 _parse_run_summaries fallback extracts wall_clock_seconds"
else
    fail "3.3 _parse_run_summaries fallback failed to extract wall_clock_seconds (got: $result_fallback)"
fi

if echo "$result_fallback" | grep -qE '"milestone"\s*:\s*"m0[56]_test"'; then
    pass "3.4 _parse_run_summaries fallback extracts milestone field"
else
    fail "3.4 _parse_run_summaries fallback failed to extract milestone (got: $result_fallback)"
fi

# =============================================================================
# Test Suite 4: Verify helper functions from dashboard_parsers_runs.sh work
# =============================================================================
echo "=== Test Suite 4: Delegated helper functions ==="

# Create test data for _parse_run_summaries_from_files (bash fallback)
mkdir -p "$TMPDIR/.claude/logs_bash"
cat > "$TMPDIR/.claude/logs_bash/RUN_SUMMARY_20260402_120000.json" << 'EOF'
{"outcome":"success","total_agent_calls":25,"wall_clock_seconds":200,"task":"Direct bash fallback test"}
EOF

# Force bash fallback by shadowing python3
stub_bin="$TMPDIR/stub_bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/python3" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$stub_bin/python3"

original_path="$PATH"
export PATH="${stub_bin}:${original_path}"

# Call _parse_run_summaries_from_files directly (verify it's callable and works)
if declare -f _parse_run_summaries_from_files &>/dev/null; then
    result_files=$(_parse_run_summaries_from_files "$TMPDIR/.claude/logs_bash" 10 2>/dev/null)

    if echo "$result_files" | grep -q '^\['; then
        pass "4.1 _parse_run_summaries_from_files returns valid JSON"
    else
        fail "4.1 _parse_run_summaries_from_files did not return valid JSON (got: $result_files)"
    fi

    if echo "$result_files" | grep -qE '"total_turns".*25|"total_turns": 25'; then
        pass "4.2 _parse_run_summaries_from_files extracts total_agent_calls correctly"
    else
        fail "4.2 _parse_run_summaries_from_files failed (got: $result_files)"
    fi
else
    fail "4.1 _parse_run_summaries_from_files not callable"
    fail "4.2 _parse_run_summaries_from_files not callable"
fi

# Restore PATH
export PATH="$original_path"

# =============================================================================
# Test Suite 5: Verify the source directive and shellcheck comment
# =============================================================================
echo "=== Test Suite 5: Source directive validation ==="

# Check that dashboard_parsers.sh contains the source delegation
if grep -q 'source.*dashboard_parsers_runs.sh' "${TEKHTON_HOME}/lib/dashboard_parsers.sh"; then
    pass "5.1 dashboard_parsers.sh contains source delegation to dashboard_parsers_runs.sh"
else
    fail "5.1 dashboard_parsers.sh missing source delegation"
fi

# Check that shellcheck directive is present
if grep -q '# shellcheck source=' "${TEKHTON_HOME}/lib/dashboard_parsers.sh"; then
    pass "5.2 dashboard_parsers.sh contains shellcheck source directive"
else
    fail "5.2 dashboard_parsers.sh missing shellcheck directive"
fi

# Verify dashboard_parsers_runs.sh exists
if [[ -f "${TEKHTON_HOME}/lib/dashboard_parsers_runs.sh" ]]; then
    pass "5.3 dashboard_parsers_runs.sh file exists"
else
    fail "5.3 dashboard_parsers_runs.sh file does not exist"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  delegation tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All delegation tests passed"
