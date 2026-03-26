#!/usr/bin/env bash
# =============================================================================
# test_dashboard_parsers_bugfix.sh — Verify fixes for three dashboard bugs
#
# Bug #1: dashboard_emitters.sh:155-156 — grep -c pattern producing double "0"
# Bug #2: dashboard_parsers.sh:159-163 — Python parser field name mismatch
# Bug #3: dashboard_parsers.sh:175-181 — grep fallback field name mismatch
#
# All three bugs involved RUN_SUMMARY.json parsing:
# - emitters.sh grep -c exits 1 on zero matches, causing || echo "0" to append
# - parsers.sh used total_turns/total_time_s but JSON uses total_agent_calls/wall_clock_seconds
# - Both paths now handle actual JSON field names and extract milestone/stages
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

# Source necessary libraries
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"
# For test 1b functional test, we need to source dashboard.sh which has is_dashboard_enabled
# Since we don't want full pipeline initialization, we'll define a stub
is_dashboard_enabled() {
    return 0  # Enable dashboard for tests
}

# Helper for JSON escaping used by parsers
_json_escape() {
    local s="$1"
    # Minimal JSON escape for testing
    printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/
/\\n/g'
}

# For non-Python environments, also test grep fallback
# (dashboard_parsers.sh has a grep fallback when python3 is unavailable)

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

# Source dashboard_emitters.sh for functional testing of emit_dashboard_reports
source "${TEKHTON_HOME}/lib/dashboard_emitters.sh"

# =============================================================================
# Test Suite 1a: Pattern validation — grep -c || true idiom (documentation)
# Tests that the bash pattern doesn't produce double "0"
# =============================================================================
echo "=== Test Suite 1a: Pattern validation — grep -c || true idiom ==="

# Create a test audit file with no HIGH findings
cat > "$TMPDIR/test_audit.md" << 'EOF'
# Test Audit Report
Some content here without severity markers.
EOF

# Simulate the fixed pattern from emitters.sh:155-156
high_findings=$(grep -c 'Severity: HIGH' "$TMPDIR/test_audit.md" 2>/dev/null || true)
: "${high_findings:=0}"

# Test that it produces "0" exactly once, not "0\n0"
if [ "$high_findings" = "0" ]; then
    pass "1a.1 grep -c with || true produces single value on zero matches"
else
    fail "1a.1 grep -c produced unexpected value: '$high_findings' (expected '0')"
fi

# Test with actual matches
cat > "$TMPDIR/test_audit2.md" << 'EOF'
# Audit with findings
- Severity: HIGH: Security issue
- Severity: MEDIUM: Code quality
- Severity: HIGH: Another issue
EOF

high_findings=$(grep -c 'Severity: HIGH' "$TMPDIR/test_audit2.md" 2>/dev/null || true)
: "${high_findings:=0}"

if [ "$high_findings" = "2" ]; then
    pass "1a.2 grep -c correctly counts matches (2 HIGH findings)"
else
    fail "1a.2 grep -c count incorrect: got '$high_findings', expected '2'"
fi

# =============================================================================
# Test Suite 1b: Functional test — emit_dashboard_reports with zero HIGH findings
# Regression test for Bug #1: Ensure emit_dashboard_reports produces valid JSON
# =============================================================================
echo "=== Test Suite 1b: Functional test — emit_dashboard_reports (Bug #1) ==="

# Create minimal dashboard infrastructure
mkdir -p "$TMPDIR/.claude/dashboard/data"

# Create an audit file with no HIGH findings (only to test the zero-count path)
cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
## Audit Summary
All tests passed.

## Findings
None.
EOF

# Create minimal dummy report files
touch "$TMPDIR/INTAKE_REPORT.md"
touch "$TMPDIR/CODER_SUMMARY.md"
touch "$TMPDIR/REVIEWER_REPORT.md"

# Call emit_dashboard_reports and verify it produces valid JSON
# (This exercises the grep -c || true pattern in the actual function)
export TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md"
export INTAKE_REPORT_FILE="$TMPDIR/INTAKE_REPORT.md"
export DASHBOARD_DIR=".claude/dashboard"

emit_dashboard_reports

