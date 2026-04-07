#!/usr/bin/env bash
# =============================================================================
# test_watchtower_test_audit_rendering.sh
#
# Test suite for Test Audit section rendering in Watchtower Reports tab.
# Verifies the emitter→renderer contract: data shape from dashboard_emitters.sh
# must match expectations in templates/watchtower/app.js renderTestAuditBody().
#
# The bug was: emitter produced {verdict, high_findings, medium_findings}
# but renderer expected {total, passed, failed, pre_existing_failures}.
# These tests guard against re-introducing the same mismatch.
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
    echo "  ✓ PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ FAIL: $1"
    FAIL=$((FAIL + 1))
}

# Stubs required by dashboard_emitters.sh
is_dashboard_enabled() {
    return 0
}

_json_escape() {
    local s="$1"
    printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

_write_js_file() {
    local filepath="$1"
    local varname="$2"
    local json="$3"
    mkdir -p "$(dirname "$filepath")"
    printf 'window.%s = %s;\n' "$varname" "$json" > "$filepath"
}

_to_js_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_parse_intake_report() {
    echo '{"verdict":"pending","confidence":0}'
}

_parse_coder_summary() {
    echo '{"status":"pending","files_modified":0}'
}

_parse_reviewer_report() {
    echo '{"verdict":"pending"}'
}

get_notes_summary() {
    echo "0|0|0|0|0|0"
}

_read_json_int() {
    echo "0"
}

get_health_belt() {
    echo "white"
}

_parse_run_summaries() {
    echo "[]"
}

_parse_security_report() {
    echo "[]"
}

# Source the library under test
source "${TEKHTON_HOME}/lib/dashboard_emitters.sh"

echo "=== Test Suite: Test Audit Rendering (Emitter→Renderer Contract) ==="
echo ""

# =============================================================================
# Test 1: Emitter produces correct JSON shape with PASS verdict
# =============================================================================
echo "[Test 1] Emitter produces correct JSON shape with PASS verdict"

mkdir -p "$TMPDIR/.claude/dashboard/data"
mkdir -p "$TMPDIR/.claude/logs"

# Create a TEST_AUDIT_REPORT.md with PASS verdict
cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: PASS

### High Severity Findings
None

### Medium Severity Findings
None
EOF

# Run the emitter
TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

# Check that reports.js was created
if [[ -f "$TMPDIR/.claude/dashboard/data/reports.js" ]]; then
    pass "1.1 reports.js file created"
else
    fail "1.1 reports.js file created"
fi

# Extract test_audit JSON from the generated file
REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Verify test_audit JSON contains verdict field
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict"'; then
    pass "1.2 test_audit contains verdict field"
else
    fail "1.2 test_audit contains verdict field"
fi

# Verify verdict is set to PASS
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict":"PASS"'; then
    pass "1.3 Verdict is set to PASS"
else
    fail "1.3 Verdict is set to PASS"
fi

# Verify high_findings field exists and is numeric
if echo "$TEST_AUDIT_JSON" | grep -q '"high_findings":[0-9]'; then
    pass "1.4 high_findings is numeric"
else
    fail "1.4 high_findings is numeric"
fi

# Verify medium_findings field exists and is numeric
if echo "$TEST_AUDIT_JSON" | grep -q '"medium_findings":[0-9]'; then
    pass "1.5 medium_findings is numeric"
else
    fail "1.5 medium_findings is numeric"
fi

# Verify the JSON structure is valid (no unexpected fields)
# Should be: {"verdict":"...", "high_findings":..., "medium_findings":...}
if echo "$TEST_AUDIT_JSON" | grep -q '{"verdict":"PASS","high_findings":0,"medium_findings":0}'; then
    pass "1.6 Correct complete JSON shape for PASS verdict with zero findings"
else
    fail "1.6 Correct complete JSON shape for PASS verdict with zero findings"
fi

echo ""

# =============================================================================
# Test 2: Emitter correctly counts HIGH severity findings
# =============================================================================
echo "[Test 2] Emitter correctly counts HIGH severity findings"

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: NEEDS_WORK

### High Severity Findings
- Severity: HIGH, Category: Auth, Detail: SQL injection in login form
- Severity: HIGH, Category: Crypto, Detail: Weak random number generation
- Severity: HIGH, Category: Network, Detail: Unencrypted API calls

### Medium Severity Findings
- Severity: MEDIUM, Category: Performance, Detail: N+1 query on user list
EOF

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Verify high_findings is 3
if echo "$TEST_AUDIT_JSON" | grep -q '"high_findings":3'; then
    pass "2.1 High findings count is 3"
else
    fail "2.1 High findings count is 3"
fi

# Verify medium_findings is 1
if echo "$TEST_AUDIT_JSON" | grep -q '"medium_findings":1'; then
    pass "2.2 Medium findings count is 1"
else
    fail "2.2 Medium findings count is 1"
fi

# Verify verdict is NEEDS_WORK
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict":"NEEDS_WORK"'; then
    pass "2.3 Verdict is NEEDS_WORK"
else
    fail "2.3 Verdict is NEEDS_WORK"
fi

echo ""

# =============================================================================
# Test 3: Emitter correctly counts MEDIUM severity findings
# =============================================================================
echo "[Test 3] Emitter correctly counts MEDIUM severity findings"

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: CONCERNS

### High Severity Findings
- Severity: HIGH, Category: Security, Detail: Unvalidated redirect

### Medium Severity Findings
- Severity: MEDIUM, Category: XSS, Detail: Unescaped user input in template
- Severity: MEDIUM, Category: Performance, Detail: Missing database index
- Severity: MEDIUM, Category: Logging, Detail: Sensitive data in logs
- Severity: MEDIUM, Category: Error, Detail: Stack traces exposed to client
EOF

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Verify high_findings is 1
if echo "$TEST_AUDIT_JSON" | grep -q '"high_findings":1'; then
    pass "3.1 High findings count is 1"
else
    fail "3.1 High findings count is 1"
fi

# Verify medium_findings is 4
if echo "$TEST_AUDIT_JSON" | grep -q '"medium_findings":4'; then
    pass "3.2 Medium findings count is 4"
else
    fail "3.2 Medium findings count is 4"
fi

# Verify verdict is CONCERNS
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict":"CONCERNS"'; then
    pass "3.3 Verdict is CONCERNS"
else
    fail "3.3 Verdict is CONCERNS"
fi

echo ""

# =============================================================================
# Test 4: Emitter defaults to 'skipped' when TEST_AUDIT_REPORT.md missing
# =============================================================================
echo "[Test 4] Emitter defaults to 'skipped' when TEST_AUDIT_REPORT.md missing"

rm -f "$TMPDIR/TEST_AUDIT_REPORT.md"
rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

# Run emitter without TEST_AUDIT_REPORT.md
TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Verify verdict defaults to 'skipped'
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict":"skipped"'; then
    pass "4.1 Verdict defaults to 'skipped' when file missing"
else
    fail "4.1 Verdict defaults to 'skipped' when file missing"
fi

# Verify high_findings is 0
if echo "$TEST_AUDIT_JSON" | grep -q '"high_findings":0'; then
    pass "4.2 High findings is 0 when file missing"
else
    fail "4.2 High findings is 0 when file missing"
fi

# Verify medium_findings is 0
if echo "$TEST_AUDIT_JSON" | grep -q '"medium_findings":0'; then
    pass "4.3 Medium findings is 0 when file missing"
else
    fail "4.3 Medium findings is 0 when file missing"
fi

echo ""

# =============================================================================
# Test 5: Case-insensitive verdict extraction
# =============================================================================
echo "[Test 5] Case-insensitive verdict extraction"

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: pass

### High Severity Findings
None
EOF

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Verify lowercase 'pass' is converted to uppercase 'PASS'
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict":"PASS"'; then
    pass "5.1 Lowercase 'pass' converted to 'PASS'"
else
    fail "5.1 Lowercase 'pass' converted to 'PASS'"
fi

echo ""

# =============================================================================
# Test 6: Renderer can consume the emitted JSON shape
# =============================================================================
echo "[Test 6] Renderer JavaScript contract (data shape validation)"

# This test validates that the emitted JSON structure matches what
# renderTestAuditBody() in app.js expects:
#   - data.verdict (string or falsy)
#   - data.high_findings (number or null)
#   - data.medium_findings (number or null)

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: NEEDS_WORK

### High Severity Findings
- Severity: HIGH, Category: Test, Detail: Critical bug found

### Medium Severity Findings
- Severity: MEDIUM, Category: Test, Detail: Minor issue
- Severity: MEDIUM, Category: Test, Detail: Another issue
EOF

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Verify the JSON is syntactically valid (can be used in JavaScript)
# For this we check it has the expected structure
if echo "$TEST_AUDIT_JSON" | grep -qE '^\{"verdict":"[^"]+","high_findings":[0-9]+,"medium_findings":[0-9]+\}$'; then
    pass "6.1 Emitted JSON matches renderer contract structure"
else
    fail "6.1 Emitted JSON matches renderer contract structure"
    echo "     Got: $TEST_AUDIT_JSON"
fi

# Verify all three fields are present (not missing or null)
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict":"NEEDS_WORK"' && \
   echo "$TEST_AUDIT_JSON" | grep -q '"high_findings":1' && \
   echo "$TEST_AUDIT_JSON" | grep -q '"medium_findings":2'; then
    pass "6.2 All required fields present with correct values"
else
    fail "6.2 All required fields present with correct values"
fi

echo ""

# =============================================================================
# Test 7: Findings counting is accurate with mixed content
# =============================================================================
echo "[Test 7] Findings counting with mixed severity levels"

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: CONCERNS

### Findings Detail
- Severity: LOW, Category: Style, Detail: Inconsistent naming
- Severity: MEDIUM, Category: Perf, Detail: Slow query
- Severity: MEDIUM, Category: Security, Detail: Weak hash
- Severity: HIGH, Category: Auth, Detail: Auth bypass
- Severity: HIGH, Category: Crypto, Detail: Hardcoded key
- Severity: HIGH, Category: Injection, Detail: SQL injection
- Severity: LOW, Category: Docs, Detail: Missing docs
EOF

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Verify only HIGH and MEDIUM are counted (not LOW)
if echo "$TEST_AUDIT_JSON" | grep -q '"high_findings":3'; then
    pass "7.1 High findings count is 3 (excludes LOW)"
else
    fail "7.1 High findings count is 3 (excludes LOW)"
fi

if echo "$TEST_AUDIT_JSON" | grep -q '"medium_findings":2'; then
    pass "7.2 Medium findings count is 2 (excludes LOW)"
else
    fail "7.2 Medium findings count is 2 (excludes LOW)"
fi

echo ""

# =============================================================================
# Test 8: Verdict validation (only valid verdicts accepted)
# =============================================================================
echo "[Test 8] Verdict validation and fallback"

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

# Create test report with invalid verdict format
cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: INVALID_STATUS

### High Severity Findings
None
EOF

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# The emitter should only extract known verdicts or leave as-is
# This test verifies the emitter behavior with unexpected input
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict"'; then
    pass "8.1 Verdict field always present (even if unexpected value)"
else
    fail "8.1 Verdict field always present (even if unexpected value)"
fi

echo ""

# =============================================================================
# Test 9: Empty report edge case
# =============================================================================
echo "[Test 9] Empty TEST_AUDIT_REPORT.md"

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

# Create an empty file
touch "$TMPDIR/TEST_AUDIT_REPORT.md"

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")
TEST_AUDIT_JSON=$(echo "$REPORTS_JS" | sed -n 's/.*"test_audit":\({[^}]*}\).*/\1/p')

# Should default to skipped when no verdict found
if echo "$TEST_AUDIT_JSON" | grep -q '"verdict":"skipped"'; then
    pass "9.1 Empty report defaults to 'skipped' verdict"
else
    fail "9.1 Empty report defaults to 'skipped' verdict"
fi

# Should have zero findings
if echo "$TEST_AUDIT_JSON" | grep -q '"high_findings":0,"medium_findings":0'; then
    pass "9.2 Empty report has zero findings"
else
    fail "9.2 Empty report has zero findings"
fi

echo ""

# =============================================================================
# Test 10: Full integration - all report sections together
# =============================================================================
echo "[Test 10] Full reports.js generation with all sections"

rm -f "$TMPDIR/.claude/dashboard/data/reports.js"

cat > "$TMPDIR/TEST_AUDIT_REPORT.md" << 'EOF'
# Test Audit Report

## Verdict: CONCERNS

### High Severity Findings
- Severity: HIGH, Category: Security, Detail: SQL injection
- Severity: HIGH, Category: Auth, Detail: Weak password handling

### Medium Severity Findings
- Severity: MEDIUM, Category: Performance, Detail: N+1 query
EOF

cat > "$TMPDIR/HUMAN_NOTES.md" << 'EOF'
- [ ] [BUG] Fix the login issue
- [x] [FEAT] Add new feature
EOF

TEST_AUDIT_REPORT_FILE="$TMPDIR/TEST_AUDIT_REPORT.md" \
    emit_dashboard_reports

# Verify the complete reports.js is valid JavaScript
REPORTS_JS=$(cat "$TMPDIR/.claude/dashboard/data/reports.js")

# Verify it's a valid JavaScript window assignment
if echo "$REPORTS_JS" | grep -q '^window\.TK_REPORTS = '; then
    pass "10.1 reports.js has valid window.TK_REPORTS assignment"
else
    fail "10.1 reports.js has valid window.TK_REPORTS assignment"
fi

# Verify test_audit is present in the full reports object
if echo "$REPORTS_JS" | grep -q '"test_audit"'; then
    pass "10.2 test_audit section present in full reports"
else
    fail "10.2 test_audit section present in full reports"
fi

# Verify backlog section is also present (sanity check for full function)
if echo "$REPORTS_JS" | grep -q '"backlog"'; then
    pass "10.3 Full reports.js generation includes all sections"
else
    fail "10.3 Full reports.js generation includes all sections"
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
