#!/usr/bin/env bash
# =============================================================================
# test_save_orchestration_state.sh — Milestone 93
#
# Tests _save_orchestration_state() end-to-end:
#   - resume_flags uses _RESUME_NEW_START_AT (not hardcoded START_AT)
#   - Notes field is augmented with restoration info when an artifact is restored
#   - MILESTONE_MODE=true adds --milestone to resume_flags
#   - No "| Restored" in Notes when no restoration occurred
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/state.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/orchestrate_aux.sh"

# Stub out finalize_run — not under test here, just a prerequisite call
finalize_run() { return 0; }
export -f finalize_run

# Stub suggest_recovery — only called when AGENT_ERROR_CATEGORY is set
suggest_recovery() { echo "Check run log."; }
export -f suggest_recovery

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $name — expected '${expected}', got '${actual}'"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: $name — expected to contain '${needle}', got: ${haystack}"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "FAIL: $name — expected NOT to contain '${needle}', got: ${haystack}"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

# Extract the value of a "## Section" from a pipeline state file via the
# m03 wedge shim. Section names are mapped to JSON keys.
extract_state_field() {
    local file="$1" section="$2" key
    case "$section" in
        "Resume Command") key="resume_flag" ;;
        "Notes")          key="notes" ;;
        "Exit Stage")     key="exit_stage" ;;
        "Exit Reason")    key="exit_reason" ;;
        "Task")           key="resume_task" ;;
        "Milestone")      key="milestone_id" ;;
        *)                key="${section,,}"; key="${key// /_}" ;;
    esac
    read_pipeline_state_field "$file" "$key"
}

# --- Shared environment -------------------------------------------------------
# Set globals that _save_orchestration_state reads directly (no :- defaults)
_ORCH_START_TIME=$(date +%s)
_ORCH_ATTEMPT=1
_ORCH_AGENT_CALLS=5
export _ORCH_START_TIME _ORCH_ATTEMPT _ORCH_AGENT_CALLS

TASK="Test task for orchestration state"
PIPELINE_STATE_FILE="${TMPDIR}/PIPELINE_STATE.md"
MILESTONE_MODE=false
MAX_PIPELINE_ATTEMPTS=5
START_AT="coder"
export TASK PIPELINE_STATE_FILE MILESTONE_MODE MAX_PIPELINE_ATTEMPTS START_AT

# Set required file path vars — all non-existent so write_pipeline_state logs "(missing)"
CODER_SUMMARY_FILE="${TMPDIR}/CODER_SUMMARY.md"
REVIEWER_REPORT_FILE="${TMPDIR}/REVIEWER_REPORT.md"
TESTER_REPORT_FILE="${TMPDIR}/TESTER_REPORT.md"
JR_CODER_SUMMARY_FILE="${TMPDIR}/JR_CODER_SUMMARY.md"
PREFLIGHT_ERRORS_FILE="${TMPDIR}/PREFLIGHT_ERRORS.md"
TDD_PREFLIGHT_FILE="${TMPDIR}/TESTER_PREFLIGHT.md"
export CODER_SUMMARY_FILE REVIEWER_REPORT_FILE TESTER_REPORT_FILE
export JR_CODER_SUMMARY_FILE PREFLIGHT_ERRORS_FILE TDD_PREFLIGHT_FILE

_reset_state() {
    rm -f "$REVIEWER_REPORT_FILE" "$TESTER_REPORT_FILE" "$PIPELINE_STATE_FILE"
    rm -f "${TMPDIR}/archive_"*.md 2>/dev/null || true
    _ARCHIVED_REVIEWER_REPORT_PATH=""
    _ARCHIVED_TESTER_REPORT_PATH=""
    _RESUME_NEW_START_AT=""
    _RESUME_RESTORED_ARTIFACT=""
    MILESTONE_MODE=false
    START_AT="coder"
    export _ARCHIVED_REVIEWER_REPORT_PATH _ARCHIVED_TESTER_REPORT_PATH
    export MILESTONE_MODE START_AT
}

# =============================================================================
# Scenario A: No artifacts → resume_flags uses fallback START_AT
# =============================================================================
_reset_state
START_AT="coder"
export START_AT

_save_orchestration_state "max_attempts" "loop exhausted" >/dev/null 2>&1