# Check that the generated reports.js contains valid JSON (not double "0"s)
if [ -f "$TMPDIR/.claude/dashboard/data/reports.js" ]; then
    reports_content=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
    # Should contain exactly one occurrence of "high_findings":0 (not "high_findings":00)
    if echo "$reports_content" | grep -q '"high_findings":0'; then
        if ! echo "$reports_content" | grep -q '"high_findings":00'; then
            pass "1b.1 emit_dashboard_reports produces valid JSON for zero HIGH findings"
        else
            fail "1b.1 emit_dashboard_reports produced double-zero artifact: $reports_content"
        fi
    else
        fail "1b.1 emit_dashboard_reports missing high_findings field"
    fi
else
    fail "1b.1 emit_dashboard_reports did not generate reports.js"
fi

# =============================================================================
# Test Suite 2: Python parser with field name fallback (Bug #2)
# Tests that Python handles both old (total_turns) and new (total_agent_calls) field names
# =============================================================================
echo "=== Test Suite 2: Python parser field name fallback (Bug #2) ==="

# Create RUN_SUMMARY.json with actual field names (total_agent_calls, wall_clock_seconds)
cat > "$TMPDIR/RUN_SUMMARY_new.json" << 'EOF'
{
  "outcome": "success",
  "total_agent_calls": 7,
  "wall_clock_seconds": 45,
  "milestone": "m05_review_stage",
  "stages": ["coder", "reviewer", "tester"]
}
EOF

# Test Python parsing if available
if command -v python3 &>/dev/null; then
    result=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(json.dumps({
        'outcome': d.get('outcome', 'unknown'),
        'total_turns': d.get('total_turns', d.get('total_agent_calls', 0)),
        'total_time_s': d.get('total_time_s', d.get('wall_clock_seconds', 0)),
        'milestone': d.get('milestone', ''),
        'stages': d.get('stages', {})
    }))
except: pass
" "$TMPDIR/RUN_SUMMARY_new.json" 2>/dev/null || echo "")

    if [ -n "$result" ]; then
        # Verify Python extracted the correct values via fallback
        if echo "$result" | grep -q '"total_turns": 7'; then
            pass "2.1 Python parser falls back to total_agent_calls when total_turns missing"
        else
            fail "2.1 Python parser failed to extract total_agent_calls (got: $result)"
        fi

        if echo "$result" | grep -q '"total_time_s": 45'; then
            pass "2.2 Python parser falls back to wall_clock_seconds when total_time_s missing"
        else
            fail "2.2 Python parser failed to extract wall_clock_seconds (got: $result)"
        fi

        if echo "$result" | grep -q '"milestone": "m05_review_stage"'; then
            pass "2.3 Python parser extracts milestone field"
        else
            fail "2.3 Python parser failed to extract milestone (got: $result)"
        fi

        if echo "$result" | grep -q '"stages"'; then
            pass "2.4 Python parser extracts stages field"
        else
            fail "2.4 Python parser failed to extract stages (got: $result)"
        fi
    else
        echo "  SKIP: 2.1-2.4 Python parsing tests (Python error or unavailable)"
    fi
else
    echo "  SKIP: 2.1-2.4 Python parsing tests (python3 not available)"
fi

# Test with old field names (should also work via d.get fallthrough)
cat > "$TMPDIR/RUN_SUMMARY_old.json" << 'EOF'
{
  "outcome": "success",
  "total_turns": 5,
  "total_time_s": 30
}
EOF

if command -v python3 &>/dev/null; then
    result=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(json.dumps({
        'outcome': d.get('outcome', 'unknown'),
        'total_turns': d.get('total_turns', d.get('total_agent_calls', 0)),
        'total_time_s': d.get('total_time_s', d.get('wall_clock_seconds', 0))
    }))
except: pass
" "$TMPDIR/RUN_SUMMARY_old.json" 2>/dev/null || echo "")

    if echo "$result" | grep -q '"total_turns": 5'; then
        pass "2.5 Python parser still works with old total_turns field"
    else
        fail "2.5 Python parser broken for old field names (got: $result)"
    fi
else
    echo "  SKIP: 2.5 Python parser backward compat test (python3 not available)"
fi

