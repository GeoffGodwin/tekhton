#!/usr/bin/env bash
# Test: ui_validate_report.sh — _json_field, _status_icon, get_ui_validation_summary,
#       generate_ui_validation_report
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Setup: source common.sh (provides log/warn/error) then ui_validate_report.sh
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null
source "${TEKHTON_HOME}/lib/ui_validate_report.sh" 2>/dev/null

# ---------------------------------------------------------------------------
# Tests: _json_field
# ---------------------------------------------------------------------------

# Simple string value extraction
result=$(_json_field '{"label":"index.html","verdict":"PASS","load":"pass"}' "label")
if [[ "$result" = "index.html" ]]; then
    pass "_json_field: extracts simple string value"
else
    fail "_json_field: expected 'index.html', got '${result}'"
fi

# Numeric value extraction
result=$(_json_field '{"timeout":30,"label":"test"}' "timeout")
if [[ "$result" = "30" ]]; then
    pass "_json_field: extracts numeric value"
else
    fail "_json_field: expected '30', got '${result}'"
fi

# Missing key returns empty
result=$(_json_field '{"label":"test"}' "verdict")
if [[ -z "$result" ]]; then
    pass "_json_field: missing key returns empty string"
else
    fail "_json_field: expected empty for missing key, got '${result}'"
fi

# Empty JSON returns empty
result=$(_json_field '{}' "label")
if [[ -z "$result" ]]; then
    pass "_json_field: empty JSON returns empty string"
else
    fail "_json_field: expected empty for empty JSON, got '${result}'"
fi

# FAIL verdict extraction
result=$(_json_field '{"verdict":"FAIL","load":"fail"}' "verdict")
if [[ "$result" = "FAIL" ]]; then
    pass "_json_field: extracts FAIL verdict"
else
    fail "_json_field: expected 'FAIL', got '${result}'"
fi

# Boolean-like value
result=$(_json_field '{"flicker":"detected","load":"pass"}' "flicker")
if [[ "$result" = "detected" ]]; then
    pass "_json_field: extracts boolean-like string value"
else
    fail "_json_field: expected 'detected', got '${result}'"
fi

# ---------------------------------------------------------------------------
# Tests: _status_icon
# ---------------------------------------------------------------------------

for val in pass true ok; do
    result=$(_status_icon "$val")
    if [[ "$result" = "pass" ]]; then
        pass "_status_icon: '$val' maps to 'pass'"
    else
        fail "_status_icon: '$val' should map to 'pass', got '${result}'"
    fi
done

for val in warn warning; do
    result=$(_status_icon "$val")
    if [[ "$result" = "warn" ]]; then
        pass "_status_icon: '$val' maps to 'warn'"
    else
        fail "_status_icon: '$val' should map to 'warn', got '${result}'"
    fi
done

for val in fail false error; do
    result=$(_status_icon "$val")
    if [[ "$result" = "FAIL" ]]; then
        pass "_status_icon: '$val' maps to 'FAIL'"
    else
        fail "_status_icon: '$val' should map to 'FAIL', got '${result}'"
    fi
done

result=$(_status_icon "unknown_value")
if [[ "$result" = "?" ]]; then
    pass "_status_icon: unknown value maps to '?'"
else
    fail "_status_icon: unknown value should map to '?', got '${result}'"
fi

result=$(_status_icon "")
if [[ "$result" = "?" ]]; then
    pass "_status_icon: empty value maps to '?'"
else
    fail "_status_icon: empty value should map to '?', got '${result}'"
fi

# ---------------------------------------------------------------------------
# Tests: get_ui_validation_summary
# ---------------------------------------------------------------------------

# Failures present
export UI_VALIDATION_PASS_COUNT=2
export UI_VALIDATION_FAIL_COUNT=1
export UI_VALIDATION_WARN_COUNT=0
result=$(get_ui_validation_summary)
if [[ "$result" = "2 passed, 1 failed, 0 warnings" ]]; then
    pass "get_ui_validation_summary: reports fail correctly"
else
    fail "get_ui_validation_summary: fail case, got '${result}'"
fi

# Warnings only
export UI_VALIDATION_PASS_COUNT=3
export UI_VALIDATION_FAIL_COUNT=0
export UI_VALIDATION_WARN_COUNT=2
result=$(get_ui_validation_summary)
if [[ "$result" = "3 passed, 2 warnings" ]]; then
    pass "get_ui_validation_summary: reports warnings without fail"
else
    fail "get_ui_validation_summary: warn-only case, got '${result}'"
fi

# Pass only
export UI_VALIDATION_PASS_COUNT=4
export UI_VALIDATION_FAIL_COUNT=0
export UI_VALIDATION_WARN_COUNT=0
result=$(get_ui_validation_summary)
if [[ "$result" = "4 passed" ]]; then
    pass "get_ui_validation_summary: reports pass-only"
else
    fail "get_ui_validation_summary: pass-only case, got '${result}'"
fi

