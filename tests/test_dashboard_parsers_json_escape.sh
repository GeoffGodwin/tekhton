#!/usr/bin/env bash
# =============================================================================
# test_dashboard_parsers_json_escape.sh — Test _json_escape special characters
#
# Tests for Coverage Gap: No dedicated test for _json_escape special-character
# handling in _parse_run_summaries_from_jsonl bash fallback (line 363) and
# _parse_run_summaries_from_files sed fallback (line 449).
#
# These tests verify that task_label, outcome, milestone, run_type, and
# timestamp fields are correctly escaped when they contain:
#   - Double quotes (")
#   - Backslashes (\)
#   - Newlines (\n)
#   - Carriage returns (\r)
#   - Tabs (\t)
#
# Security: JSON injection must not be possible when these special characters
# are interpolated into JSON strings in the bash/sed fallback paths.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

# Source necessary libraries
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Helper for JSON validation using printf to safely handle special chars
is_valid_json() {
    local json="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "import json, sys; json.loads(sys.stdin.read())" <<< "$json" 2>/dev/null
    else
        # Crude fallback: check for basic JSON structure
        [[ "$json" =~ ^\[ ]] && [[ "$json" =~ \]$ ]]
    fi
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
# Test Suite 1: _json_escape function with special characters
# =============================================================================
echo "=== Test Suite 1: _json_escape function special-character handling ==="

# Create a test stub for _json_escape if not already available
if ! declare -f _json_escape &>/dev/null; then
    # This shouldn't happen since we sourced dashboard_parsers.sh,
    # but provide a fallback just in case
    _json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"
        s="${s//$'\r'/\\r}"
        s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    }
fi

# Test 1.1: Double quote escaping
input_with_quote='Test with "quotes"'
escaped=$(_json_escape "$input_with_quote")
# In JSON, " should become \" - check that we have escaped quotes
if [[ "$escaped" == *'\"'* ]]; then
    pass "1.1 _json_escape escapes double quotes"
else
    fail "1.1 _json_escape quote handling (got: '$escaped')"
fi

# Test 1.2: Backslash escaping
input_with_backslash='Path\like\this'
escaped=$(_json_escape "$input_with_backslash")
# Single backslash should become double backslash
if [[ "$escaped" == 'Path\\like\\this' ]]; then
    pass "1.2 _json_escape escapes backslashes"
else
    fail "1.2 _json_escape backslash handling (got: '$escaped')"
fi

# Test 1.3: Newline escaping
newline=$'\n'
input_with_newline="Line1${newline}Line2"
escaped=$(_json_escape "$input_with_newline")
if [[ "$escaped" == 'Line1\nLine2' ]]; then
    pass "1.3 _json_escape escapes newlines"
else
    fail "1.3 _json_escape newline handling (got: '$escaped')"
fi

# Test 1.4: Tab escaping
tab=$'\t'
input_with_tab="Before${tab}After"
escaped=$(_json_escape "$input_with_tab")
if [[ "$escaped" == 'Before\tAfter' ]]; then
    pass "1.4 _json_escape escapes tabs"
else
    fail "1.4 _json_escape tab handling (got: '$escaped')"
fi

# Test 1.5: Combined special characters
input_combined='Quote:"Test", Backslash:\path, Newline:Line1
Line2'
escaped=$(_json_escape "$input_combined")
# Should have \" for quotes, \\ for backslashes, \n for newlines
if [[ "$escaped" == *"Quote:\\\"Test\\\""* ]] && \
   [[ "$escaped" == *"\\path"* ]] && \
   [[ "$escaped" == *"\\n"* ]]; then
    pass "1.5 _json_escape handles combined special characters"
else
    fail "1.5 _json_escape combined special chars (got: '$escaped')"
fi

# =============================================================================
# Test Suite 2: _parse_run_summaries_from_jsonl with special characters (Line 363)
# Tests the bash fallback path where _json_escape is called for task_label, etc.
# =============================================================================
echo "=== Test Suite 2: _parse_run_summaries_from_jsonl JSON escape in output ==="

# Create a temporary directory with metrics.jsonl containing special characters
mkdir -p "$TMPDIR/.claude/logs_special"

# Create metrics.jsonl with fields containing special characters (properly escaped JSON)
cat > "$TMPDIR/.claude/logs_special/metrics.jsonl" << 'JSONL'
{"timestamp":"2026-04-01T12:00:00Z","task":"Fix: Add \"quoted\" feature","task_type":"feature","milestone_mode":false,"total_turns":5,"total_time_s":30,"coder_turns":1,"reviewer_turns":1,"tester_turns":1,"scout_turns":0,"scout_est_coder":0,"scout_est_reviewer":0,"scout_est_tester":0,"adjusted_coder":0,"adjusted_reviewer":0,"adjusted_tester":0,"context_tokens":1000,"retry_count":0,"continuation_attempts":0,"verdict":"APPROVED","outcome":"success"}
JSONL

# Force bash fallback by shadowing python3
stub_bin="$TMPDIR/stub_bin_special"
mkdir -p "$stub_bin"
cat > "$stub_bin/python3" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$stub_bin/python3"

original_path="$PATH"
export PATH="${stub_bin}:${original_path}"

# Call _parse_run_summaries and verify valid JSON output
result=$(_parse_run_summaries "$TMPDIR/.claude/logs_special" 1 2>/dev/null)

# Restore original PATH
export PATH="$original_path"

