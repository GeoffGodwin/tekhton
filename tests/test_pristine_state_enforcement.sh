#!/usr/bin/env bash
# shellcheck disable=SC2016  # eq() uses single-quoted deferred-eval expressions
set -euo pipefail
# test_pristine_state_enforcement.sh — Tests for Milestone 92.
# Verifies: config defaults, acceptance/completion gates no longer auto-pass
# on pre_existing, pre-run clean sweep enable/skip + baseline re-capture.

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

_PASS=0 _FAIL=0
pass() { _PASS=$((_PASS + 1)); echo "PASS: $1"; }
fail() { _FAIL=$((_FAIL + 1)); echo "FAIL: $1"; }
# eq COND DESC — pass if [[ COND ]] is true (eval'd), else fail.
eq() { if eval "[[ $1 ]]"; then pass "$2"; else fail "$2 (cond: $1)"; fi; }

log() { :; }
warn() { :; }
success() { :; }
header() { :; }
export -f log warn success header

# --- Suite 1: Config defaults ------------------------------------------------
echo "=== Suite 1: Config defaults ==="
_clamp_config_value() { :; }
_clamp_config_float() { :; }
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/config_defaults.sh"

eq '"${TEST_BASELINE_PASS_ON_PREEXISTING}" = "false"' "1.1 TEST_BASELINE_PASS_ON_PREEXISTING defaults to false"
eq '"${PRE_RUN_CLEAN_ENABLED}" = "true"' "1.2 PRE_RUN_CLEAN_ENABLED defaults to true"
eq '"${PRE_RUN_FIX_MAX_TURNS}" = "20"' "1.3 PRE_RUN_FIX_MAX_TURNS defaults to 20"
eq '"${PRE_RUN_FIX_MAX_ATTEMPTS}" = "1"' "1.4 PRE_RUN_FIX_MAX_ATTEMPTS defaults to 1"

# --- Suite 2: Milestone acceptance no longer auto-passes on pre_existing ----
echo "=== Suite 2: pre_existing does not auto-pass ==="
run_build_gate() { return 0; }
parse_milestones() { echo ""; }
has_milestone_manifest() { return 1; }
save_acceptance_test_output() { :; }
has_test_baseline() { return 0; }
compare_test_with_baseline() { echo "pre_existing"; }
export -f run_build_gate parse_milestones has_milestone_manifest
export -f save_acceptance_test_output has_test_baseline compare_test_with_baseline

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/milestone_acceptance.sh"

cat > "$TEST_TMP/failing_test.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: pre_existing_test_a"
exit 1
EOF
chmod +x "$TEST_TMP/failing_test.sh"
TEST_CMD="bash $TEST_TMP/failing_test.sh"
TEST_BASELINE_ENABLED=true
ANALYZE_CMD=""
PROJECT_RULES_FILE="$TEST_TMP/claude.md"
touch "$PROJECT_RULES_FILE"
export TEST_CMD TEST_BASELINE_ENABLED ANALYZE_CMD PROJECT_RULES_FILE

TEST_BASELINE_PASS_ON_PREEXISTING=false
export TEST_BASELINE_PASS_ON_PREEXISTING

_result=0
check_milestone_acceptance "1" "$PROJECT_RULES_FILE" >/dev/null 2>&1 || _result=$?
eq '"$_result" -ne 0' "2.1 check_milestone_acceptance returns non-zero for pre_existing+PASS=false"

# --- Suite 3: pre_existing auto-passes when opted in ------------------------
echo "=== Suite 3: pre_existing auto-passes with opt-in ==="
TEST_BASELINE_PASS_ON_PREEXISTING=true
export TEST_BASELINE_PASS_ON_PREEXISTING

_result=0
check_milestone_acceptance "1" "$PROJECT_RULES_FILE" >/dev/null 2>&1 || _result=$?
eq '"$_result" -eq 0' "3.1 check_milestone_acceptance returns 0 for pre_existing+PASS=true (legacy opt-in preserved)"

TEST_BASELINE_PASS_ON_PREEXISTING=false
export TEST_BASELINE_PASS_ON_PREEXISTING

# --- Suite 4: Pre-run clean sweep skipped when disabled ---------------------
echo "=== Suite 4: PRE_RUN_CLEAN_ENABLED=false skips sweep ==="
PROJECT_DIR="$TEST_TMP/proj_prerun"
mkdir -p "$PROJECT_DIR/.claude"
LOG_FILE="$TEST_TMP/prerun.log"
touch "$LOG_FILE"
AGENT_TOOLS_BUILD_FIX="Read Write Edit Bash"
PROJECT_NAME="test-proj"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
CLAUDE_JR_CODER_MODEL="claude-sonnet-4-6"
_CURRENT_MILESTONE="92"
export PROJECT_DIR LOG_FILE AGENT_TOOLS_BUILD_FIX PROJECT_NAME
export JR_CODER_ROLE_FILE CLAUDE_JR_CODER_MODEL _CURRENT_MILESTONE

_MOCK_RUN_AGENT_CALLS=0
_MOCK_CAPTURE_CALLS=0
run_agent() { _MOCK_RUN_AGENT_CALLS=$(( _MOCK_RUN_AGENT_CALLS + 1 )); return 0; }
render_prompt() { echo "# mock prompt"; }
capture_test_baseline() { _MOCK_CAPTURE_CALLS=$(( _MOCK_CAPTURE_CALLS + 1 )); return 0; }

TEST_CMD="bash $TEST_TMP/failing_test.sh"
export TEST_CMD

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder_prerun.sh"

PRE_RUN_CLEAN_ENABLED=false
export PRE_RUN_CLEAN_ENABLED
_MOCK_RUN_AGENT_CALLS=0
run_prerun_clean_sweep >/dev/null 2>&1

