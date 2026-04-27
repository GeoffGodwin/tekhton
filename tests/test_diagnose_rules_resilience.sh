#!/usr/bin/env bash
# =============================================================================
# test_diagnose_rules_resilience.sh — M133 resilience-arc diagnose rule tests
#
# Covers the four new rules and the upgraded _rule_max_turns:
#   T1  Interactive reporter fires from primary_cause.signal=ui_timeout_*
#   T2  Interactive reporter fires from raw log evidence only (medium conf)
#   T3  Interactive reporter does not fire on unrelated timeout text
#   T4  Build-fix exhausted fires from BUILD_FIX_REPORT_FILE
#   T5  Build-fix exhausted does not fire when both error artifacts empty
#   T6  Build-fix exhausted no_progress variant includes guidance
#   T7  Preflight interactive config fires from RUN_SUMMARY preflight_ui.*
#   T8  Mixed classification fires at low confidence
#   T9  Max-turns env-root emits MAX_TURNS_ENV_ROOT
#   T10 Max-turns v1 fixture remains MAX_TURNS_EXHAUSTED
#   T11 Priority: interactive reporter beats build failure
#   T12 Priority: build-fix exhausted beats build failure
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals --------------------------------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/.claude/logs"
PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"
CAUSAL_LOG_FILE="$TMPDIR/.claude/logs/CAUSAL_LOG.jsonl"
DASHBOARD_DIR=".claude/dashboard"
DASHBOARD_ENABLED=false
TEKHTON_SESSION_DIR="$TMPDIR"
TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"

BUILD_ERRORS_FILE="${BUILD_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_ERRORS.md}"
BUILD_RAW_ERRORS_FILE="${BUILD_RAW_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_RAW_ERRORS.txt}"
BUILD_FIX_REPORT_FILE="${BUILD_FIX_REPORT_FILE:-${TEKHTON_DIR}/BUILD_FIX_REPORT.md}"
REVIEWER_REPORT_FILE="${REVIEWER_REPORT_FILE:-${TEKHTON_DIR}/REVIEWER_REPORT.md}"
SECURITY_REPORT_FILE="${SECURITY_REPORT_FILE:-${TEKHTON_DIR}/SECURITY_REPORT.md}"
CLARIFICATIONS_FILE="${CLARIFICATIONS_FILE:-${TEKHTON_DIR}/CLARIFICATIONS.md}"
DIAGNOSIS_FILE="${DIAGNOSIS_FILE:-${TEKHTON_DIR}/DIAGNOSIS.md}"

export PROJECT_DIR LOG_DIR PIPELINE_STATE_FILE CAUSAL_LOG_FILE
export DASHBOARD_DIR DASHBOARD_ENABLED TEKHTON_HOME TEKHTON_SESSION_DIR
export TEKHTON_DIR BUILD_ERRORS_FILE BUILD_RAW_ERRORS_FILE BUILD_FIX_REPORT_FILE
export REVIEWER_REPORT_FILE SECURITY_REPORT_FILE CLARIFICATIONS_FILE DIAGNOSIS_FILE

mkdir -p "$LOG_DIR" "${PROJECT_DIR}/${TEKHTON_DIR}" "$TMPDIR/.claude/dashboard/data"

# --- Source dependencies -----------------------------------------------------
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/causality.sh"

_write_js_file() { return 0; }
_to_js_timestamp() { echo "2026-04-27T00:00:00Z"; }
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}
is_dashboard_enabled() { return 1; }

source "${TEKHTON_HOME}/lib/diagnose.sh"

# --- Test helpers ------------------------------------------------------------
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — '$haystack' missing '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

_reset_fixture() {
    rm -rf "$TMPDIR/.claude" "${PROJECT_DIR}/${TEKHTON_DIR}" \
        "${PROJECT_DIR}/playwright.config."*
    mkdir -p "$LOG_DIR" "${PROJECT_DIR}/${TEKHTON_DIR}" "${PROJECT_DIR}/.claude"
    DIAG_CLASSIFICATION=""
    DIAG_CONFIDENCE=""
    DIAG_SUGGESTIONS=()
    _DIAG_PIPELINE_OUTCOME=""
    _DIAG_PIPELINE_STAGE=""
    _DIAG_PIPELINE_TASK=""
    _DIAG_LAST_CLASSIFICATION=""
    _DIAG_EXIT_REASON=""
    _DIAG_PRIMARY_CATEGORY=""
    _DIAG_PRIMARY_SUBCATEGORY=""
    _DIAG_PRIMARY_SIGNAL=""
    _DIAG_PRIMARY_SOURCE=""
    _DIAG_SECONDARY_CATEGORY=""
    _DIAG_SECONDARY_SUBCATEGORY=""
    _DIAG_SECONDARY_SIGNAL=""
    _DIAG_SECONDARY_SOURCE=""
    _DIAG_SCHEMA_VERSION=""
}

