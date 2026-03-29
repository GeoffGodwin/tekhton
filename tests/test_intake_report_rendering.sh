#!/usr/bin/env bash
# =============================================================================
# test_intake_report_rendering.sh — Intake Report UI rendering
#
# Tests:
#   1. JSON structure contains required fields (verdict, confidence, task_text)
#   2. CSS classes exist for styling (intake-task-text, intake-task-content, intake-ms-link)
#   3. renderIntakeBody function logic (verified via grep on source)
#   4. Link generation with milestone ID
#   5. Link omission when no milestone
#   6. HTML escaping in rendered output
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Test Suite: Intake Report UI Rendering ==="

# =============================================================================
# Test 1: JSON structure from _parse_intake_report includes all required fields
# =============================================================================
echo ""
echo "--- Test 1: JSON structure validation ---"

_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Create test INTAKE_REPORT.md
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/INTAKE_REPORT.md" << 'EOF'
## Verdict
TWEAKED

## Confidence
75

## Tweaked Content

[FEAT] Add user authentication to the API
EOF

result=$(_parse_intake_report "$TEST_DIR/INTAKE_REPORT.md")

# Validate JSON structure
if echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'verdict' in d, 'Missing verdict field'
assert 'confidence' in d, 'Missing confidence field'
assert 'task_text' in d, 'Missing task_text field'
" 2>/dev/null; then
    pass "1.1 — JSON includes all required fields (verdict, confidence, task_text)"
else
    fail "1.1 — JSON missing required fields"
fi

# Validate field types
if echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert isinstance(d['verdict'], str), 'verdict not string'
assert isinstance(d['confidence'], int), 'confidence not int'
assert isinstance(d['task_text'], str), 'task_text not string'
" 2>/dev/null; then
    pass "1.2 — JSON fields have correct types"
else
    fail "1.2 — JSON field types incorrect"
fi

# =============================================================================
# Test 2: CSS classes exist in style.css
# =============================================================================
echo ""
echo "--- Test 2: CSS styling classes ---"

CSS_FILE="${TEKHTON_HOME}/templates/watchtower/style.css"
if [[ ! -f "$CSS_FILE" ]]; then
    fail "2.1 — style.css not found"
else
    if grep -q "\.intake-task-text" "$CSS_FILE"; then
        pass "2.1 — CSS class .intake-task-text exists"
    else
        fail "2.1 — CSS class .intake-task-text missing"
    fi

    if grep -q "\.intake-task-content" "$CSS_FILE"; then
        pass "2.2 — CSS class .intake-task-content exists"
    else
        fail "2.2 — CSS class .intake-task-content missing"
    fi

    if grep -q "\.intake-ms-link" "$CSS_FILE"; then
        pass "2.3 — CSS class .intake-ms-link exists"
    else
        fail "2.3 — CSS class .intake-ms-link missing"
    fi
fi

# =============================================================================
# Test 3: renderIntakeBody function exists in app.js
# =============================================================================
echo ""
echo "--- Test 3: JavaScript function presence ---"

APP_JS_FILE="${TEKHTON_HOME}/templates/watchtower/app.js"
if [[ ! -f "$APP_JS_FILE" ]]; then
    fail "3.1 — app.js not found"
else
    if grep -q "function renderIntakeBody" "$APP_JS_FILE"; then
        pass "3.1 — renderIntakeBody function exists"
    else
        fail "3.1 — renderIntakeBody function not found"
    fi

    if grep -q "intake-task-text" "$APP_JS_FILE"; then
        pass "3.2 — app.js references intake-task-text class"
    else
        fail "3.2 — app.js missing intake-task-text class reference"
    fi

    if grep -q "intake-task-content" "$APP_JS_FILE"; then
        pass "3.3 — app.js references intake-task-content class"
    else
        fail "3.3 — app.js missing intake-task-content class reference"
    fi

    if grep -q "intake-ms-link" "$APP_JS_FILE"; then
        pass "3.4 — app.js references intake-ms-link class"
    else
        fail "3.4 — app.js missing intake-ms-link class reference"
    fi
