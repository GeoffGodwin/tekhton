#!/usr/bin/env bash
# shellcheck disable=SC2034
# =============================================================================
# test_failure_context_schema.sh — M129 LAST_FAILURE_CONTEXT schema v2 tests
#
# Covers writer (schema v2 + pretty-print contract + alias precedence),
# reader (v2 parse + legacy fallback), _rule_max_turns secondary-symptom
# message, reset semantics, format_failure_cause_summary partial population.
#
# SC2034 is suppressed file-wide because many test fixture variables are
# consumed indirectly by sourced library functions (TASK, AGENT_ERROR_*,
# DIAG_CLASSIFICATION, etc.) and shellcheck cannot trace them across the
# `source` boundary into diagnose.sh / failure_context.sh.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/.claude/logs"
PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"
CAUSAL_LOG_FILE="$TMPDIR/.claude/logs/CAUSAL_LOG.jsonl"
DASHBOARD_DIR=".claude/dashboard"
DASHBOARD_ENABLED=false
TEKHTON_SESSION_DIR="$TMPDIR"
TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"
BUILD_ERRORS_FILE="${BUILD_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_ERRORS.md}"
REVIEWER_REPORT_FILE="${REVIEWER_REPORT_FILE:-${TEKHTON_DIR}/REVIEWER_REPORT.md}"
SECURITY_REPORT_FILE="${SECURITY_REPORT_FILE:-${TEKHTON_DIR}/SECURITY_REPORT.md}"
CLARIFICATIONS_FILE="${CLARIFICATIONS_FILE:-${TEKHTON_DIR}/CLARIFICATIONS.md}"
DIAGNOSIS_FILE="${DIAGNOSIS_FILE:-${TEKHTON_DIR}/DIAGNOSIS.md}"
export PROJECT_DIR LOG_DIR PIPELINE_STATE_FILE CAUSAL_LOG_FILE
export DASHBOARD_DIR DASHBOARD_ENABLED TEKHTON_HOME TEKHTON_SESSION_DIR
export TEKHTON_DIR BUILD_ERRORS_FILE REVIEWER_REPORT_FILE SECURITY_REPORT_FILE
export CLARIFICATIONS_FILE DIAGNOSIS_FILE
mkdir -p "$LOG_DIR" "$TMPDIR/.claude/dashboard/data" "${PROJECT_DIR}/${TEKHTON_DIR}"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/causality.sh"
_write_js_file() { return 0; }
_to_js_timestamp() { echo "2026-04-26T00:00:00Z"; }
_json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; printf '%s' "$s"; }
is_dashboard_enabled() { return 1; }
source "${TEKHTON_HOME}/lib/failure_context.sh"
source "${TEKHTON_HOME}/lib/diagnose.sh"

PASS=0; FAIL=0
assert_eq() {
    if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1 — expected '$2', got '$3'"; FAIL=$((FAIL+1)); fi
}
assert() {
    if [ "$2" = "0" ]; then echo "  PASS: $1"; PASS=$((PASS+1))
    else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi
}

CTX="$TMPDIR/.claude/LAST_FAILURE_CONTEXT.json"

_reset_fixture() {
    rm -f "$CTX"
    reset_failure_cause_context
    AGENT_ERROR_CATEGORY=""; AGENT_ERROR_SUBCATEGORY=""
    DIAG_CLASSIFICATION=""; DIAG_CONFIDENCE=""; DIAG_SUGGESTIONS=()
    _DIAG_PRIMARY_CATEGORY=""; _DIAG_PRIMARY_SUBCATEGORY=""
    _DIAG_PRIMARY_SIGNAL=""; _DIAG_PRIMARY_SOURCE=""
    _DIAG_SECONDARY_CATEGORY=""; _DIAG_SECONDARY_SUBCATEGORY=""
    _DIAG_SECONDARY_SIGNAL=""; _DIAG_SECONDARY_SOURCE=""
    _DIAG_SCHEMA_VERSION=""
    _DIAG_PIPELINE_STAGE=""; _DIAG_EXIT_REASON=""; _DIAG_PIPELINE_TASK=""
}

# Shared v2 fixture body — kept byte-for-byte aligned with m134 integration
# tests (per m129 acceptance criterion).
_write_v2_fixture() {
    cat > "$CTX" << 'EOF'
{
  "schema_version": 2,
  "classification": "UI_INTERACTIVE_REPORTER",
  "stage": "coder",
  "outcome": "failure",
  "task": "M03",
  "consecutive_count": 1,
  "category": "AGENT_SCOPE",
  "subcategory": "max_turns",
  "primary_cause": {
    "category": "ENVIRONMENT",
    "subcategory": "test_infra",
    "signal": "ui_timeout_interactive_report",
    "source": "build_gate"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "build_fix_budget_exhausted",
    "source": "coder_build_fix"
  }
}
EOF
}

