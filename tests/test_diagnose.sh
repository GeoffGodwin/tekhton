#!/usr/bin/env bash
# =============================================================================
# test_diagnose.sh — Diagnostic engine tests
#
# Tests:
# - Each diagnostic rule against fixture state
# - Rule priority ordering
# - Causal chain rendering from fixture causal logs
# - Graceful fallback when causal log absent
# - Recurring failure detection
# - Terminal output formatting
# - LAST_FAILURE_CONTEXT.json write and clear
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

export PROJECT_DIR LOG_DIR PIPELINE_STATE_FILE CAUSAL_LOG_FILE
export DASHBOARD_DIR DASHBOARD_ENABLED TEKHTON_HOME TEKHTON_SESSION_DIR

mkdir -p "$LOG_DIR/runs" "$TMPDIR/.claude/dashboard/data" "$TMPDIR/.claude/milestones"

# --- Source dependencies -----------------------------------------------------
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/causality.sh"
# Mock _write_js_file since dashboard_parsers.sh is needed
_write_js_file() { return 0; }
_to_js_timestamp() { echo "2026-03-23T00:00:00Z"; }
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
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

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

_reset_fixture() {
    rm -f "$PIPELINE_STATE_FILE"
    rm -f "$CAUSAL_LOG_FILE"
    rm -f "$TMPDIR/BUILD_ERRORS.md"
    rm -f "$TMPDIR/REVIEWER_REPORT.md"
    rm -f "$TMPDIR/SECURITY_REPORT.md"
    rm -f "$TMPDIR/CLARIFICATIONS.md"
    rm -f "$TMPDIR/.claude/QUOTA_PAUSED"
    rm -f "$TMPDIR/.claude/logs/RUN_SUMMARY.json"
    rm -f "$TMPDIR/.claude/LAST_FAILURE_CONTEXT.json"
    rm -f "$TMPDIR/DIAGNOSIS.md"
    DIAG_CLASSIFICATION=""
    DIAG_CONFIDENCE=""
    DIAG_SUGGESTIONS=()
    _DIAG_PIPELINE_OUTCOME=""
    _DIAG_PIPELINE_STAGE=""
    _DIAG_CAUSAL_EVENTS=""
}

_create_pipeline_state() {
    local stage="$1"
    local reason="$2"
    local error_cat="${3:-}"
    local error_sub="${4:-}"
    mkdir -p "$(dirname "$PIPELINE_STATE_FILE")"
    cat > "$PIPELINE_STATE_FILE" << EOF
# Pipeline State — 2026-03-23 10:45:00
## Exit Stage
${stage}

## Exit Reason
${reason}

## Resume Command
--start-at ${stage}

## Task
Test task

## Notes


## Milestone
17

## Error Classification
$(if [[ -n "$error_cat" ]]; then
echo "Category: ${error_cat}"
echo "Subcategory: ${error_sub}"
echo "Transient: false"
fi)
EOF
}

_create_run_summary() {
    local outcome="$1"
    local rework_cycles="${2:-0}"
    local split_depth="${3:-0}"
    cat > "$TMPDIR/.claude/logs/RUN_SUMMARY.json" << EOF
{
  "milestone": "17",
  "outcome": "${outcome}",
  "attempts": 1,
  "total_agent_calls": 5,
  "wall_clock_seconds": 300,
  "files_changed": [],
  "error_classes_encountered": [],
  "recovery_actions_taken": [],
  "rework_cycles": ${rework_cycles},
  "split_depth": ${split_depth},
  "timestamp": "2026-03-23T10:45:00Z"
}
EOF
}

# =============================================================================
# Test Suite 1: Rule priority ordering
# =============================================================================
echo "=== Test Suite 1: Rule priority ordering ==="

assert_eq "1.1 DIAGNOSE_RULES has 12 entries" "12" "${#DIAGNOSE_RULES[@]}"
assert_eq "1.2 first rule is _rule_build_failure" "_rule_build_failure" "${DIAGNOSE_RULES[0]}"
assert_eq "1.3 second rule is _rule_review_loop" "_rule_review_loop" "${DIAGNOSE_RULES[1]}"
assert_eq "1.4 last rule is _rule_unknown" "_rule_unknown" "${DIAGNOSE_RULES[11]}"