_write_v2_failure_ctx() {
    local class="$1" pcat="$2" psub="$3" psig="$4" psrc="${5:-}" scat="${6:-}" ssub="${7:-}" ssig="${8:-}"
    cat > "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" << EOF
{
  "schema_version": 2,
  "classification": "${class}",
  "stage": "coder",
  "outcome": "failure",
  "primary_cause": {
    "category": "${pcat}",
    "subcategory": "${psub}",
    "signal": "${psig}",
    "source": "${psrc:-build_gate}"
  },
  "secondary_cause": {
    "category": "${scat}",
    "subcategory": "${ssub}",
    "signal": "${ssig}",
    "source": "agent"
  }
}
EOF
}

# =============================================================================
# T1: Interactive reporter fires from primary_cause.signal
# =============================================================================
echo "=== T1: Interactive reporter fires from primary_cause.signal ==="
_reset_fixture
_write_v2_failure_ctx "UI_INTERACTIVE_REPORTER" "ENVIRONMENT" "test_infra" \
    "ui_timeout_interactive_report" "build_gate"
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T1.1 classification UI_GATE_INTERACTIVE_REPORTER" \
    "UI_GATE_INTERACTIVE_REPORTER" "$DIAG_CLASSIFICATION"
assert_eq "T1.2 confidence high (signal match)" "high" "$DIAG_CONFIDENCE"

# =============================================================================
# T2: Interactive reporter fires from raw log evidence only (medium conf)
# =============================================================================
echo "=== T2: Interactive reporter fires from raw log evidence ==="
_reset_fixture
echo "Serving HTML report at http://localhost:9323" \
    > "${PROJECT_DIR}/${BUILD_RAW_ERRORS_FILE}"
echo "  Press Ctrl+C to quit." \
    >> "${PROJECT_DIR}/${BUILD_RAW_ERRORS_FILE}"
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T2.1 classification UI_GATE_INTERACTIVE_REPORTER" \
    "UI_GATE_INTERACTIVE_REPORTER" "$DIAG_CLASSIFICATION"
assert_eq "T2.2 confidence medium (raw log only)" "medium" "$DIAG_CONFIDENCE"

# =============================================================================
# T3: Interactive reporter does not fire on unrelated timeout text
# =============================================================================
echo "=== T3: Interactive reporter does not fire on unrelated timeout ==="
_reset_fixture
echo "Test timed out after 30000ms in some-test.spec.ts:42" \
    > "${PROJECT_DIR}/${BUILD_RAW_ERRORS_FILE}"
echo "Some other generic error" >> "${PROJECT_DIR}/${BUILD_ERRORS_FILE}"
_read_diagnostic_context 2>/dev/null || true
_rule_ui_gate_interactive_reporter 2>/dev/null && r=0 || r=1
assert_eq "T3.1 _rule_ui_gate_interactive_reporter does not match" "1" "$r"

# =============================================================================
# T4: Build-fix exhausted fires from BUILD_FIX_REPORT_FILE
# =============================================================================
echo "=== T4: Build-fix exhausted fires from BUILD_FIX_REPORT_FILE ==="
_reset_fixture
echo "still failing" > "${PROJECT_DIR}/${BUILD_ERRORS_FILE}"
cat > "${PROJECT_DIR}/${BUILD_FIX_REPORT_FILE}" << 'EOF'
# Build-Fix Report

## Attempt 1
- Turn budget: 27
- Terminal class: max_turns
- Gate result: FAIL
- Progress signal: improved
- Error-count delta: -2
- M127 classification: code_dominant

## Attempt 2
- Turn budget: 40
- Terminal class: max_turns
- Gate result: FAIL
- Progress signal: improved
- Error-count delta: -1
- M127 classification: code_dominant