eq '"$_MOCK_RUN_AGENT_CALLS" -eq 0' "4.1 run_agent not called when PRE_RUN_CLEAN_ENABLED=false"

# --- Suite 5: Baseline is re-captured after a successful pre-run fix --------
echo "=== Suite 5: baseline captured after successful fix ==="
PRE_RUN_CLEAN_ENABLED=true
PRE_RUN_FIX_MAX_ATTEMPTS=1
PRE_RUN_FIX_MAX_TURNS=5
export PRE_RUN_CLEAN_ENABLED PRE_RUN_FIX_MAX_ATTEMPTS PRE_RUN_FIX_MAX_TURNS

# Script that fails on first call and passes afterwards (simulates a fix).
cat > "$TEST_TMP/flaky_test.sh" <<'EOF'
#!/usr/bin/env bash
STATE_FILE="${TEST_TMP:-/tmp}/flaky_state"
if [[ ! -f "$STATE_FILE" ]]; then
    echo "first-call" > "$STATE_FILE"
    echo "FAIL: initial"
    exit 1
fi
echo "All tests pass"
exit 0
EOF
chmod +x "$TEST_TMP/flaky_test.sh"
export TEST_TMP
rm -f "$TEST_TMP/flaky_state"
TEST_CMD="bash $TEST_TMP/flaky_test.sh"
export TEST_CMD

BASELINE_JSON="$PROJECT_DIR/.claude/TEST_BASELINE.json"
echo '{"stale":"baseline"}' > "$BASELINE_JSON"

_MOCK_CAPTURE_CALLS=0
_MOCK_RUN_AGENT_CALLS=0
run_prerun_clean_sweep >/dev/null 2>&1

eq '"$_MOCK_CAPTURE_CALLS" -ge 1' "5.1 capture_test_baseline called after successful fix"
eq '"$_MOCK_RUN_AGENT_CALLS" -ge 1' "5.2 fix agent invoked when tests fail pre-coder"

# --- Suite 6: run_completion_gate respects PASS_ON_PREEXISTING --------------
echo "=== Suite 6: run_completion_gate pre_existing+PASS_ON_PREEXISTING=false ==="
CODER_SUMMARY_FILE="$TEST_TMP/coder_summary_s6.md"
cat > "$CODER_SUMMARY_FILE" <<'EOF'
## Status: COMPLETE

## Summary
Done.

## Files Modified
- `some/file.sh`
EOF
export CODER_SUMMARY_FILE

cat > "$TEST_TMP/failing_s6.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "FAIL: pre_existing_test"
exit 1
SCRIPT
chmod +x "$TEST_TMP/failing_s6.sh"
TEST_CMD="bash $TEST_TMP/failing_s6.sh"
COMPLETION_GATE_TEST_ENABLED=true
export TEST_CMD COMPLETION_GATE_TEST_ENABLED

has_test_baseline() { return 0; }
compare_test_with_baseline() { echo "pre_existing"; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/gates_completion.sh"
_warn_summary_drift() { :; }

TEST_BASELINE_PASS_ON_PREEXISTING=false
export TEST_BASELINE_PASS_ON_PREEXISTING
_result=0
run_completion_gate >/dev/null 2>&1 || _result=$?
eq '"$_result" -ne 0' "6.1 run_completion_gate returns non-zero for pre_existing+PASS=false"

TEST_BASELINE_PASS_ON_PREEXISTING=true
export TEST_BASELINE_PASS_ON_PREEXISTING
_result=0
run_completion_gate >/dev/null 2>&1 || _result=$?
eq '"$_result" -eq 0' "6.2 run_completion_gate returns 0 for pre_existing+PASS=true"

# --- Suite 7: pre-run fix fails → run_prerun_clean_sweep returns 0 ----------
echo "=== Suite 7: pre-run fix fails → pipeline proceeds gracefully ==="
PRE_RUN_CLEAN_ENABLED=true
PRE_RUN_FIX_MAX_ATTEMPTS=1
PRE_RUN_FIX_MAX_TURNS=5
export PRE_RUN_CLEAN_ENABLED PRE_RUN_FIX_MAX_ATTEMPTS PRE_RUN_FIX_MAX_TURNS

cat > "$TEST_TMP/always_fail.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "FAIL: always fails"
exit 1
SCRIPT
chmod +x "$TEST_TMP/always_fail.sh"
TEST_CMD="bash $TEST_TMP/always_fail.sh"
export TEST_CMD

_MOCK_RUN_AGENT_CALLS=0
_MOCK_CAPTURE_CALLS=0
run_agent() { _MOCK_RUN_AGENT_CALLS=$(( _MOCK_RUN_AGENT_CALLS + 1 )); return 1; }
capture_test_baseline() { _MOCK_CAPTURE_CALLS=$(( _MOCK_CAPTURE_CALLS + 1 )); return 0; }

_sweep_exit=0
run_prerun_clean_sweep >/dev/null 2>&1 || _sweep_exit=$?

eq '"$_sweep_exit" -eq 0' "7.1 run_prerun_clean_sweep returns 0 when fix agent fails (graceful fallthrough)"
eq '"$_MOCK_CAPTURE_CALLS" -eq 0' "7.2 capture_test_baseline not called when fix fails"
eq '"$_MOCK_RUN_AGENT_CALLS" -ge 1' "7.3 fix agent attempted at least once when tests fail pre-coder"

echo ""
echo "---"
echo "Pristine state enforcement tests: ${_PASS} passed, ${_FAIL} failed"
if [[ "$_FAIL" -gt 0 ]]; then exit 1; fi
exit 0