# =============================================================================
# Test Suite 2: _rule_build_failure
# =============================================================================
echo "=== Test Suite 2: _rule_build_failure ==="

_reset_fixture

# No BUILD_ERRORS.md — should not match
_rule_build_failure 2>/dev/null && r=0 || r=1
assert_eq "2.1 no match without BUILD_ERRORS.md" "1" "$r"

# Empty BUILD_ERRORS.md — should not match
touch "$TMPDIR/BUILD_ERRORS.md"
_rule_build_failure 2>/dev/null && r=0 || r=1
assert_eq "2.2 no match with empty BUILD_ERRORS.md" "1" "$r"

# Non-empty BUILD_ERRORS.md — should match
echo "error: compilation failed" > "$TMPDIR/BUILD_ERRORS.md"
_rule_build_failure 2>/dev/null && r=0 || r=1
assert_eq "2.3 matches with non-empty BUILD_ERRORS.md" "0" "$r"
assert_eq "2.4 classification is BUILD_FAILURE" "BUILD_FAILURE" "$DIAG_CLASSIFICATION"
assert_eq "2.5 confidence is high" "high" "$DIAG_CONFIDENCE"

# =============================================================================
# Test Suite 3: _rule_review_loop
# =============================================================================
echo "=== Test Suite 3: _rule_review_loop ==="

_reset_fixture

# No state file — should not match
_rule_review_loop 2>/dev/null && r=0 || r=1
assert_eq "3.1 no match without state file" "1" "$r"

# State file with review stage + reviewer report with CHANGES_REQUIRED
_create_pipeline_state "review" "Max review cycles"
echo -e "## Verdict\nCHANGES_REQUIRED" > "$TMPDIR/REVIEWER_REPORT.md"
_rule_review_loop 2>/dev/null && r=0 || r=1
assert_eq "3.2 matches on review stage with CHANGES_REQUIRED" "0" "$r"
assert_eq "3.3 classification is REVIEW_REJECTION_LOOP" "REVIEW_REJECTION_LOOP" "$DIAG_CLASSIFICATION"

# =============================================================================
# Test Suite 4: _rule_security_halt
# =============================================================================
echo "=== Test Suite 4: _rule_security_halt ==="

_reset_fixture

# No security file — should not match (forward-compat)
_rule_security_halt 2>/dev/null && r=0 || r=1
assert_eq "4.1 no match without SECURITY_REPORT.md" "1" "$r"

# Security report with HALT
echo -e "Verdict: HALT\nCritical: 2" > "$TMPDIR/SECURITY_REPORT.md"
_rule_security_halt 2>/dev/null && r=0 || r=1
assert_eq "4.2 matches with HALT in security report" "0" "$r"
assert_eq "4.3 classification is SECURITY_HALT" "SECURITY_HALT" "$DIAG_CLASSIFICATION"

# =============================================================================
# Test Suite 5: _rule_intake_clarity
# =============================================================================
echo "=== Test Suite 5: _rule_intake_clarity ==="

_reset_fixture

# No clarifications file — should not match
_rule_intake_clarity 2>/dev/null && r=0 || r=1
assert_eq "5.1 no match without CLARIFICATIONS.md" "1" "$r"

# Clarifications with unanswered + intake stage
_create_pipeline_state "intake" "Needs clarification"
cat > "$TMPDIR/CLARIFICATIONS.md" << 'EOF'
- [ ] What is the auth provider?
- [x] What database?
EOF
_rule_intake_clarity 2>/dev/null && r=0 || r=1
assert_eq "5.2 matches with unanswered clarifications at intake" "0" "$r"
assert_eq "5.3 classification is INTAKE_NEEDS_CLARITY" "INTAKE_NEEDS_CLARITY" "$DIAG_CLASSIFICATION"

# =============================================================================
# Test Suite 6: _rule_quota_exhausted
# =============================================================================
echo "=== Test Suite 6: _rule_quota_exhausted ==="

_reset_fixture

