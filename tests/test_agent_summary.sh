#!/usr/bin/env bash
# =============================================================================
# test_agent_summary.sh — Tests for _append_agent_summary (12.3 log summaries)
#
# Tests:
#   1. Success run produces a summary block with Class: SUCCESS
#   2. Failure with error classification includes category in Class field
#   3. Failure with error classification includes recovery suggestion
#   4. Summary block is redacted via redact_sensitive
#   5. Unicode/ASCII fallback works correctly
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/errors.sh"

# Source agent_helpers directly (it normally gets sourced by agent.sh)
# Set globals that agent_helpers expects
LAST_AGENT_NULL_RUN=false
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/agent_helpers.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# _append_agent_summary — success run
# =============================================================================

echo "=== _append_agent_summary: success run ==="

LOG_FILE="${TMPDIR_TEST}/test_success.log"
touch "$LOG_FILE"

# Reset error globals
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""
LAST_AGENT_NULL_RUN=false

_append_agent_summary "Coder" "claude-sonnet-4-20250514" "25" "50" "12" "34" "0" "8" "$LOG_FILE"

content=$(cat "$LOG_FILE")

if echo "$content" | grep -q "Agent Run Summary"; then
    pass "success run: summary block header present"
else
    fail "success run: missing 'Agent Run Summary' header"
fi

if echo "$content" | grep -q "Agent:.*Coder"; then
    pass "success run: agent label present"
else
    fail "success run: missing agent label"
fi

if echo "$content" | grep -q "Turns:.*25 / 50"; then
    pass "success run: turns present"
else
    fail "success run: missing turns line"
fi

if echo "$content" | grep -q "Duration:.*12m 34s"; then
    pass "success run: duration present"
else
    fail "success run: missing duration line"
fi

if echo "$content" | grep -q "Exit Code: 0"; then
    pass "success run: exit code 0"
else
    fail "success run: missing exit code"
fi

if echo "$content" | grep -q "Class:.*SUCCESS"; then
    pass "success run: Class is SUCCESS"
else
    fail "success run: expected Class: SUCCESS, got: $(grep 'Class:' "$LOG_FILE" || echo 'not found')"
fi

if echo "$content" | grep -q "Files:.*8 modified"; then
    pass "success run: files modified count"
else
    fail "success run: missing files count"
fi

# =============================================================================
# _append_agent_summary — failure with error classification
# =============================================================================

echo "=== _append_agent_summary: failure with error classification ==="

LOG_FILE="${TMPDIR_TEST}/test_failure.log"
touch "$LOG_FILE"

AGENT_ERROR_CATEGORY="UPSTREAM"
AGENT_ERROR_SUBCATEGORY="api_500"
AGENT_ERROR_TRANSIENT="true"
AGENT_ERROR_MESSAGE="API server error (HTTP 500)"
LAST_AGENT_NULL_RUN=false

_append_agent_summary "Coder" "claude-sonnet-4-20250514" "2" "50" "0" "15" "1" "0" "$LOG_FILE"

content=$(cat "$LOG_FILE")

if echo "$content" | grep -q "Class:.*UPSTREAM/api_500"; then
    pass "failure run: Class shows error category/subcategory"
else
    fail "failure run: expected Class: UPSTREAM/api_500, got: $(grep 'Class:' "$LOG_FILE" || echo 'not found')"
fi

if echo "$content" | grep -q "Error:.*API server error"; then
    pass "failure run: error message present"
else
    fail "failure run: missing error message"
fi

if echo "$content" | grep -q "Recovery:"; then
    pass "failure run: recovery suggestion present"
else
    fail "failure run: missing recovery suggestion"
fi

# =============================================================================
# _append_agent_summary — null run
# =============================================================================

echo "=== _append_agent_summary: null run ==="

LOG_FILE="${TMPDIR_TEST}/test_null.log"
touch "$LOG_FILE"

AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""
LAST_AGENT_NULL_RUN=true

_append_agent_summary "Coder" "claude-sonnet-4-20250514" "0" "50" "0" "5" "1" "0" "$LOG_FILE"

content=$(cat "$LOG_FILE")

if echo "$content" | grep -q "Class:.*NULL_RUN"; then
    pass "null run: Class is NULL_RUN"
else
    fail "null run: expected Class: NULL_RUN, got: $(grep 'Class:' "$LOG_FILE" || echo 'not found')"
fi

# =============================================================================
# _append_agent_summary — tail-friendly (summary at end of file)
# =============================================================================

echo "=== _append_agent_summary: tail-friendly ==="

LOG_FILE="${TMPDIR_TEST}/test_tail.log"
echo "Line 1 of agent log" > "$LOG_FILE"
echo "Line 2 of agent log" >> "$LOG_FILE"
echo "Many more lines..." >> "$LOG_FILE"

AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
LAST_AGENT_NULL_RUN=false

_append_agent_summary "Tester" "claude-sonnet-4-20250514" "10" "20" "2" "30" "0" "3" "$LOG_FILE"

# Last 20 lines should contain the summary
tail_content=$(tail -20 "$LOG_FILE")
if echo "$tail_content" | grep -q "Agent Run Summary"; then
    pass "tail-friendly: summary in last 20 lines"
else
    fail "tail-friendly: summary not in last 20 lines"
fi

# =============================================================================
# _append_agent_summary — redact_sensitive integration
# =============================================================================

echo "=== _append_agent_summary: redact_sensitive integration ==="

LOG_FILE="${TMPDIR_TEST}/test_redact.log"
touch "$LOG_FILE"

AGENT_ERROR_CATEGORY="UPSTREAM"
AGENT_ERROR_SUBCATEGORY="api_auth"
AGENT_ERROR_TRANSIENT="true"
AGENT_ERROR_MESSAGE="Authentication failed: sk-ant-api03-FAKEKEYVALUE123 ANTHROPIC_API_KEY=sk-ant-secret99"
LAST_AGENT_NULL_RUN=false

_append_agent_summary "Coder" "claude-sonnet-4-20250514" "1" "50" "0" "5" "1" "0" "$LOG_FILE"

content=$(cat "$LOG_FILE")

if ! echo "$content" | grep -qF "sk-ant-"; then
    pass "redaction: sk-ant-* key not present in log output"
else
    fail "redaction: sk-ant-* key leaked into log output"
fi

if ! echo "$content" | grep -qF "ANTHROPIC_API_KEY=sk-ant"; then
    pass "redaction: ANTHROPIC_API_KEY value not present in log output"
else
    fail "redaction: ANTHROPIC_API_KEY value leaked into log output"
fi

if echo "$content" | grep -q "REDACTED"; then
    pass "redaction: [REDACTED] placeholder present in log output"
else
    fail "redaction: expected [REDACTED] placeholder in log output"
fi

# Request IDs must NOT be redacted
LOG_FILE="${TMPDIR_TEST}/test_redact_reqid.log"
touch "$LOG_FILE"

AGENT_ERROR_CATEGORY="UPSTREAM"
AGENT_ERROR_SUBCATEGORY="api_500"
AGENT_ERROR_TRANSIENT="true"
AGENT_ERROR_MESSAGE="Server error. Request ID: req_011CZ9DVbXFAKEREQID"
LAST_AGENT_NULL_RUN=false

_append_agent_summary "Coder" "claude-sonnet-4-20250514" "1" "50" "0" "5" "1" "0" "$LOG_FILE"

content=$(cat "$LOG_FILE")

if echo "$content" | grep -q "req_011CZ9DVbXFAKEREQID"; then
    pass "redaction: Anthropic request ID preserved in log output"
else
    fail "redaction: Anthropic request ID was incorrectly redacted"
fi

# =============================================================================
# _append_agent_summary — Unicode/ASCII fallback
# =============================================================================

echo "=== _append_agent_summary: Unicode/ASCII fallback ==="

LOG_FILE="${TMPDIR_TEST}/test_unicode.log"
touch "$LOG_FILE"

AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""
LAST_AGENT_NULL_RUN=false

# Force UTF-8 terminal so Unicode separators are used
orig_lang="${LANG:-}"
orig_lc_all="${LC_ALL:-}"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

_append_agent_summary "Coder" "claude-sonnet-4-20250514" "10" "50" "1" "0" "0" "2" "$LOG_FILE"

content=$(cat "$LOG_FILE")

if echo "$content" | grep -q "═══"; then
    pass "unicode: Unicode separator used when LANG=en_US.UTF-8"
else
    fail "unicode: expected Unicode separator (═══) when LANG=en_US.UTF-8, got ASCII or missing"
fi

# Force non-UTF-8 terminal so ASCII separators are used
LOG_FILE="${TMPDIR_TEST}/test_ascii.log"
touch "$LOG_FILE"

export LANG="C"
export LC_ALL="C"

_append_agent_summary "Coder" "claude-sonnet-4-20250514" "10" "50" "1" "0" "0" "2" "$LOG_FILE"

content=$(cat "$LOG_FILE")

if echo "$content" | grep -q "==="; then
    pass "ascii: ASCII separator used when LANG=C"
else
    fail "ascii: expected ASCII separator (===) when LANG=C"
fi

# Confirm no Unicode separator leaked through
if echo "$content" | grep -q "═══"; then
    fail "ascii: Unicode separator leaked through when LANG=C"
else
    pass "ascii: No Unicode separator when LANG=C"
fi

# Restore env
export LANG="$orig_lang"
export LC_ALL="$orig_lc_all"

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "agent_summary tests passed"