# T1: writes_schema_v2_with_primary_secondary
echo "=== T1: writes_schema_v2_with_primary_secondary ==="
_reset_fixture
TASK="M03"
set_primary_cause "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" "build_gate"
set_secondary_cause "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted" "coder_build_fix"
write_last_failure_context "UI_INTERACTIVE_REPORTER" "coder" "failure"
assert "T1.1 file exists" "$([ -f "$CTX" ] && echo 0 || echo 1)"
assert "T1.2 schema_version 2" "$(grep -q '"schema_version": 2' "$CTX" && echo 0 || echo 1)"
assert "T1.3 primary_cause object" "$(grep -q '"primary_cause": {' "$CTX" && echo 0 || echo 1)"
assert "T1.4 primary signal" "$(grep -q '"signal": "ui_timeout_interactive_report"' "$CTX" && echo 0 || echo 1)"
assert "T1.5 secondary_cause object" "$(grep -q '"secondary_cause": {' "$CTX" && echo 0 || echo 1)"
assert "T1.6 secondary signal" "$(grep -q '"signal": "build_fix_budget_exhausted"' "$CTX" && echo 0 || echo 1)"

# T2: writes_legacy_aliases_for_compat
echo "=== T2: writes_legacy_aliases_for_compat ==="
_reset_fixture
set_secondary_cause "AGENT_SCOPE" "max_turns" "" ""
write_last_failure_context "MAX_TURNS_EXHAUSTED" "coder" "failure"
assert "T2.1 alias category from secondary" "$(grep -q '"category": "AGENT_SCOPE"' "$CTX" && echo 0 || echo 1)"
assert "T2.2 alias subcategory from secondary" "$(grep -q '"subcategory": "max_turns"' "$CTX" && echo 0 || echo 1)"
_reset_fixture
AGENT_ERROR_CATEGORY="UPSTREAM"
AGENT_ERROR_SUBCATEGORY="api_500"
write_last_failure_context "TRANSIENT_ERROR" "coder" "failure"
assert "T2.3 alias from AGENT_ERROR_CATEGORY" "$(grep -q '"category": "UPSTREAM"' "$CTX" && echo 0 || echo 1)"
assert "T2.4 alias from AGENT_ERROR_SUBCATEGORY" "$(grep -q '"subcategory": "api_500"' "$CTX" && echo 0 || echo 1)"
_reset_fixture
write_last_failure_context "UNKNOWN" "coder" "failure"
assert "T2.5 no empty category alias when unavailable" "$(grep -q '"category":' "$CTX" && echo 1 || echo 0)"

# T3: writes_pretty_printed_one_key_per_line  (CANARY for downstream parsers)
echo "=== T3: writes_pretty_printed_one_key_per_line ==="
_reset_fixture
set_primary_cause "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" "build_gate"
set_secondary_cause "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted" "coder_build_fix"
write_last_failure_context "UI_INTERACTIVE_REPORTER" "coder" "failure"
_first_pc=$(grep -n '"primary_cause": {$' "$CTX" | head -1 | cut -d: -f1)
_after=$(sed -n "$((_first_pc + 1))p" "$CTX")
assert "T3.1 primary_cause opens on own line ending with {" "$([ -n "$_first_pc" ] && echo 0 || echo 1)"
assert "T3.2 first inner key (category) on its own line" \
    "$(echo "$_after" | grep -qE '^\s+"category": "ENVIRONMENT"' && echo 0 || echo 1)"
_signal_lines=$(grep -c '"signal":' "$CTX" 2>/dev/null || echo 0)
_signal_lines="${_signal_lines//[!0-9]/}"
assert_eq "T3.3 two signal lines (primary + secondary)" "2" "$_signal_lines"