# No quota marker — should not match
_rule_quota_exhausted 2>/dev/null && r=0 || r=1
assert_eq "6.1 no match without QUOTA_PAUSED" "1" "$r"

# Quota marker exists
echo "paused_at=2026-03-23T10:00:00Z" > "$TMPDIR/.claude/QUOTA_PAUSED"
_rule_quota_exhausted 2>/dev/null && r=0 || r=1
assert_eq "6.2 matches with QUOTA_PAUSED" "0" "$r"
assert_eq "6.3 classification is QUOTA_EXHAUSTED" "QUOTA_EXHAUSTED" "$DIAG_CLASSIFICATION"

# =============================================================================
# Test Suite 7: _rule_stuck_loop
# =============================================================================
echo "=== Test Suite 7: _rule_stuck_loop ==="

_reset_fixture

# State with high attempt count
_create_pipeline_state "coder" "Stuck loop"
# Add orchestration context with high attempt count
echo -e "\n## Orchestration Context\nPipeline attempt: 5" >> "$PIPELINE_STATE_FILE"
MAX_PIPELINE_ATTEMPTS=5
_rule_stuck_loop 2>/dev/null && r=0 || r=1
assert_eq "7.1 matches when attempts >= max" "0" "$r"
assert_eq "7.2 classification is STUCK_LOOP" "STUCK_LOOP" "$DIAG_CLASSIFICATION"

# Low attempt count — no match
_reset_fixture
_create_pipeline_state "coder" "Normal exit"
echo -e "\n## Orchestration Context\nPipeline attempt: 2" >> "$PIPELINE_STATE_FILE"
_rule_stuck_loop 2>/dev/null && r=0 || r=1
assert_eq "7.3 no match when attempts < max" "1" "$r"

# =============================================================================
# Test Suite 8: _rule_turn_exhaustion
# =============================================================================
echo "=== Test Suite 8: _rule_turn_exhaustion ==="

_reset_fixture

# State with max_turns error
_create_pipeline_state "coder" "Turn exhaustion" "AGENT_SCOPE" "max_turns"
_rule_turn_exhaustion 2>/dev/null && r=0 || r=1
assert_eq "8.1 matches on AGENT_SCOPE/max_turns" "0" "$r"
assert_eq "8.2 classification is TURN_EXHAUSTION" "TURN_EXHAUSTION" "$DIAG_CLASSIFICATION"

# Different error — no match
_reset_fixture
_create_pipeline_state "coder" "Build failure" "PIPELINE" "internal"
_rule_turn_exhaustion 2>/dev/null && r=0 || r=1
assert_eq "8.3 no match on non-max_turns error" "1" "$r"

# =============================================================================
# Test Suite 9: _rule_split_depth
# =============================================================================
echo "=== Test Suite 9: _rule_split_depth ==="

_reset_fixture

# RUN_SUMMARY with high split depth
_create_run_summary "failure" 0 3
MILESTONE_MAX_SPLIT_DEPTH=3
_rule_split_depth 2>/dev/null && r=0 || r=1
assert_eq "9.1 matches when split_depth >= max" "0" "$r"
assert_eq "9.2 classification is MILESTONE_SPLIT_DEPTH" "MILESTONE_SPLIT_DEPTH" "$DIAG_CLASSIFICATION"

# Low split depth — no match
_reset_fixture
_create_run_summary "failure" 0 1
_rule_split_depth 2>/dev/null && r=0 || r=1
assert_eq "9.3 no match when split_depth < max" "1" "$r"

# =============================================================================
# Test Suite 10: _rule_transient_error
# =============================================================================
echo "=== Test Suite 10: _rule_transient_error ==="

_reset_fixture

# State with upstream error
_create_pipeline_state "coder" "API error" "UPSTREAM" "api_500"
# Add Transient: true to the error classification section
sed -i 's/Transient: false/Transient: true/' "$PIPELINE_STATE_FILE"
_rule_transient_error 2>/dev/null && r=0 || r=1
assert_eq "10.1 matches on UPSTREAM error" "0" "$r"
assert_eq "10.2 classification is TRANSIENT_ERROR" "TRANSIENT_ERROR" "$DIAG_CLASSIFICATION"