fi

# =============================================================================
# Test 4: renderIntakeBody includes link with data-ms-link attribute
# =============================================================================
echo ""
echo "--- Test 4: Milestone link generation ---"

if grep -q "data-ms-link" "$APP_JS_FILE"; then
    pass "4.1 — renderIntakeBody generates link with data-ms-link attribute"
else
    fail "4.1 — data-ms-link attribute not found in renderIntakeBody"
fi

# Verify the link includes "View in Milestone Map" text
if grep -q "View in Milestone Map" "$APP_JS_FILE"; then
    pass "4.2 — Link text 'View in Milestone Map' present"
else
    fail "4.2 — Link text not found"
fi

# =============================================================================
# Test 5: renderIntakeBody displays task_text when present
# =============================================================================
echo ""
echo "--- Test 5: Task text rendering logic ---"

if grep -q 'if (data.task_text)' "$APP_JS_FILE" || grep -q 'data\.task_text' "$APP_JS_FILE"; then
    pass "5.1 — renderIntakeBody checks for task_text presence"
else
    fail "5.1 — Task text presence check not found"
fi

if grep -q 'esc(data.task_text)' "$APP_JS_FILE"; then
    pass "5.2 — renderIntakeBody escapes task_text for HTML safety"
else
    fail "5.2 — HTML escaping of task_text not found"
fi

# =============================================================================
# Test 6: renderIntakeBody handles missing milestone gracefully
# =============================================================================
echo ""
echo "--- Test 6: Missing milestone handling ---"

if grep -q "if (msId)" "$APP_JS_FILE"; then
    pass "6.1 — renderIntakeBody checks if milestone ID exists"
else
    fail "6.1 — Milestone ID existence check not found"
fi

# =============================================================================
# Test 7: Verify app.js is syntactically valid JavaScript
# =============================================================================
echo ""
echo "--- Test 7: JavaScript syntax validation ---"

if command -v node &>/dev/null; then
    # Use Node.js to check syntax if available
    if node -c "$APP_JS_FILE" 2>/dev/null; then
        pass "7.1 — app.js has valid JavaScript syntax (via Node.js)"
    else
        fail "7.1 — app.js has syntax errors (Node.js check)"
    fi
else
    # Fallback: check for obvious syntax issues
    if grep -q "function " "$APP_JS_FILE" && ! grep -q "function function" "$APP_JS_FILE"; then
        pass "7.1 — app.js structure looks valid (basic check)"
    else
        fail "7.1 — app.js structure appears invalid"
    fi
fi

# =============================================================================
# Test 8: Verify task label renders with "Task:" prefix
# =============================================================================
echo ""
echo "--- Test 8: Task label rendering ---"

if grep -q "Task:" "$APP_JS_FILE"; then
    pass "8.1 — renderIntakeBody renders task label with 'Task:' prefix"
else
    fail "8.1 — 'Task:' label not found in renderIntakeBody"
fi

# =============================================================================
# Test 9: Verify Verdict and Confidence are still rendered
# =============================================================================
echo ""
echo "--- Test 9: Legacy fields still rendered ---"

if grep -q "Verdict:" "$APP_JS_FILE"; then
    pass "9.1 — Verdict field still rendered"
else
    fail "9.1 — Verdict rendering removed"
fi

if grep -q "Confidence:" "$APP_JS_FILE"; then
    pass "9.2 — Confidence field still rendered"
else
    fail "9.2 — Confidence rendering removed"
fi

# =============================================================================
# Test 10: renderIntakeBody returns HTML string
# =============================================================================
echo ""
echo "--- Test 10: Return type validation ---"

# The function should accumulate html variable and return it
if grep -A 20 "function renderIntakeBody" "$APP_JS_FILE" | grep -q "return html"; then
    pass "10.1 — renderIntakeBody returns HTML string"
else
    fail "10.1 — renderIntakeBody doesn't return HTML"
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
