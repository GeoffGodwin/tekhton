#!/usr/bin/env bash
# test_security_stage.sh — Unit tests for stages/security.sh helper functions
# Tests: _parse_security_findings, _severity_meets_threshold, _build_fixable_block
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME PROJECT_DIR

cd "$PROJECT_DIR"

# --- Stub required globals and functions ---
SECURITY_BLOCK_SEVERITY="HIGH"

# Stub functions required by security.sh (stage functions, not tested here)
log()    { :; }
warn()   { :; }
error()  { :; }
header() { :; }
success() { :; }
run_agent() { :; }
print_run_summary() { :; }
render_prompt() { echo "stub"; }
run_build_gate() { return 0; }
write_pipeline_state() { :; }
append_human_action() { :; }
extract_files_from_coder_summary() { echo ""; }

# --- Source the helper and stage files (defines the helper functions) ---
# shellcheck source=../lib/security_helpers.sh
source "${TEKHTON_HOME}/lib/security_helpers.sh"
# shellcheck source=../stages/security.sh
source "${TEKHTON_HOME}/stages/security.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected='$expected', got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected to contain '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "\033[0;31mFAIL\033[0m $label — expected NOT to contain '$needle'"
        FAIL=$((FAIL + 1))
    else
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    fi
}

# =============================================================================
# _severity_meets_threshold tests
# =============================================================================

# Test 1: CRITICAL meets CRITICAL threshold
result=0
_severity_meets_threshold "CRITICAL" "CRITICAL" || result=$?
assert_eq "CRITICAL meets CRITICAL" "0" "$result"

# Test 2: CRITICAL meets HIGH threshold
result=0
_severity_meets_threshold "CRITICAL" "HIGH" || result=$?
assert_eq "CRITICAL meets HIGH" "0" "$result"

# Test 3: HIGH meets HIGH threshold
result=0
_severity_meets_threshold "HIGH" "HIGH" || result=$?
assert_eq "HIGH meets HIGH" "0" "$result"

# Test 4: MEDIUM does NOT meet HIGH threshold
result=0
_severity_meets_threshold "MEDIUM" "HIGH" && result=0 || result=$?
if [ "$result" -ne 0 ]; then
    echo -e "\033[0;32mPASS\033[0m MEDIUM does not meet HIGH"
    PASS=$((PASS + 1))
else
    echo -e "\033[0;31mFAIL\033[0m MEDIUM does not meet HIGH — expected non-zero return"
    FAIL=$((FAIL + 1))
fi

# Test 5: LOW does NOT meet HIGH threshold
_severity_meets_threshold "LOW" "HIGH" && _low_meets_high=true || _low_meets_high=false
assert_eq "LOW does not meet HIGH" "false" "$_low_meets_high"

# Test 6: MEDIUM meets MEDIUM threshold
result=0
_severity_meets_threshold "MEDIUM" "MEDIUM" || result=$?
assert_eq "MEDIUM meets MEDIUM" "0" "$result"

# Test 7: MEDIUM meets LOW threshold
result=0
_severity_meets_threshold "MEDIUM" "LOW" || result=$?
assert_eq "MEDIUM meets LOW" "0" "$result"

# Test 8: HIGH meets MEDIUM threshold
result=0
_severity_meets_threshold "HIGH" "MEDIUM" || result=$?
assert_eq "HIGH meets MEDIUM" "0" "$result"

# Test 9: LOW meets LOW threshold
result=0
_severity_meets_threshold "LOW" "LOW" || result=$?
assert_eq "LOW meets LOW" "0" "$result"

# Test 10: Unknown severity does NOT meet any threshold
_severity_meets_threshold "UNKNOWN" "LOW" && _unknown_meets_low=true || _unknown_meets_low=false
assert_eq "Unknown severity does not meet LOW" "false" "$_unknown_meets_low"

# =============================================================================
# _parse_security_findings tests
# =============================================================================

REPORT_FILE="${TMPDIR_TEST}/SECURITY_REPORT.md"

# Test 11: Missing report file returns 1
_SEC_SEVERITIES=()
_SEC_FIXABLES=()
_SEC_DESCRIPTIONS=()
_parse_security_findings "/nonexistent/path.md" && _missing_returns_1=false || _missing_returns_1=true
assert_eq "Missing report returns 1" "true" "$_missing_returns_1"

# Test 12: Report with no Findings section returns 1
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Summary
Clean run, no issues found.
EOF

_parse_security_findings "$REPORT_FILE" && _no_findings_returns_1=false || _no_findings_returns_1=true
assert_eq "No Findings section returns 1" "true" "$_no_findings_returns_1"

# Test 13: Report with empty Findings section returns 1
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings

## Summary
No issues.
EOF

_parse_security_findings "$REPORT_FILE" && _empty_section_returns_1=false || _empty_section_returns_1=true
assert_eq "Empty Findings section returns 1" "true" "$_empty_section_returns_1"

# Test 14: Parses a single CRITICAL fixable finding
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [CRITICAL] fixable:yes SQL injection in login handler via unescaped input

## Summary
1 finding.
EOF

_parse_security_findings "$REPORT_FILE"
assert_eq "Single finding: count" "1" "${#_SEC_SEVERITIES[@]}"
assert_eq "Single finding: severity" "CRITICAL" "${_SEC_SEVERITIES[0]}"
assert_eq "Single finding: fixable" "yes" "${_SEC_FIXABLES[0]}"

# Test 15: Parses multiple findings with mixed severity/fixability
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [CRITICAL] fixable:yes SQL injection in login handler
- [HIGH] fixable:no Hardcoded API key in config.sh
- [MEDIUM] fixable:yes Missing CSRF token on form
- [LOW] fixable:unknown Verbose error messages expose stack traces

## Summary
4 findings.
EOF

_parse_security_findings "$REPORT_FILE"
assert_eq "Multi finding: count" "4" "${#_SEC_SEVERITIES[@]}"
assert_eq "Multi finding: first severity" "CRITICAL" "${_SEC_SEVERITIES[0]}"
assert_eq "Multi finding: second fixable" "no" "${_SEC_FIXABLES[1]}"
assert_eq "Multi finding: third severity" "MEDIUM" "${_SEC_SEVERITIES[2]}"
assert_eq "Multi finding: fourth fixable" "unknown" "${_SEC_FIXABLES[3]}"

# Test 16: Fixable defaults to "unknown" when not specified
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [HIGH] Missing input validation on user endpoint

## Summary
1 finding.
EOF

_parse_security_findings "$REPORT_FILE"
assert_eq "Missing fixable defaults to unknown" "unknown" "${_SEC_FIXABLES[0]}"

# Test 17: Lines without severity bracket are ignored
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- This line has no severity bracket
- [HIGH] fixable:yes Real finding here
- Another plain line

## Summary
EOF

_parse_security_findings "$REPORT_FILE"
assert_eq "Lines without severity bracket ignored" "1" "${#_SEC_SEVERITIES[@]}"
assert_eq "Only real finding parsed" "HIGH" "${_SEC_SEVERITIES[0]}"

# Test 18: Parser stops at next ## section header
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [HIGH] fixable:yes Finding inside section

## Remediation
- [CRITICAL] fixable:yes This line is outside Findings section
EOF

_parse_security_findings "$REPORT_FILE"
assert_eq "Parser stops at next section" "1" "${#_SEC_SEVERITIES[@]}"

# =============================================================================
# _build_fixable_block tests
# =============================================================================

# Test 19: Only fixable findings at or above threshold are included
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [CRITICAL] fixable:yes SQL injection — must fix
- [HIGH] fixable:no Hardcoded key — cannot fix automatically
- [MEDIUM] fixable:yes CSRF missing — below threshold
- [LOW] fixable:yes Verbose errors — well below threshold
EOF

_parse_security_findings "$REPORT_FILE"
SECURITY_BLOCK_SEVERITY="HIGH"
fixable_block=$(_build_fixable_block)

assert_contains "Fixable block: CRITICAL yes included" "[CRITICAL]" "$fixable_block"
assert_not_contains "Fixable block: HIGH no excluded" "Hardcoded key" "$fixable_block"
assert_not_contains "Fixable block: MEDIUM excluded (below threshold)" "[MEDIUM]" "$fixable_block"
assert_not_contains "Fixable block: LOW excluded" "[LOW]" "$fixable_block"

# Test 20: Empty fixable block when no fixable findings at threshold
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [HIGH] fixable:no Hardcoded credentials — cannot fix
- [MEDIUM] fixable:yes Missing CSRF — below threshold
EOF

_parse_security_findings "$REPORT_FILE"
SECURITY_BLOCK_SEVERITY="HIGH"
fixable_block=$(_build_fixable_block)

# Should be empty (no content lines)
stripped="${fixable_block//[$'\n\t ']/}"
assert_eq "Empty fixable block when none qualify" "" "$stripped"

# Test 21: CRITICAL threshold — only CRITICAL fixable findings included
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [CRITICAL] fixable:yes Critical SQL injection
- [HIGH] fixable:yes High-severity XSS
- [MEDIUM] fixable:yes Medium CSRF
EOF

_parse_security_findings "$REPORT_FILE"
SECURITY_BLOCK_SEVERITY="CRITICAL"
fixable_block=$(_build_fixable_block)

assert_contains "CRITICAL threshold: CRITICAL fixable included" "[CRITICAL]" "$fixable_block"
assert_not_contains "CRITICAL threshold: HIGH excluded" "[HIGH]" "$fixable_block"
assert_not_contains "CRITICAL threshold: MEDIUM excluded" "[MEDIUM]" "$fixable_block"

# Test 22: MEDIUM threshold — CRITICAL, HIGH, and MEDIUM fixable included
cat > "$REPORT_FILE" << 'EOF'
# Security Report

## Findings
- [CRITICAL] fixable:yes Critical finding
- [HIGH] fixable:yes High finding
- [MEDIUM] fixable:yes Medium finding
- [LOW] fixable:yes Low finding
EOF

_parse_security_findings "$REPORT_FILE"
SECURITY_BLOCK_SEVERITY="MEDIUM"
fixable_block=$(_build_fixable_block)

assert_contains "MEDIUM threshold: CRITICAL included" "[CRITICAL]" "$fixable_block"
assert_contains "MEDIUM threshold: HIGH included" "[HIGH]" "$fixable_block"
assert_contains "MEDIUM threshold: MEDIUM included" "[MEDIUM]" "$fixable_block"
assert_not_contains "MEDIUM threshold: LOW excluded" "[LOW]" "$fixable_block"

# Restore default
SECURITY_BLOCK_SEVERITY="HIGH"

# =============================================================================
# Results
# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: $PASS  Failed: $FAIL"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ] || exit 1