# =============================================================================
# Test Suite 11: _rule_unknown (always matches)
# =============================================================================
echo "=== Test Suite 11: _rule_unknown ==="

_reset_fixture

_rule_unknown 2>/dev/null && r=0 || r=1
assert_eq "11.1 always matches" "0" "$r"
assert_eq "11.2 classification is UNKNOWN" "UNKNOWN" "$DIAG_CLASSIFICATION"

# =============================================================================
# Test Suite 12: classify_failure_diag — success detection
# =============================================================================
echo "=== Test Suite 12: classify_failure_diag success ==="

_reset_fixture
_DIAG_PIPELINE_OUTCOME="success"
classify_failure_diag
assert_eq "12.1 classifies success" "SUCCESS" "$DIAG_CLASSIFICATION"
assert_eq "12.2 confidence is high" "high" "$DIAG_CONFIDENCE"

# =============================================================================
# Test Suite 13: classify_failure_diag — priority (BUILD_FAILURE before STUCK)
# =============================================================================
echo "=== Test Suite 13: classify_failure_diag priority ==="

_reset_fixture
_DIAG_PIPELINE_OUTCOME="failure"
echo "error: compilation failed" > "$TMPDIR/BUILD_ERRORS.md"
_create_pipeline_state "coder" "Stuck loop"
echo -e "\n## Orchestration Context\nPipeline attempt: 5" >> "$PIPELINE_STATE_FILE"
MAX_PIPELINE_ATTEMPTS=5
classify_failure_diag
assert_eq "13.1 BUILD_FAILURE takes priority over STUCK_LOOP" "BUILD_FAILURE" "$DIAG_CLASSIFICATION"

# =============================================================================
# Test Suite 14: Graceful fallback without causal log
# =============================================================================
echo "=== Test Suite 14: Fallback without causal log ==="

_reset_fixture
_DIAG_PIPELINE_OUTCOME="failure"
echo "error: compilation failed" > "$TMPDIR/BUILD_ERRORS.md"
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
assert_eq "14.1 works without causal log" "BUILD_FAILURE" "$DIAG_CLASSIFICATION"

# Cause chain should be empty
assert_eq "14.2 cause chain empty without causal log" "" "$_DIAG_CAUSE_CHAIN"

# =============================================================================
# Test Suite 15: DIAGNOSIS.md generation
# =============================================================================
echo "=== Test Suite 15: DIAGNOSIS.md generation ==="

_reset_fixture
_DIAG_PIPELINE_OUTCOME="failure"
echo "error: test failure" > "$TMPDIR/BUILD_ERRORS.md"
_create_run_summary "failure"
_read_diagnostic_context 2>/dev/null || true
classify_failure_diag
generate_diagnosis_report

assert "15.1 DIAGNOSIS.md created" \
    "$([ -f "$TMPDIR/DIAGNOSIS.md" ] && echo 0 || echo 1)"
assert "15.2 DIAGNOSIS.md contains classification" \
    "$(grep -q 'BUILD_FAILURE' "$TMPDIR/DIAGNOSIS.md" 2>/dev/null && echo 0 || echo 1)"
assert "15.3 DIAGNOSIS.md contains Recovery Suggestions" \
    "$(grep -q '## Recovery Suggestions' "$TMPDIR/DIAGNOSIS.md" 2>/dev/null && echo 0 || echo 1)"

# =============================================================================
# Test Suite 16: LAST_FAILURE_CONTEXT.json
# =============================================================================
echo "=== Test Suite 16: LAST_FAILURE_CONTEXT.json ==="

_reset_fixture
TASK="Test task for context"
write_last_failure_context "BUILD_FAILURE" "coder" "failure"

assert "16.1 LAST_FAILURE_CONTEXT.json created" \
    "$([ -f "$TMPDIR/.claude/LAST_FAILURE_CONTEXT.json" ] && echo 0 || echo 1)"
assert "16.2 contains classification" \
    "$(grep -q '"classification": "BUILD_FAILURE"' "$TMPDIR/.claude/LAST_FAILURE_CONTEXT.json" 2>/dev/null && echo 0 || echo 1)"