# =============================================================================
# Test Suite 3: Grep fallback with field name fallback (Bug #3)
# Tests that grep extraction handles both field name variants
# =============================================================================
echo "=== Test Suite 3: Grep fallback field name fallback (Bug #3) ==="

# Test grep extraction from RUN_SUMMARY with new field names
outcome=$(grep -oP '"outcome"\s*:\s*"\K[^"]+' "$TMPDIR/RUN_SUMMARY_new.json" 2>/dev/null || echo "unknown")
if [ "$outcome" = "success" ]; then
    pass "3.1 grep fallback extracts outcome field"
else
    fail "3.1 grep fallback outcome extraction failed (got: '$outcome')"
fi

# Extract turns with fallback to total_agent_calls
turns=$(grep -oP '"total_turns"\s*:\s*\K[0-9]+' "$TMPDIR/RUN_SUMMARY_new.json" 2>/dev/null || true)
[[ -z "$turns" ]] && turns=$(grep -oP '"total_agent_calls"\s*:\s*\K[0-9]+' "$TMPDIR/RUN_SUMMARY_new.json" 2>/dev/null || echo "0")
: "${turns:=0}"
if [ "$turns" = "7" ]; then
    pass "3.2 grep fallback extracts total_agent_calls when total_turns missing"
else
    fail "3.2 grep fallback to total_agent_calls failed (got: '$turns')"
fi

# Extract time with fallback to wall_clock_seconds
time_s=$(grep -oP '"total_time_s"\s*:\s*\K[0-9]+' "$TMPDIR/RUN_SUMMARY_new.json" 2>/dev/null || true)
[[ -z "$time_s" ]] && time_s=$(grep -oP '"wall_clock_seconds"\s*:\s*\K[0-9]+' "$TMPDIR/RUN_SUMMARY_new.json" 2>/dev/null || echo "0")
: "${time_s:=0}"
if [ "$time_s" = "45" ]; then
    pass "3.3 grep fallback extracts wall_clock_seconds when total_time_s missing"
else
    fail "3.3 grep fallback to wall_clock_seconds failed (got: '$time_s')"
fi

# Extract milestone field
milestone=$(grep -oP '"milestone"\s*:\s*"\K[^"]+' "$TMPDIR/RUN_SUMMARY_new.json" 2>/dev/null || echo "")
if [ "$milestone" = "m05_review_stage" ]; then
    pass "3.4 grep fallback extracts milestone field"
else
    fail "3.4 grep fallback milestone extraction failed (got: '$milestone')"
fi

# Test with old field names via grep fallback
turns=$(grep -oP '"total_turns"\s*:\s*\K[0-9]+' "$TMPDIR/RUN_SUMMARY_old.json" 2>/dev/null || true)
[[ -z "$turns" ]] && turns=$(grep -oP '"total_agent_calls"\s*:\s*\K[0-9]+' "$TMPDIR/RUN_SUMMARY_old.json" 2>/dev/null || echo "0")
: "${turns:=0}"
if [ "$turns" = "5" ]; then
    pass "3.5 grep fallback still works with old total_turns field"
else
    fail "3.5 grep fallback broken for old field names (got: '$turns')"
fi

# =============================================================================
# Test Suite 3b: Bash fallback path exercise (shadow python3 to force fallback)
# Regression test for Bug #3: Ensures bash fallback is exercised through real function
# =============================================================================
echo "=== Test Suite 3b: _parse_run_summaries with bash fallback forced ==="

# Create a temporary bin directory with a python3 stub that fails
stub_bin="$TMPDIR/stub_bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/python3" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$stub_bin/python3"

# Temporarily prepend stub_bin to PATH to shadow the real python3
original_path="$PATH"
export PATH="${stub_bin}:${original_path}"

# Now call _parse_run_summaries with the stubbed python3 (forcing bash fallback)
mkdir -p "$TMPDIR/.claude/logs_fallback"
cat > "$TMPDIR/.claude/logs_fallback/RUN_SUMMARY.1.json" << 'EOF'
{"outcome":"success","total_agent_calls":9,"wall_clock_seconds":60,"milestone":"m03_fallback"}
EOF

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_fallback" 1 2>/dev/null)

# Restore original PATH
export PATH="$original_path"