resume_cmd=$(extract_state_field "$PIPELINE_STATE_FILE" "Resume Command")
assert_contains "A.1 no artifacts: resume_flags contains --start-at coder" \
    "--start-at coder" "$resume_cmd"

notes=$(extract_state_field "$PIPELINE_STATE_FILE" "Notes")
assert_not_contains "A.2 no artifacts: Notes has no Restored line" \
    "| Restored" "$notes"

# =============================================================================
# Scenario B: In-run REVIEWER_REPORT exists → resume skips to test stage
# =============================================================================
_reset_state
echo "reviewer content" > "$REVIEWER_REPORT_FILE"

_save_orchestration_state "timeout" "wall-clock limit" >/dev/null 2>&1

resume_cmd=$(extract_state_field "$PIPELINE_STATE_FILE" "Resume Command")
assert_contains "B.1 in-run reviewer: resume_flags contains --start-at test" \
    "--start-at test" "$resume_cmd"

notes=$(extract_state_field "$PIPELINE_STATE_FILE" "Notes")
assert_not_contains "B.2 in-run reviewer: Notes has no Restored line" \
    "| Restored" "$notes"

# =============================================================================
# Scenario C: Archived reviewer restored → Notes augmented with restoration info
# =============================================================================
_reset_state
ARCHIVED_REVIEWER="${TMPDIR}/archive_reviewer.md"
echo "archived reviewer content" > "$ARCHIVED_REVIEWER"
_ARCHIVED_REVIEWER_REPORT_PATH="$ARCHIVED_REVIEWER"
export _ARCHIVED_REVIEWER_REPORT_PATH

_save_orchestration_state "agent_cap" "agent call limit" >/dev/null 2>&1

resume_cmd=$(extract_state_field "$PIPELINE_STATE_FILE" "Resume Command")
assert_contains "C.1 archived reviewer: resume_flags contains --start-at test" \
    "--start-at test" "$resume_cmd"

notes=$(extract_state_field "$PIPELINE_STATE_FILE" "Notes")
assert_contains "C.2 archived reviewer: Notes contains '| Restored'" \
    "| Restored" "$notes"
assert_contains "C.3 archived reviewer: Notes contains REVIEWER_REPORT.md" \
    "REVIEWER_REPORT.md" "$notes"
assert_contains "C.4 archived reviewer: Notes contains archive path" \
    "$ARCHIVED_REVIEWER" "$notes"

# =============================================================================
# Scenario D: MILESTONE_MODE=true → resume_flags includes --milestone
# =============================================================================
_reset_state
MILESTONE_MODE=true
export MILESTONE_MODE
echo "reviewer content" > "$REVIEWER_REPORT_FILE"

_save_orchestration_state "stuck" "no progress" >/dev/null 2>&1

resume_cmd=$(extract_state_field "$PIPELINE_STATE_FILE" "Resume Command")
assert_contains "D.1 milestone mode: resume_flags contains --milestone" \
    "--milestone" "$resume_cmd"
assert_contains "D.2 milestone mode: resume_flags still picks smart start-at test" \
    "--start-at test" "$resume_cmd"

# =============================================================================
# Scenario E: Archived tester (no reviewer) → resume at tester, Notes augmented
# =============================================================================
_reset_state
ARCHIVED_TESTER="${TMPDIR}/archive_tester.md"
echo "archived tester content" > "$ARCHIVED_TESTER"
_ARCHIVED_TESTER_REPORT_PATH="$ARCHIVED_TESTER"
export _ARCHIVED_TESTER_REPORT_PATH

_save_orchestration_state "review_exhausted" "max review cycles" >/dev/null 2>&1

resume_cmd=$(extract_state_field "$PIPELINE_STATE_FILE" "Resume Command")
assert_contains "E.1 archived tester: resume_flags contains --start-at tester" \
    "--start-at tester" "$resume_cmd"

notes=$(extract_state_field "$PIPELINE_STATE_FILE" "Notes")
assert_contains "E.2 archived tester: Notes contains '| Restored'" \
    "| Restored" "$notes"
assert_contains "E.3 archived tester: Notes contains TESTER_REPORT.md" \
    "TESTER_REPORT.md" "$notes"

# =============================================================================
echo
if [ "$FAIL" -ne 0 ]; then
    echo "test_save_orchestration_state: FAILED"
    exit 1
fi
echo "test_save_orchestration_state: PASSED"