## Attempt 3
- Turn budget: 54
- Terminal class: max_turns
- Gate result: FAIL
- Progress signal: improved
- Error-count delta: -1
- M127 classification: code_dominant
EOF
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T4.1 classification BUILD_FIX_EXHAUSTED" \
    "BUILD_FIX_EXHAUSTED" "$DIAG_CLASSIFICATION"
assert_contains "T4.2 mentions BUILD_FIX_REPORT path" "BUILD_FIX_REPORT.md" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"
assert_contains "T4.3 mentions BUILD_FIX_MAX_ATTEMPTS knob" "BUILD_FIX_MAX_ATTEMPTS" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"
assert_contains "T4.4 mentions BUILD_FIX_TOTAL_TURN_CAP knob" "BUILD_FIX_TOTAL_TURN_CAP" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"

# =============================================================================
# T5: Build-fix exhausted does not fire when both error artifacts empty
# =============================================================================
echo "=== T5: Build-fix exhausted does not fire when artifacts empty ==="
_reset_fixture
# Stale BUILD_FIX_REPORT only — current run has clean build artifacts.
cat > "${PROJECT_DIR}/${BUILD_FIX_REPORT_FILE}" << 'EOF'
# Build-Fix Report

## Attempt 1
- Turn budget: 27
- Terminal class: max_turns
- Gate result: FAIL
- Progress signal: unchanged
- Error-count delta: 0
- M127 classification: code_dominant

## Attempt 2
- Turn budget: 40
- Terminal class: max_turns
- Gate result: FAIL
- Progress signal: unchanged
- Error-count delta: 0
- M127 classification: code_dominant
EOF
# Both BUILD_ERRORS_FILE and BUILD_RAW_ERRORS_FILE absent / empty.
_read_diagnostic_context 2>/dev/null || true
_rule_build_fix_exhausted 2>/dev/null && r=0 || r=1
assert_eq "T5.1 _rule_build_fix_exhausted does not match (no current artifacts)" "1" "$r"

# =============================================================================
# T6: Build-fix exhausted no_progress variant
# =============================================================================
echo "=== T6: Build-fix exhausted no_progress variant ==="
_reset_fixture
echo "still failing" > "${PROJECT_DIR}/${BUILD_ERRORS_FILE}"
cat > "${PROJECT_DIR}/${BUILD_FIX_REPORT_FILE}" << 'EOF'
# Build-Fix Report

## Attempt 1
- Turn budget: 27
- Terminal class: max_turns
- Gate result: FAIL
- Progress signal: unchanged
- Error-count delta: 0
- M127 classification: code_dominant

## Attempt 2
- Turn budget: 40
- Terminal class: max_turns
- Gate result: FAIL
- Progress signal: unchanged
- Error-count delta: 0
- M127 classification: code_dominant
EOF
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T6.1 classification BUILD_FIX_EXHAUSTED (no_progress branch)" \
    "BUILD_FIX_EXHAUSTED" "$DIAG_CLASSIFICATION"
assert_contains "T6.2 mentions no measurable progress" "no measurable progress" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"

# =============================================================================
# T7: Preflight interactive config fires from RUN_SUMMARY preflight_ui.*
# =============================================================================
echo "=== T7: Preflight interactive config fires from RUN_SUMMARY ==="
_reset_fixture
cat > "${PROJECT_DIR}/.claude/logs/RUN_SUMMARY.json" << 'EOF'
{
  "milestone": "M01",
  "outcome": "failure",
  "preflight_ui": {
    "interactive_config_detected": true,
    "interactive_config_rule": "PW-1",
    "interactive_config_file": "playwright.config.ts",
    "reporter_auto_patched": false,
    "fail_count": 1,
    "warn_count": 0
  }
}
EOF
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T7.1 classification PREFLIGHT_INTERACTIVE_CONFIG" \
    "PREFLIGHT_INTERACTIVE_CONFIG" "$DIAG_CLASSIFICATION"
assert_contains "T7.2 references playwright.config.ts" "playwright.config.ts" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"
assert_contains "T7.3 mentions PREFLIGHT_UI_CONFIG_AUTO_FIX knob" \
    "PREFLIGHT_UI_CONFIG_AUTO_FIX" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"