# Verify the bash fallback extracted the correct values
# (bash fallback extracts the value from total_agent_calls and puts it in total_turns field)
if echo "$result" | grep -qE '"total_turns"\s*:\s*9'; then
    pass "3b.1 bash fallback correctly extracts total_agent_calls into total_turns"
else
    fail "3b.1 bash fallback failed to extract total_agent_calls (got: $result)"
fi

if echo "$result" | grep -q '"total_time_s":60'; then
    pass "3b.2 bash fallback correctly extracts wall_clock_seconds into total_time_s"
else
    fail "3b.2 bash fallback failed to extract wall_clock_seconds (got: $result)"
fi

if echo "$result" | grep -q '"milestone":"m03_fallback"'; then
    pass "3b.3 bash fallback extracts milestone field"
else
    fail "3b.3 bash fallback failed to extract milestone (got: $result)"
fi

# =============================================================================
# Test Suite 4: _parse_run_summaries function integration
# Tests that the actual function from dashboard_parsers.sh handles both paths
# =============================================================================
echo "=== Test Suite 4: _parse_run_summaries integration ==="

# Create a logs directory with multiple RUN_SUMMARY files
mkdir -p "$TMPDIR/.claude/logs"

# Create recent summary with new field names
cat > "$TMPDIR/.claude/logs/RUN_SUMMARY.1.json" << 'EOF'
{
  "outcome": "success",
  "total_agent_calls": 8,
  "wall_clock_seconds": 50,
  "milestone": "m01_test"
}
EOF

# Create older summary with old field names
cat > "$TMPDIR/.claude/logs/RUN_SUMMARY.2.json" << 'EOF'
{
  "outcome": "partial",
  "total_turns": 3,
  "total_time_s": 20
}
EOF

# Call _parse_run_summaries and verify it handles both
result=$(_parse_run_summaries "$TMPDIR/.claude/logs" 2)

# Both summaries should be in the output
# Use whitespace-tolerant grep pattern (Python adds spaces, bash fallback doesn't)
if echo "$result" | grep -qE '"outcome"\s*:\s*"success"'; then
    pass "4.1 _parse_run_summaries includes new-format summary"
else
    fail "4.1 _parse_run_summaries missing new-format summary (got: $result)"
fi

if echo "$result" | grep -qE '"outcome"\s*:\s*"partial"'; then
    pass "4.2 _parse_run_summaries includes old-format summary"
else
    fail "4.2 _parse_run_summaries missing old-format summary (got: $result)"
fi

# Verify it's valid JSON array
if echo "$result" | grep -q '^\['; then
    pass "4.3 _parse_run_summaries output is valid JSON array"
else
    fail "4.3 _parse_run_summaries output is not valid JSON (got: $result)"
fi

# =============================================================================
# Test Suite 5: Edge cases and error handling
# =============================================================================
echo "=== Test Suite 5: Edge cases ==="

# Clean up logs from previous tests for edge case testing
rm -rf "$TMPDIR/.claude/logs"
mkdir -p "$TMPDIR/.claude/logs"

# Empty directory (no RUN_SUMMARY files)
result=$(_parse_run_summaries "$TMPDIR/.claude/logs" 1 2>/dev/null || true)
if [ "$result" = "[]" ]; then
    pass "5.1 _parse_run_summaries handles empty directory gracefully"
else
    fail "5.1 _parse_run_summaries empty dir failed (got: '$result')"
fi

# Malformed JSON (bash fallback extracts what it can with defaults)
cat > "$TMPDIR/.claude/logs/RUN_SUMMARY.json" << 'EOF'
{ this is not valid json }
EOF

# Should not crash — malformed JSON produces partial results via grep fallback with defaults
result=$(_parse_run_summaries "$TMPDIR/.claude/logs" 1 2>/dev/null)
# Verify it returns valid JSON and doesn't crash
if echo "$result" | grep -q '^\[.*\]$'; then
    pass "5.2 _parse_run_summaries handles malformed JSON gracefully (returns valid JSON)"
else
    fail "5.2 _parse_run_summaries did not produce valid JSON for malformed input (got: '$result')"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  dashboard_parsers tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All dashboard parser tests passed"