# T4: diagnose_reads_v2_primary_secondary
echo "=== T4: diagnose_reads_v2_primary_secondary ==="
_reset_fixture
_write_v2_fixture
_read_diagnostic_context 2>/dev/null || true
assert_eq "T4.1 schema_version" "2" "$_DIAG_SCHEMA_VERSION"
assert_eq "T4.2 primary category" "ENVIRONMENT" "$_DIAG_PRIMARY_CATEGORY"
assert_eq "T4.3 primary subcategory" "test_infra" "$_DIAG_PRIMARY_SUBCATEGORY"
assert_eq "T4.4 primary signal" "ui_timeout_interactive_report" "$_DIAG_PRIMARY_SIGNAL"
assert_eq "T4.5 primary source" "build_gate" "$_DIAG_PRIMARY_SOURCE"
assert_eq "T4.6 secondary category" "AGENT_SCOPE" "$_DIAG_SECONDARY_CATEGORY"
assert_eq "T4.7 secondary subcategory" "max_turns" "$_DIAG_SECONDARY_SUBCATEGORY"
assert_eq "T4.8 secondary signal" "build_fix_budget_exhausted" "$_DIAG_SECONDARY_SIGNAL"
assert_eq "T4.9 secondary source" "coder_build_fix" "$_DIAG_SECONDARY_SOURCE"

# T5: diagnose_falls_back_to_legacy_fields
echo "=== T5: diagnose_falls_back_to_legacy_fields ==="
_reset_fixture
cat > "$CTX" << 'EOF'
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
assert_eq "T5.1 schema_version empty (legacy)" "" "$_DIAG_SCHEMA_VERSION"
assert_eq "T5.2 primary slots empty" "" "$_DIAG_PRIMARY_CATEGORY"
assert_eq "T5.3 secondary slots empty" "" "$_DIAG_SECONDARY_CATEGORY"
assert_eq "T5.4 classification still parsed" "MAX_TURNS_EXHAUSTED" "$_DIAG_LAST_CLASSIFICATION"
assert_eq "T5.5 stage still parsed" "coder" "$_DIAG_PIPELINE_STAGE"

# T6: max_turns_rule_marks_secondary_symptom
echo "=== T6: max_turns_rule_marks_secondary_symptom ==="
_reset_fixture
_write_v2_fixture
_read_diagnostic_context 2>/dev/null || true
_rule_max_turns 2>/dev/null && r=0 || r=1
assert_eq "T6.1 _rule_max_turns matches" "0" "$r"
_secondary_note=$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}" | grep -q 'secondary symptom' && echo 0 || echo 1)
assert_eq "T6.2 suggestions include secondary-symptom note" "0" "$_secondary_note"
_primary_in_note=$(printf '%s\n' "${DIAG_SUGGESTIONS[@]}" | grep -q 'ENVIRONMENT/test_infra' && echo 0 || echo 1)
assert_eq "T6.3 primary cause label present" "0" "$_primary_in_note"

# T7: reset_clears_all_eight_vars
echo "=== T7: reset_clears_all_eight_vars ==="
_reset_fixture
set_primary_cause "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" "build_gate"
set_secondary_cause "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted" "coder_build_fix"
reset_failure_cause_context
for v in PRIMARY_ERROR_CATEGORY PRIMARY_ERROR_SUBCATEGORY PRIMARY_ERROR_SIGNAL PRIMARY_ERROR_SOURCE \
         SECONDARY_ERROR_CATEGORY SECONDARY_ERROR_SUBCATEGORY SECONDARY_ERROR_SIGNAL SECONDARY_ERROR_SOURCE; do
    assert_eq "T7 ${v} cleared" "" "${!v}"
done

# T8: format_summary_handles_partial_population
echo "=== T8: format_summary_handles_partial_population ==="
_reset_fixture
out=$(format_failure_cause_summary)
assert_eq "T8.1 empty when both unset" "" "$out"
_reset_fixture
set_primary_cause "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" "build_gate"
out=$(format_failure_cause_summary)
assert "T8.2 primary-only one line" "$([ "$(printf '%s\n' "$out" | wc -l)" = "1" ] && echo 0 || echo 1)"
assert "T8.3 primary line content" "$(echo "$out" | grep -q 'Primary cause: ENVIRONMENT/test_infra' && echo 0 || echo 1)"
_reset_fixture
set_secondary_cause "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted" "coder_build_fix"
out=$(format_failure_cause_summary)
assert "T8.4 secondary-only one line" "$([ "$(printf '%s\n' "$out" | wc -l)" = "1" ] && echo 0 || echo 1)"
assert "T8.5 secondary line content" "$(echo "$out" | grep -q 'Secondary cause: AGENT_SCOPE/max_turns' && echo 0 || echo 1)"
_reset_fixture
set_primary_cause "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" "build_gate"
set_secondary_cause "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted" "coder_build_fix"
out=$(format_failure_cause_summary)
assert "T8.6 both populated two lines" "$([ "$(printf '%s\n' "$out" | wc -l)" = "2" ] && echo 0 || echo 1)"

echo
echo "════════════════════════════════════════"
echo "  failure_context_schema tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
echo "All failure_context_schema tests passed"
