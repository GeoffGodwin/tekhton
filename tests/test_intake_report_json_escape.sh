#!/usr/bin/env bash
# =============================================================================
# test_intake_report_json_escape.sh — Intake Report JSON escaping
#
# Tests:
#   1. Task text with special characters is properly JSON-escaped
#   2. Task text with quotes, newlines, and backslashes
#   3. Confidence parsing with edge cases
#   4. Empty verdict/confidence handling
#   5. Malformed Tweaked Content section (missing header, extra noise)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub _json_escape function (from causality.sh)
_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Source the function under test
# shellcheck source=../lib/dashboard_parsers.sh
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

echo "=== Test Suite: Intake Report JSON Escaping ==="

# =============================================================================
# Test 1: Quotes and backslashes in task_text
# =============================================================================
echo ""
echo "--- Test 1: Special characters in task text ---"

cat > "$TEST_TMPDIR/INTAKE_QUOTES.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
75

## Tweaked Content

[FEAT] Add "quoted text" and handle path\separators
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_QUOTES.md")

# Verify JSON is valid
if echo "$result" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    pass "1.1 — Task text with quotes and backslashes produces valid JSON"
else
    fail "1.1 — JSON parsing failed: $result"
fi

# Extract and verify task_text
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)
if [[ "$task_text" == *"quoted text"* ]] && [[ "$task_text" == *"path"* ]]; then
    pass "1.2 — Task text preserved quotes and backslashes after JSON round-trip"
else
    fail "1.2 — Task text incorrect: '$task_text'"
fi

# =============================================================================
# Test 2: Multi-line task text (collapse to single line)
# =============================================================================
echo ""
echo "--- Test 2: Multi-line task text ---"

cat > "$TEST_TMPDIR/INTAKE_MULTILINE.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
80

## Tweaked Content

[FEAT] Add user authentication
This includes login, logout, and password reset
Scope: API and frontend both
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_MULTILINE.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

# Should collapse to single line with spaces, not preserve newlines
if [[ "$task_text" != *$'\n'* ]]; then
    pass "2.1 — Multi-line task text collapsed to single line"
else
    fail "2.1 — Task text still contains newlines: '$task_text'"
fi

if [[ "$task_text" == *"Add user authentication"* ]] && [[ "$task_text" == *"password reset"* ]]; then
    pass "2.2 — Multi-line task text preserved all content"
else
    fail "2.2 — Task text missing content: '$task_text'"
fi

# =============================================================================
# Test 3: Confidence edge cases
# =============================================================================
echo ""
echo "--- Test 3: Confidence parsing edge cases ---"

cat > "$TEST_TMPDIR/INTAKE_CONF_EDGE1.md" << 'EOF'
## Verdict: APPROVED
## Confidence: 100/100 (perfect score)
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_CONF_EDGE1.md")
confidence=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confidence',0))" 2>/dev/null || true)

if [[ "$confidence" == "100" ]]; then
    pass "3.1 — Confidence extracted from inline '100/100' format"
else
    fail "3.1 — Expected confidence=100, got '$confidence' (BUG: header-then-value format concatenates all numbers)"
fi

# =============================================================================
# Test 4: Tweaked Content section with subsection markers
# =============================================================================
echo ""
echo "--- Test 4: Tweaked Content with subsections ---"

cat > "$TEST_TMPDIR/INTAKE_SUBSEC.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
65

## Tweaked Content

[FEAT] Implement caching layer with Redis

### Acceptance Criteria
- Redis connection pool
- Cache invalidation
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_SUBSEC.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

# Should extract only the [FEAT] line, not subsections
if [[ "$task_text" == "[FEAT] Implement caching layer"* ]] && [[ "$task_text" != *"Acceptance Criteria"* ]]; then
    pass "4.1 — Task text stops at subsection marker (###)"
else
    fail "4.1 — Task text incorrectly includes subsections: '$task_text'"
fi

# =============================================================================
# Test 5: HTML/XML-like content in task text
# =============================================================================
echo ""
echo "--- Test 5: HTML-like content escaping ---"

cat > "$TEST_TMPDIR/INTAKE_HTML.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
50

## Tweaked Content

[FEAT] Fix <script> tag handling and sanitize <user-input>
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_HTML.md")

# Verify JSON is valid even with HTML-like tags
if echo "$result" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    pass "5.1 — HTML-like tags in task text produce valid JSON"
else
    fail "5.1 — JSON parsing failed with HTML tags: $result"
fi

task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)
if [[ "$task_text" == *"script"* ]] && [[ "$task_text" == *"sanitize"* ]]; then
    pass "5.2 — HTML-like content preserved in task_text"
else
    fail "5.2 — Task text lost HTML-like content: '$task_text'"
fi

# =============================================================================
# Test 6: Unicode and special characters
# =============================================================================
echo ""
echo "--- Test 6: Unicode handling ---"

cat > "$TEST_TMPDIR/INTAKE_UNICODE.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
60

## Tweaked Content

[FEAT] Add support for émojis 🚀 and internationalization (i18n)
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_UNICODE.md")

if echo "$result" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    pass "6.1 — Unicode characters in task text produce valid JSON"
else
    fail "6.1 — JSON parsing failed with Unicode: $result"
fi

task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)
if [[ "$task_text" == *"support"* ]] && [[ "$task_text" == *"i18n"* ]]; then
    pass "6.2 — Unicode content preserved in task_text"
else
    fail "6.2 — Task text lost Unicode: '$task_text'"
fi

# =============================================================================
# Test 7: Empty or whitespace-only Tweaked Content
# =============================================================================
echo ""
echo "--- Test 7: Empty Tweaked Content handling ---"

cat > "$TEST_TMPDIR/INTAKE_EMPTY_CONTENT.md" << 'EOF'
## Verdict
APPROVED

## Confidence
95

## Tweaked Content


EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_EMPTY_CONTENT.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)

if [[ -z "$task_text" ]]; then
    pass "7.1 — Empty Tweaked Content yields empty task_text"
else
    fail "7.1 — Expected empty task_text, got: '$task_text'"
fi

# =============================================================================
# Test 8: Verdict/Confidence ordering doesn't affect task extraction
# =============================================================================
echo ""
echo "--- Test 8: Field ordering independence ---"

cat > "$TEST_TMPDIR/INTAKE_REORDER.md" << 'EOF'
## Confidence
88

## Tweaked Content

[FEAT] Task text comes after confidence header

## Verdict
APPROVED
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_REORDER.md")
task_text=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('task_text',''))" 2>/dev/null || true)
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null || true)

if [[ "$task_text" == *"Task text comes"* ]]; then
    pass "8.1 — Task text extracted regardless of field order"
else
    fail "8.1 — Task text not extracted when fields reordered: '$task_text'"
fi

if [[ "$verdict" == "APPROVED" ]]; then
    pass "8.2 — Verdict extracted despite different field order"
else
    fail "8.2 — Verdict not extracted correctly: '$verdict'"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

exit 0