assert "16.3 consecutive count is 1" \
    "$(grep -q '"consecutive_count": 1' "$TMPDIR/.claude/LAST_FAILURE_CONTEXT.json" 2>/dev/null && echo 0 || echo 1)"

# Write again with same classification — count should increment
write_last_failure_context "BUILD_FAILURE" "coder" "failure"
assert "16.4 consecutive count increments to 2" \
    "$(grep -q '"consecutive_count": 2' "$TMPDIR/.claude/LAST_FAILURE_CONTEXT.json" 2>/dev/null && echo 0 || echo 1)"

# Different classification — count resets
write_last_failure_context "TRANSIENT_ERROR" "coder" "failure"
assert "16.5 consecutive count resets on different classification" \
    "$(grep -q '"consecutive_count": 1' "$TMPDIR/.claude/LAST_FAILURE_CONTEXT.json" 2>/dev/null && echo 0 || echo 1)"

# =============================================================================
# Test Suite 17: run_diagnose with no runs
# =============================================================================
echo "=== Test Suite 17: run_diagnose with no runs ==="

_reset_fixture
output=$(run_diagnose 2>/dev/null)
assert "17.1 no-runs message shown" \
    "$(echo "$output" | grep -q 'No pipeline runs found' && echo 0 || echo 1)"

# =============================================================================
# Test Suite 18: Causal chain rendering
# =============================================================================
echo "=== Test Suite 18: Causal chain rendering ==="

_reset_fixture
# Create a simple causal log
mkdir -p "$LOG_DIR"
cat > "$CAUSAL_LOG_FILE" << 'EOF'
{"id":"scout.001","ts":"2026-03-23T10:00:00Z","run_id":"run_20260323","milestone":"17","type":"stage_start","stage":"scout","detail":"","caused_by":[],"verdict":null,"context":null}
{"id":"coder.001","ts":"2026-03-23T10:01:00Z","run_id":"run_20260323","milestone":"17","type":"stage_start","stage":"coder","detail":"","caused_by":["scout.001"],"verdict":null,"context":null}
{"id":"coder.002","ts":"2026-03-23T10:02:00Z","run_id":"run_20260323","milestone":"17","type":"build_gate","stage":"coder","detail":"FAIL","caused_by":["coder.001"],"verdict":null,"context":null}
EOF

_create_run_summary "failure"
_read_diagnostic_context 2>/dev/null || true

assert "18.1 causal events populated" \
    "$([ -n "$_DIAG_CAUSAL_EVENTS" ] && echo 0 || echo 1)"
assert "18.2 terminal event is last line" \
    "$(echo "$_DIAG_TERMINAL_EVENT" | grep -q 'build_gate' && echo 0 || echo 1)"

# =============================================================================
# Test Suite 19: print_crash_first_aid
# =============================================================================
echo "=== Test Suite 19: print_crash_first_aid ==="

_reset_fixture

# Quota pause
echo "paused_at=2026-03-23T10:00:00Z" > "$TMPDIR/.claude/QUOTA_PAUSED"
output=$(print_crash_first_aid 2>&1)
assert "19.1 quota first-aid message" \
    "$(echo "$output" | grep -q 'quota' && echo 0 || echo 1)"
rm -f "$TMPDIR/.claude/QUOTA_PAUSED"

# Build failure
echo "error: compilation failed" > "$TMPDIR/BUILD_ERRORS.md"
output=$(print_crash_first_aid 2>&1)
assert "19.2 build first-aid message" \
    "$(echo "$output" | grep -q 'Build failure' && echo 0 || echo 1)"
rm -f "$TMPDIR/BUILD_ERRORS.md"

# Resumable state
_create_pipeline_state "coder" "Interrupted"
output=$(print_crash_first_aid 2>&1)
assert "19.3 resumable first-aid message" \
    "$(echo "$output" | grep -q 'checkpoint saved' && echo 0 || echo 1)"

# =============================================================================
# Test Suite 20: emit_dashboard_diagnosis — JSON serialization
# =============================================================================
echo "=== Test Suite 20: emit_dashboard_diagnosis ==="

_reset_fixture

# Override is_dashboard_enabled to return true for this suite
is_dashboard_enabled() { return 0; }