# All zero — not run
export UI_VALIDATION_PASS_COUNT=0
export UI_VALIDATION_FAIL_COUNT=0
export UI_VALIDATION_WARN_COUNT=0
result=$(get_ui_validation_summary)
if [[ "$result" = "not run" ]]; then
    pass "get_ui_validation_summary: all-zero reports 'not run'"
else
    fail "get_ui_validation_summary: all-zero case, got '${result}'"
fi

# Unset vars fall back to 0 default
unset UI_VALIDATION_PASS_COUNT UI_VALIDATION_FAIL_COUNT UI_VALIDATION_WARN_COUNT
result=$(get_ui_validation_summary)
if [[ "$result" = "not run" ]]; then
    pass "get_ui_validation_summary: unset vars default to 'not run'"
else
    fail "get_ui_validation_summary: unset vars case, got '${result}'"
fi

# ---------------------------------------------------------------------------
# Tests: generate_ui_validation_report
# ---------------------------------------------------------------------------

# Reset counts
export UI_VALIDATION_PASS_COUNT=0
export UI_VALIDATION_FAIL_COUNT=0
export UI_VALIDATION_WARN_COUNT=0
export UI_VALIDATION_SCREENSHOTS=false

cd "$TMPDIR"
REPORT_FILE="${TMPDIR}/UI_VALIDATION_REPORT.md"

# Single PASS result
PASS_JSON='{"label":"index.html","verdict":"PASS","load":"pass","console":"pass","resources":"pass","rendering":"pass","flicker":"none","viewport":"1280x800","console_errors":[],"missing_resources":[]}'
generate_ui_validation_report "$PASS_JSON" 2>/dev/null

if [[ -f "$REPORT_FILE" ]]; then
    pass "generate_ui_validation_report: creates report file"
else
    fail "generate_ui_validation_report: report file not created"
fi

if grep -q "## UI Validation Report" "$REPORT_FILE" 2>/dev/null; then
    pass "generate_ui_validation_report: report has heading"
else
    fail "generate_ui_validation_report: missing heading"
fi

if grep -q "index.html" "$REPORT_FILE" 2>/dev/null; then
    pass "generate_ui_validation_report: report contains target label"
else
    fail "generate_ui_validation_report: missing target label in report"
fi

if [[ "${UI_VALIDATION_PASS_COUNT:-0}" -eq 1 ]]; then
    pass "generate_ui_validation_report: exports pass count = 1"
else
    fail "generate_ui_validation_report: expected pass count 1, got ${UI_VALIDATION_PASS_COUNT:-0}"
fi

if [[ "${UI_VALIDATION_FAIL_COUNT:-0}" -eq 0 ]]; then
    pass "generate_ui_validation_report: exports fail count = 0"
else
    fail "generate_ui_validation_report: expected fail count 0, got ${UI_VALIDATION_FAIL_COUNT:-0}"
fi

# FAIL result increments fail counter
export UI_VALIDATION_PASS_COUNT=0
export UI_VALIDATION_FAIL_COUNT=0
export UI_VALIDATION_WARN_COUNT=0
FAIL_JSON='{"label":"broken.html","verdict":"FAIL","load":"fail","console":"pass","resources":"pass","rendering":"pass","flicker":"none","viewport":"1280x800","console_errors":["Load failed"],"missing_resources":[]}'
generate_ui_validation_report "$FAIL_JSON" 2>/dev/null

if [[ "${UI_VALIDATION_FAIL_COUNT:-0}" -eq 1 ]]; then
    pass "generate_ui_validation_report: FAIL result increments fail counter"
else
    fail "generate_ui_validation_report: expected fail count 1, got ${UI_VALIDATION_FAIL_COUNT:-0}"
fi

if grep -q "\*\*FAIL\*\*" "$REPORT_FILE" 2>/dev/null; then
    pass "generate_ui_validation_report: FAIL verdict shown bold in table"
else
    fail "generate_ui_validation_report: missing **FAIL** in report"
fi

# Mixed results: one pass and one fail
export UI_VALIDATION_PASS_COUNT=0
export UI_VALIDATION_FAIL_COUNT=0
export UI_VALIDATION_WARN_COUNT=0
generate_ui_validation_report "$PASS_JSON" "$FAIL_JSON" 2>/dev/null

if [[ "${UI_VALIDATION_PASS_COUNT:-0}" -eq 1 ]] && [[ "${UI_VALIDATION_FAIL_COUNT:-0}" -eq 1 ]]; then
    pass "generate_ui_validation_report: mixed results counted correctly"
else
    fail "generate_ui_validation_report: mixed counts wrong: pass=${UI_VALIDATION_PASS_COUNT:-0} fail=${UI_VALIDATION_FAIL_COUNT:-0}"
fi

# Empty result string — should still write file without crashing
export UI_VALIDATION_PASS_COUNT=0
export UI_VALIDATION_FAIL_COUNT=0
export UI_VALIDATION_WARN_COUNT=0
generate_ui_validation_report "" 2>/dev/null
if [[ -f "$REPORT_FILE" ]]; then
    pass "generate_ui_validation_report: empty result still writes file"
else
    fail "generate_ui_validation_report: empty result did not write file"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