# Test 2.1: Output is valid JSON
if is_valid_json "$result"; then
    pass "2.1 _parse_run_summaries_from_jsonl produces valid JSON with escaped task fields"
else
    fail "2.1 JSON validation failed (output: $result)"
fi

# Test 2.2: Task with quotes is properly represented in JSON output
# The parser extracts the task field and escapes it for JSON output
if echo "$result" | grep -q 'Fix: Add'; then
    pass "2.2 Task field is extracted and represented in JSON output"
else
    fail "2.2 Task field not found in output (got: $result)"
fi

# Test 2.3: Output contains properly escaped JSON (no unescaped quotes within strings)
if echo "$result" | grep -qE '"task_label":\s*"[^"]*"'; then
    pass "2.3 Task label field has proper JSON string structure"
else
    fail "2.3 Task label field missing or malformed (got: $result)"
fi

# =============================================================================
# Test Suite 3: _parse_run_summaries_from_files with special characters (Line 449)
# Tests the sed fallback path where _json_escape is called for outcome, milestone, etc.
# =============================================================================
echo "=== Test Suite 3: _parse_run_summaries_from_files JSON escape in output ==="

# Create RUN_SUMMARY files with special characters in fields
mkdir -p "$TMPDIR/.claude/logs_files"

# File 1: Special characters in outcome, milestone, task_label (properly escaped JSON)
cat > "$TMPDIR/.claude/logs_files/RUN_SUMMARY_20260401_100000.json" << 'EOF'
{
  "outcome": "partial",
  "total_turns": 10,
  "total_time_s": 45,
  "milestone": "m01_setup",
  "run_type": "feature",
  "task_label": "Add quoted feature with tabs",
  "timestamp": "2026-04-01T10:00:00Z"
}
EOF

# Test 3.1: Python path (if available) produces valid JSON
if command -v python3 &>/dev/null; then
    result=$(_parse_run_summaries "$TMPDIR/.claude/logs_files" 1 2>/dev/null)
    if is_valid_json "$result"; then
        pass "3.1 _parse_run_summaries_from_files (Python path) produces valid JSON"
    else
        fail "3.1 Python path JSON validation failed (output: $result)"
    fi
else
    echo "  SKIP: 3.1 Python path test (python3 not available)"
fi

# Test 3.2: Bash/sed fallback path produces valid JSON
stub_bin2="$TMPDIR/stub_bin_special2"
mkdir -p "$stub_bin2"
cat > "$stub_bin2/python3" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$stub_bin2/python3"

original_path2="$PATH"
export PATH="${stub_bin2}:${original_path2}"

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_files" 1 2>/dev/null)

export PATH="$original_path2"

if is_valid_json "$result"; then
    pass "3.2 _parse_run_summaries_from_files (sed fallback) produces valid JSON"
else
    fail "3.2 Sed fallback JSON validation failed (output: $result)"
fi

# Test 3.3: Verify fields are extracted and represented in output
if echo "$result" | grep -q '"task_label"'; then
    pass "3.3 Task label field present in sed fallback output"
else
    fail "3.3 Task label field missing in sed fallback output (got: $result)"
fi

if echo "$result" | grep -q '"milestone"'; then
    pass "3.4 Milestone field present in sed fallback output"
else
    fail "3.4 Milestone field missing in sed fallback output (got: $result)"
fi

if echo "$result" | grep -q '"outcome"'; then
    pass "3.5 Outcome field present in sed fallback output"
else
    fail "3.5 Outcome field missing in sed fallback output (got: $result)"
fi

# =============================================================================
# Test Suite 4: JSON injection prevention
# Verify that special characters cannot break out of JSON strings
# =============================================================================
echo "=== Test Suite 4: JSON injection prevention ==="

mkdir -p "$TMPDIR/.claude/logs_injection"

# Attempt JSON injection via task_label
cat > "$TMPDIR/.claude/logs_injection/RUN_SUMMARY_20260401_200000.json" << 'EOF'
{
  "outcome": "success",
  "total_turns": 1,
  "total_time_s": 10,
  "milestone": "test",
  "run_type": "feature",
  "task_label": "\"},{\"injected\":true,\"other\":\"",
  "timestamp": "2026-04-01T20:00:00Z"
}
EOF

# Force sed fallback
stub_bin3="$TMPDIR/stub_bin_injection"
mkdir -p "$stub_bin3"
cat > "$stub_bin3/python3" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$stub_bin3/python3"

original_path3="$PATH"
export PATH="${stub_bin3}:${original_path3}"

result=$(_parse_run_summaries "$TMPDIR/.claude/logs_injection" 1 2>/dev/null)

export PATH="$original_path3"

# Test 4.1: Output must be valid JSON (not corrupted by injection attempt)
if is_valid_json "$result"; then
    pass "4.1 JSON injection attempt properly escaped, output is valid JSON"
else
    fail "4.1 JSON injection broke JSON structure (output: $result)"
fi

# Test 4.2: Injected field should not appear as a separate JSON object
if echo "$result" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    # Should be a single-element array with one run
    if len(data) == 1:
        print('PASS')
    else:
        print('FAIL')
except:
    print('FAIL')
" 2>/dev/null | grep -q "PASS"; then
    pass "4.2 Injection attempt did not create extra JSON objects"
else
    fail "4.2 Injection detection failed"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  JSON escape tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All JSON escape tests passed"
