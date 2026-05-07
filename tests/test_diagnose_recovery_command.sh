#!/usr/bin/env bash
# Test: _diagnose_recovery_command() — concrete CLI recovery from state
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Stubs for config values. m10: state file is JSON.
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.json"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude/milestones" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_AUTO_MIGRATE=true
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
source "${TEKHTON_HOME}/lib/milestone_progress.sh"

cd "$TMPDIR"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# Helper: write pipeline state file. m10: emit a tekhton.state.v1 JSON
# envelope (exit_stage / resume_task / milestone_id) instead of the legacy
# "## Heading" markdown — the bash legacy reader was retired with the rest
# of the bash supervisor.
write_state() {
    local stage="$1" task="$2" milestone="${3:-}"
    mkdir -p "${TMPDIR}/.claude"
    cat > "$PIPELINE_STATE_FILE" << EOF
{
  "proto":"tekhton.state.v1",
  "exit_stage":"${stage}",
  "resume_task":"${task}",
  "milestone_id":"${milestone}"
}
EOF
}

# ── Test 1: Valid state with task/stage/milestone → concrete command ──
echo "Test 1: Valid state with task/stage/milestone"
write_state "review" "Add user auth" "M06: Payment Processing"

output=$(_diagnose_recovery_command 2>/dev/null)
if echo "$output" | grep -q "tekhton --start-at review"; then
    pass "Start-at review stage"
else
    fail "Expected --start-at review: $output"
fi
if echo "$output" | grep -q -- '--milestone.*M06.*Payment Processing'; then
    pass "Includes milestone flag"
else
    fail "Expected --milestone in output: $output"
fi
if echo "$output" | grep -q 'Add user auth'; then
    pass "Includes task description"
else
    fail "Expected task description: $output"
fi

# ── Test 2: Missing PIPELINE_STATE_FILE → empty output ───────────────
echo "Test 2: Missing state file — empty output"
rm -f "$PIPELINE_STATE_FILE"

output=$(_diagnose_recovery_command 2>/dev/null)
if [[ -z "$output" ]]; then
    pass "Empty output for missing state file"
else
    fail "Expected empty output: $output"
fi

# ── Test 3: Coder stage → start-at coder ─────────────────────────────
echo "Test 3: Coder stage"
write_state "coder" "Fix login bug" ""

output=$(_diagnose_recovery_command 2>/dev/null)
if echo "$output" | grep -q "tekhton --start-at coder"; then
    pass "Coder stage maps to --start-at coder"
else
    fail "Expected --start-at coder: $output"
fi

# ── Test 4: Tester stage → start-at tester ───────────────────────────
echo "Test 4: Tester stage"
write_state "tester" "Write tests for auth" ""

output=$(_diagnose_recovery_command 2>/dev/null)
if echo "$output" | grep -q "tekhton --start-at tester"; then
    pass "Tester stage maps to --start-at tester"
else
    fail "Expected --start-at tester: $output"
fi

# ── Test 5: Reviewer stage → start-at review ─────────────────────────
echo "Test 5: Reviewer stage maps to review"
write_state "reviewer" "Review the code" ""

output=$(_diagnose_recovery_command 2>/dev/null)
if echo "$output" | grep -q "tekhton --start-at review"; then
    pass "Reviewer stage maps to --start-at review"
else
    fail "Expected --start-at review for reviewer: $output"
fi

# ── Test 6: No milestone in state → no --milestone flag ──────────────
echo "Test 6: No milestone → no --milestone flag"
write_state "coder" "Simple task" "none"

output=$(_diagnose_recovery_command 2>/dev/null)
if echo "$output" | grep -q -- "--milestone"; then
    fail "Should not include --milestone for 'none'"
else
    pass "No --milestone flag for 'none'"
fi

# ── Results ──────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
exit "$FAIL"