# =============================================================================
# T8: Mixed classification fires at low confidence
# =============================================================================
echo "=== T8: Mixed classification fires at low confidence ==="
_reset_fixture
_write_v2_failure_ctx "MIXED_UNCERTAIN" "BUILD" "mixed" \
    "mixed_uncertain_classification" "build_gate"
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T8.1 classification MIXED_UNCERTAIN_CLASSIFICATION" \
    "MIXED_UNCERTAIN_CLASSIFICATION" "$DIAG_CLASSIFICATION"
assert_eq "T8.2 confidence low" "low" "$DIAG_CONFIDENCE"
assert_contains "T8.3 biases toward inspection" "Inspect" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"

# =============================================================================
# T9: Max-turns env-root emits MAX_TURNS_ENV_ROOT
# =============================================================================
echo "=== T9: Max-turns env-root emits MAX_TURNS_ENV_ROOT ==="
_reset_fixture
_write_v2_failure_ctx "MAX_TURNS_EXHAUSTED" \
    "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" "build_gate" \
    "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted"
_read_diagnostic_context 2>/dev/null || true
# Run only _rule_max_turns directly (the resilience UI rule beats it under
# classify_failure_diag, but here we want to validate the upgrade path).
_rule_max_turns 2>/dev/null && r=0 || r=1
assert_eq "T9.1 _rule_max_turns matches v2 env-root fixture" "0" "$r"
assert_eq "T9.2 classification MAX_TURNS_ENV_ROOT" \
    "MAX_TURNS_ENV_ROOT" "$DIAG_CLASSIFICATION"
assert_contains "T9.3 mentions secondary symptom framing" "secondary symptom" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"
assert_contains "T9.4 says more turns or splitting unlikely to help" \
    "unlikely to help" \
    "$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}")"

# =============================================================================
# T10: Max-turns v1 fixture remains MAX_TURNS_EXHAUSTED
# =============================================================================
echo "=== T10: Max-turns v1 fixture remains MAX_TURNS_EXHAUSTED ==="
_reset_fixture
cat > "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" << 'EOF'
{
  "classification": "MAX_TURNS_EXHAUSTED",
  "category": "AGENT_SCOPE",
  "subcategory": "max_turns",
  "stage": "coder",
  "outcome": "failure",
  "consecutive_count": 1
}
EOF
_read_diagnostic_context 2>/dev/null || true
_rule_max_turns 2>/dev/null && r=0 || r=1
assert_eq "T10.1 _rule_max_turns matches v1 fixture" "0" "$r"
assert_eq "T10.2 classification MAX_TURNS_EXHAUSTED (legacy branch)" \
    "MAX_TURNS_EXHAUSTED" "$DIAG_CLASSIFICATION"

# =============================================================================
# T11: Priority — interactive reporter beats build failure
# =============================================================================
echo "=== T11: Priority interactive reporter beats build failure ==="
_reset_fixture
echo "build broken" > "${PROJECT_DIR}/${BUILD_ERRORS_FILE}"
_write_v2_failure_ctx "UI_INTERACTIVE_REPORTER" "ENVIRONMENT" "test_infra" \
    "ui_timeout_interactive_report" "build_gate"
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T11.1 UI_GATE_INTERACTIVE_REPORTER beats BUILD_FAILURE" \
    "UI_GATE_INTERACTIVE_REPORTER" "$DIAG_CLASSIFICATION"

# =============================================================================
# T12: Priority — build-fix exhausted beats build failure
# =============================================================================
echo "=== T12: Priority build-fix exhausted beats build failure ==="
_reset_fixture
echo "still broken" > "${PROJECT_DIR}/${BUILD_ERRORS_FILE}"
cat > "${PROJECT_DIR}/${BUILD_FIX_REPORT_FILE}" << 'EOF'
# Build-Fix Report

## Attempt 1
- Turn budget: 27
- Gate result: FAIL
- Progress signal: improved
- Error-count delta: -1

## Attempt 2
- Turn budget: 40
- Gate result: FAIL
- Progress signal: improved
- Error-count delta: -1

## Attempt 3
- Turn budget: 54
- Gate result: FAIL
- Progress signal: improved
- Error-count delta: -1
EOF
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "T12.1 BUILD_FIX_EXHAUSTED beats BUILD_FAILURE" \
    "BUILD_FIX_EXHAUSTED" "$DIAG_CLASSIFICATION"

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  resilience diagnose tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All resilience diagnose tests passed"