# Capture what _write_js_file is called with
_CAPTURED_JS_KEY=""
_CAPTURED_JS_JSON=""
_write_js_file() {
    # $1 = output path, $2 = key, $3 = json
    _CAPTURED_JS_KEY="$2"
    _CAPTURED_JS_JSON="$3"
    return 0
}

# 20.1 — No classification → available:false
DIAG_CLASSIFICATION=""
DIAG_CONFIDENCE=""
DIAG_SUGGESTIONS=()
_DIAG_PIPELINE_STAGE=""
_DIAG_CAUSE_CHAIN_SHORT=""
_DIAG_RECURRING_COUNT=0

emit_dashboard_diagnosis
assert_eq "20.1 available:false when no classification" '{"available":false}' "$_CAPTURED_JS_JSON"

# 20.2 — SUCCESS classification → available:false
DIAG_CLASSIFICATION="SUCCESS"
DIAG_CONFIDENCE="high"
DIAG_SUGGESTIONS=("Last run completed successfully.")
emit_dashboard_diagnosis
assert_eq "20.2 available:false for SUCCESS classification" '{"available":false}' "$_CAPTURED_JS_JSON"

# 20.3 — BUILD_FAILURE → available:true with required fields
DIAG_CLASSIFICATION="BUILD_FAILURE"
DIAG_CONFIDENCE="high"
DIAG_SUGGESTIONS=("Fix the build errors in BUILD_ERRORS.md")
_DIAG_PIPELINE_STAGE="coder"
_DIAG_CAUSE_CHAIN_SHORT="build_gate -> error"
_DIAG_RECURRING_COUNT=1

emit_dashboard_diagnosis

assert "20.3 available:true for BUILD_FAILURE" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '"available":true' && echo 0 || echo 1)"
assert "20.4 classification field present" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '"classification":"BUILD_FAILURE"' && echo 0 || echo 1)"
assert "20.5 confidence field present" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '"confidence":"high"' && echo 0 || echo 1)"
assert "20.6 stage field present" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '"stage":"coder"' && echo 0 || echo 1)"
assert "20.7 cause_chain field present" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '"cause_chain"' && echo 0 || echo 1)"
assert "20.8 suggestions array present" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '"suggestions":\[' && echo 0 || echo 1)"
assert "20.9 TK_DIAGNOSIS key used" \
    "$([ "$_CAPTURED_JS_KEY" = 'TK_DIAGNOSIS' ] && echo 0 || echo 1)"

# 20.10 — Special character escaping in suggestions
DIAG_CLASSIFICATION="BUILD_FAILURE"
DIAG_SUGGESTIONS=('Run: make "clean" && build' 'Check file C:\path\to\file')
_DIAG_CAUSE_CHAIN_SHORT=""
emit_dashboard_diagnosis

assert "20.10 double-quotes escaped in suggestions" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '\\"clean\\"' && echo 0 || echo 1)"
assert "20.11 backslashes escaped in suggestions" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '\\\\path' && echo 0 || echo 1)"

# 20.12 — Multiple suggestions produce comma-separated JSON array
DIAG_CLASSIFICATION="TRANSIENT_ERROR"
DIAG_CONFIDENCE="medium"
DIAG_SUGGESTIONS=("Retry the pipeline" "Check API status" "Wait 5 minutes")
_DIAG_PIPELINE_STAGE="coder"
emit_dashboard_diagnosis

assert "20.12 multiple suggestions in array" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '"Retry the pipeline","Check API status","Wait 5 minutes"' && echo 0 || echo 1)"

# 20.13 — cause_chain escaping
DIAG_CLASSIFICATION="BUILD_FAILURE"
DIAG_SUGGESTIONS=("Fix it")
_DIAG_CAUSE_CHAIN_SHORT='error "critical" -> build'
emit_dashboard_diagnosis

assert "20.13 cause chain quotes escaped" \
    "$(echo "$_CAPTURED_JS_JSON" | grep -q '\\"critical\\"' && echo 0 || echo 1)"

# Restore mock to disabled for remaining tests
is_dashboard_enabled() { return 1; }

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  diagnose tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All diagnose tests passed"
