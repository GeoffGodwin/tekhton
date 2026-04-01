#!/usr/bin/env bash
# =============================================================================
# test_finalize_run.sh — finalize_run() hook registry and orchestrator tests
#
# Tests:
# - Hook registration order (12 hooks in deterministic sequence, plus M13+M17+M19 hooks)
# - register_finalize_hook appends in order
# - finalize_run calls all hooks in registration order
# - finalize_run passes pipeline_exit_code to each hook
# - A failing hook logs a warning but does not abort the sequence
# - finalize_run initializes shared state variables
# - Success-only hooks (_hook_cleanup_resolved, _hook_resolve_notes,
#   _hook_mark_done, _hook_commit, _hook_archive_milestone, _hook_clear_state)
#   skip when exit_code != 0
# - Always-run hooks (_hook_drift_artifacts, _hook_record_metrics,
#   _hook_archive_reports) run regardless of exit_code
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals expected by finalize.sh --------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/logs"
TIMESTAMP="20260319_120000"
LOG_FILE="$TMPDIR/test.log"
TASK="Test task for finalize_run"
MILESTONE_MODE=false
AUTO_COMMIT=false
_CURRENT_MILESTONE=""
TEKHTON_SESSION_DIR="$TMPDIR"
START_AT="N/A"
VERDICT="APPROVED"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
DRIFT_LOG_FILE="DRIFT_LOG.md"
_TEKHTON_LOCK_FILE=""
WITH_NOTES=false
HUMAN_MODE=false
NOTES_FILTER=""
HUMAN_NOTES_TAG=""
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false

# Stage tracking arrays (M34)
declare -A _STAGE_TURNS=()
declare -A _STAGE_DURATION=()
declare -A _STAGE_BUDGET=()
declare -A _STAGE_STATUS=()

# Orchestrator counters used by _hook_emit_run_summary
_ORCH_ATTEMPT=1
_ORCH_AGENT_CALLS=0
_ORCH_ELAPSED=0
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_REVIEW_BUMPED=false
AUTONOMOUS_TIMEOUT=7200
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
CONTINUATION_ATTEMPTS=0
LAST_AGENT_RETRY_COUNT=0
REVIEW_CYCLE=0
MILESTONE_CURRENT_SPLIT_DEPTH=0

export PROJECT_DIR LOG_DIR TIMESTAMP LOG_FILE TASK MILESTONE_MODE AUTO_COMMIT
export _CURRENT_MILESTONE TEKHTON_SESSION_DIR START_AT VERDICT
export HUMAN_ACTION_FILE NON_BLOCKING_LOG_FILE DRIFT_LOG_FILE _TEKHTON_LOCK_FILE
export WITH_NOTES HUMAN_MODE NOTES_FILTER

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
cd "$TMPDIR"

# --- Source common.sh for log/warn/success/header ----------------------------
source "${TEKHTON_HOME}/lib/common.sh"

# --- Mock all external dependencies that finalize.sh hooks call --------------

# Tracking arrays for mock invocations
declare -A _mock_called=()

_reset_mocks() {
    _mock_called=()
}

run_note_acceptance() {
    _mock_called[run_note_acceptance]=1
    return 0
}
run_final_checks() {
    _mock_called[run_final_checks]=1
    return 0
}
process_drift_artifacts() {
    _mock_called[process_drift_artifacts]=1
    return 0
}
record_run_metrics() {
    _mock_called[record_run_metrics]=1
    return 0
}
clear_resolved_nonblocking_notes() {
    _mock_called[clear_resolved_nonblocking_notes]=1
    return 0
}
resolve_human_notes() {
    _mock_called[resolve_human_notes]=1
    return 0
}
resolve_single_note() {
    _mock_called[resolve_single_note]=1
    _mock_resolve_single_note_line="${1:-}"
    _mock_resolve_single_exit_code="${2:-}"
    return 0
}
resolve_note() {
    _mock_called[resolve_note]=1
    _mock_resolve_note_id="${1:-}"
    _mock_resolve_note_outcome="${2:-}"
    return 0
}
resolve_notes_batch() {
    _mock_called[resolve_notes_batch]=1
    _mock_resolve_batch_ids="${1:-}"
    _mock_resolve_batch_exit="${2:-}"
    return 0
}
# M40: stub CLAIMED_NOTE_IDS (set during claiming, read by resolve hooks)
CLAIMED_NOTE_IDS=""
archive_reports() {
    _mock_called[archive_reports]=1
    return 0
}
mark_milestone_done() {
    _mock_called[mark_milestone_done]=1
    return 0
}
get_milestone_disposition() {
    echo "${_MOCK_DISPOSITION:-PARTIAL}"
}
generate_commit_message() {
    _mock_called[generate_commit_message]=1
    echo "feat: test commit"
}
archive_completed_milestone() {
    _mock_called[archive_completed_milestone]=1
    return 0
}
tag_milestone_complete() {
    _mock_called[tag_milestone_complete]=1
    return 0
}
clear_milestone_state() {
    _mock_called[clear_milestone_state]=1
    return 0
}
print_run_summary() {
    _mock_called[print_run_summary]=1
    return 0
}
_check_gitignore_safety() {
    _mock_called[_check_gitignore_safety]=1
    return 0
}
write_last_failure_context() {
    _mock_called[write_last_failure_context]=1
    return 0
}
_read_diagnostic_context() {
    _mock_called[_read_diagnostic_context]=1
    return 0
}
classify_failure_diag() {
    _mock_called[classify_failure_diag]=1
    DIAG_CLASSIFICATION="UNKNOWN"
    return 0
}
emit_dashboard_diagnosis() {
    _mock_called[emit_dashboard_diagnosis]=1
    return 0
}
check_for_updates() {
    _mock_called[check_for_updates]=1
    return 1
}
DIAG_CLASSIFICATION=""
EXPRESS_MODE_ACTIVE=false
EXPRESS_PERSIST_CONFIG=true
EXPRESS_PERSIST_ROLES=false
persist_express_config() {
    _mock_called[persist_express_config]=1
    return 0
}
persist_express_roles() {
    _mock_called[persist_express_roles]=1
    return 0
}
has_human_actions() {
    return 1
}
count_human_actions() {
    echo "0"
}
count_drift_observations() {
    echo "0"
}
count_open_nonblocking_notes() {
    echo "0"
}

# --- Source finalize.sh (registers hooks at source-time) ---------------------
source "${TEKHTON_HOME}/lib/finalize.sh"

# Save original hooks for restoration between test groups
ORIGINAL_FINALIZE_HOOKS=("${FINALIZE_HOOKS[@]}")

# --- Test helpers ------------------------------------------------------------
PASS=0
FAIL=0

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

restore_hooks() {
    FINALIZE_HOOKS=("${ORIGINAL_FINALIZE_HOOKS[@]}")
}

# =============================================================================
# Test Suite 1: Hook registration order
# =============================================================================
echo "=== Test Suite 1: Hook registration order ==="

assert_eq "1.1 exactly 18 hooks registered" "18" "${#FINALIZE_HOOKS[@]}"
assert_eq "1.1b first hook is _hook_note_acceptance"  "_hook_note_acceptance" "${FINALIZE_HOOKS[0]}"
assert_eq "1.2 second hook is _hook_final_checks"    "_hook_final_checks"    "${FINALIZE_HOOKS[1]}"
assert_eq "1.3 third hook is _hook_drift_artifacts" "_hook_drift_artifacts" "${FINALIZE_HOOKS[2]}"
assert_eq "1.4 fourth hook is _hook_record_metrics"   "_hook_record_metrics"  "${FINALIZE_HOOKS[3]}"
assert_eq "1.4b fifth hook is _hook_causal_log_finalize" "_hook_causal_log_finalize" "${FINALIZE_HOOKS[4]}"
assert_eq "1.5 sixth hook is _hook_cleanup_resolved" "_hook_cleanup_resolved" "${FINALIZE_HOOKS[5]}"
assert_eq "1.6 seventh hook is _hook_resolve_notes"    "_hook_resolve_notes"   "${FINALIZE_HOOKS[6]}"
assert_eq "1.7 eighth hook is _hook_archive_reports"  "_hook_archive_reports" "${FINALIZE_HOOKS[7]}"
assert_eq "1.8 ninth hook is _hook_mark_done"      "_hook_mark_done"       "${FINALIZE_HOOKS[8]}"
assert_eq "1.9 tenth hook is _hook_archive_milestone" "_hook_archive_milestone" "${FINALIZE_HOOKS[9]}"
assert_eq "1.10 eleventh hook is _hook_clear_state"     "_hook_clear_state"     "${FINALIZE_HOOKS[10]}"
assert_eq "1.10b twelfth hook is _hook_health_reassess" "_hook_health_reassess" "${FINALIZE_HOOKS[11]}"
assert_eq "1.11 thirteenth hook is _hook_emit_run_summary" "_hook_emit_run_summary" "${FINALIZE_HOOKS[12]}"
assert_eq "1.12 fourteenth hook is _hook_failure_context" "_hook_failure_context" "${FINALIZE_HOOKS[13]}"
assert_eq "1.12b fifteenth hook is _hook_express_persist" "_hook_express_persist" "${FINALIZE_HOOKS[14]}"
assert_eq "1.13 sixteenth hook is _hook_commit"    "_hook_commit"          "${FINALIZE_HOOKS[15]}"
assert_eq "1.14 seventeenth hook is _hook_update_check" "_hook_update_check"  "${FINALIZE_HOOKS[16]}"
assert_eq "1.15 eighteenth hook is _hook_final_dashboard_status" "_hook_final_dashboard_status" "${FINALIZE_HOOKS[17]}"

# =============================================================================
# Test Suite 2: register_finalize_hook appends in order
# =============================================================================
echo "=== Test Suite 2: register_finalize_hook ==="

_test_new_hook() { return 0; }
register_finalize_hook "_test_new_hook"
assert_eq "2.1 hook count increases by 1" "19" "${#FINALIZE_HOOKS[@]}"
assert_eq "2.2 new hook appended at end"  "_test_new_hook" "${FINALIZE_HOOKS[18]}"

# Register a second additional hook — ensure ordering is preserved
_test_new_hook_2() { return 0; }
register_finalize_hook "_test_new_hook_2"
assert_eq "2.3 second new hook appended"  "_test_new_hook_2" "${FINALIZE_HOOKS[19]}"
assert_eq "2.4 first new hook still at 18" "_test_new_hook" "${FINALIZE_HOOKS[18]}"

restore_hooks

# =============================================================================
# Test Suite 3: finalize_run calls all hooks in order
# =============================================================================
echo "=== Test Suite 3: finalize_run calls all hooks in order ==="

_call_sequence=()

_seq_hook_a() { _call_sequence+=("a"); }
_seq_hook_b() { _call_sequence+=("b"); }
_seq_hook_c() { _call_sequence+=("c"); }

FINALIZE_HOOKS=(_seq_hook_a _seq_hook_b _seq_hook_c)
_call_sequence=()
finalize_run 0

assert_eq "3.1 first hook called first"  "a" "${_call_sequence[0]}"
assert_eq "3.2 second hook called second" "b" "${_call_sequence[1]}"
assert_eq "3.3 third hook called third"   "c" "${_call_sequence[2]}"
assert_eq "3.4 all 3 hooks called"        "3" "${#_call_sequence[@]}"

restore_hooks

# =============================================================================
# Test Suite 4: finalize_run passes exit code to each hook
# =============================================================================
echo "=== Test Suite 4: exit code is passed to hooks ==="

_received_exit_codes=()
_capture_exit_code_hook() {
    _received_exit_codes+=("$1")
}

FINALIZE_HOOKS=(_capture_exit_code_hook _capture_exit_code_hook)
_received_exit_codes=()
finalize_run 42

assert_eq "4.1 first hook receives exit code 42" "42" "${_received_exit_codes[0]}"
assert_eq "4.2 second hook receives exit code 42" "42" "${_received_exit_codes[1]}"

_received_exit_codes=()
finalize_run 0

assert_eq "4.3 hooks receive exit code 0" "0" "${_received_exit_codes[0]}"

restore_hooks

# =============================================================================
# Test Suite 5: A failing hook does not abort the sequence
# =============================================================================
echo "=== Test Suite 5: failing hook does not abort sequence ==="

_after_fail_called=false

_always_fail_hook() { return 1; }
_after_fail_hook()  { _after_fail_called=true; }

FINALIZE_HOOKS=(_always_fail_hook _after_fail_hook)
_after_fail_called=false
finalize_run 0  # should NOT exit with error despite hook failure

assert "5.1 hook after failing hook still ran" \
    "$([ "$_after_fail_called" = true ] && echo 0 || echo 1)"

# Multiple failures in sequence — all remaining hooks still run
_seq2=()
_fail1() { return 1; }
_ok1()   { _seq2+=("ok1"); }
_fail2() { return 1; }
_ok2()   { _seq2+=("ok2"); }

FINALIZE_HOOKS=(_fail1 _ok1 _fail2 _ok2)
_seq2=()
finalize_run 0

assert_eq "5.2 first ok hook ran despite failure before it"  "ok1" "${_seq2[0]}"
assert_eq "5.3 second ok hook ran despite two failures"      "ok2" "${_seq2[1]}"
assert_eq "5.4 both ok hooks ran (2 total)"                  "2"   "${#_seq2[@]}"

restore_hooks

# =============================================================================
# Test Suite 6: finalize_run initializes shared state variables
# =============================================================================
echo "=== Test Suite 6: shared state initialization ==="

# Set known values before finalize_run to confirm they are reset
FINAL_CHECK_RESULT=99
_COMMIT_SUCCEEDED=true

FINALIZE_HOOKS=()  # no-op — just test initialization
finalize_run 0

assert_eq "6.1 FINAL_CHECK_RESULT initialized to 0"    "0"     "$FINAL_CHECK_RESULT"
assert_eq "6.2 _COMMIT_SUCCEEDED initialized to false" "false" "$_COMMIT_SUCCEEDED"

restore_hooks

# =============================================================================
# Test Suite 7: _hook_cleanup_resolved — success-only guard
# =============================================================================
echo "=== Test Suite 7: _hook_cleanup_resolved exit-code guard ==="

_reset_mocks

# On failure: clear_resolved_nonblocking_notes should NOT be called
_hook_cleanup_resolved 1
assert "7.1 cleanup_resolved skips on exit_code=1" \
    "$([ -z "${_mock_called[clear_resolved_nonblocking_notes]:-}" ] && echo 0 || echo 1)"

# On success: clear_resolved_nonblocking_notes should be called
_reset_mocks
_hook_cleanup_resolved 0
assert "7.2 cleanup_resolved calls function on exit_code=0" \
    "$([ -n "${_mock_called[clear_resolved_nonblocking_notes]:-}" ] && echo 0 || echo 1)"

# =============================================================================
# Test Suite 8: _hook_resolve_notes — success-only guard
# =============================================================================
echo "=== Test Suite 8: _hook_resolve_notes exit-code guard ==="

_reset_mocks

# On failure with [~] items: orphan safety net resets [~] → [ ]
cat > "${TMPDIR}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] Fix the thing
EOF
_hook_resolve_notes 1
assert "8.1 orphaned [~] reset to [ ] on failure" \
    "$(grep -qc '^\- \[ \]' "${TMPDIR}/HUMAN_NOTES.md" && echo 0 || echo 1)"

# On success with no HUMAN_NOTES.md: early return without error
_reset_mocks
rm -f "${TMPDIR}/HUMAN_NOTES.md"
set +e; _hook_resolve_notes 0; _rc=$?; set -e
assert "8.2 resolve_notes returns cleanly when no HUMAN_NOTES.md" \
    "$([[ $_rc -eq 0 ]] && echo 0 || echo 1)"

# On success with HUMAN_NOTES.md containing [~] items: orphan safety net resolves [~] → [x]
_reset_mocks
cat > "${TMPDIR}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] Fix the thing
EOF
_hook_resolve_notes 0
assert "8.3 orphaned [~] resolved to [x] on success" \
    "$(grep -qc '^\- \[x\]' "${TMPDIR}/HUMAN_NOTES.md" && echo 0 || echo 1)"

# On success with HUMAN_NOTES.md but no [~] items: file unchanged
_reset_mocks
cat > "${TMPDIR}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [ ] Fix the thing
- [x] Done item
EOF
_before_84=$(cat "${TMPDIR}/HUMAN_NOTES.md")
_hook_resolve_notes 0
_after_84=$(cat "${TMPDIR}/HUMAN_NOTES.md")
assert_eq "8.4 no [~] items leaves file unchanged" "$_before_84" "$_after_84"

rm -f "${TMPDIR}/HUMAN_NOTES.md"

# =============================================================================
# Test Suite 8b: _hook_resolve_notes — unified path (HUMAN_MODE branch removed)
# =============================================================================
# M42 removed the separate HUMAN_MODE branch inside _hook_resolve_notes in favour
# of a single CLAIMED_NOTE_IDS-based path. The following former assertions were
# retired and their behavioural guarantees are now covered by Suite 8b:
#
#   Former assertion (pre-M42)             → Covered by Suite 8b case
#   ─────────────────────────────────────────────────────────────────
#   "HUMAN_MODE=true skips resolve_note"   → 8b.1: batch called with CLAIMED IDs
#   "HUMAN_MODE=true calls resolve_notes_  → 8b.2: batch receives correct IDs
#    batch with correct IDs"
#   "HUMAN_MODE=true passes exit code"     → 8b.3: batch receives exit code 0
#                                            8b.8: batch receives exit code 1
#   "HUMAN_MODE=false does not call batch" → 8b.6: HUMAN_MODE=false uses same path
#
# Net change: −4 former assertions, +8 Suite 8b assertions covering equivalent
# (and broader) behavioural surface: both HUMAN_MODE values, empty vs non-empty
# CLAIMED_NOTE_IDS, and success vs failure exit codes.
# =============================================================================
echo "=== Test Suite 8b: _hook_resolve_notes unified path (no HUMAN_MODE branch) ==="

# HUMAN_MODE + CLAIMED_NOTE_IDS: uses bulk resolution (unified path)
_reset_mocks
HUMAN_MODE=true
CURRENT_NOTE_ID="n01"
CURRENT_NOTE_LINE=""
CLAIMED_NOTE_IDS="n01"
export HUMAN_MODE CURRENT_NOTE_ID CURRENT_NOTE_LINE CLAIMED_NOTE_IDS
cat > "${TMPDIR}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] [BUG] Fix the thing <!-- note:n01 created:2026-03-28 priority:medium source:cli -->
EOF
_hook_resolve_notes 0
assert "8b.1 resolve_notes_batch called with CLAIMED_NOTE_IDS" \
    "$([ -n "${_mock_called[resolve_notes_batch]:-}" ] && echo 0 || echo 1)"
assert_eq "8b.2 batch receives claimed IDs" \
    "n01" "${_mock_resolve_batch_ids:-}"
assert_eq "8b.3 batch receives exit code 0" \
    "0" "${_mock_resolve_batch_exit:-}"

# HUMAN_MODE + empty CLAIMED_NOTE_IDS: orphan safety net resolves [~] → [x]
_reset_mocks
HUMAN_MODE=true
CURRENT_NOTE_ID=""
CURRENT_NOTE_LINE=""
CLAIMED_NOTE_IDS=""
export HUMAN_MODE CURRENT_NOTE_ID CURRENT_NOTE_LINE CLAIMED_NOTE_IDS
cat > "${TMPDIR}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] [BUG] Fix the thing
EOF
_hook_resolve_notes 0
assert "8b.4 resolve_notes_batch NOT called when CLAIMED_NOTE_IDS empty" \
    "$([ -z "${_mock_called[resolve_notes_batch]:-}" ] && echo 0 || echo 1)"
# M42: resolve_human_notes fallback removed — orphan safety net resolves directly
assert "8b.5 orphaned [~] note resolved to [x] by safety net" \
    "$(grep -qc '^\- \[x\]' "${TMPDIR}/HUMAN_NOTES.md" && echo 0 || echo 1)"

# HUMAN_MODE=false + CLAIMED_NOTE_IDS: same unified path
_reset_mocks
HUMAN_MODE=false
CURRENT_NOTE_ID="n01"
CURRENT_NOTE_LINE=""
CLAIMED_NOTE_IDS="n01"
export HUMAN_MODE CURRENT_NOTE_ID CURRENT_NOTE_LINE CLAIMED_NOTE_IDS
cat > "${TMPDIR}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] [BUG] Fix the thing
EOF
_hook_resolve_notes 0
assert "8b.6 resolve_notes_batch called when HUMAN_MODE=false" \
    "$([ -n "${_mock_called[resolve_notes_batch]:-}" ] && echo 0 || echo 1)"

# Failure path: resolve_notes_batch receives non-zero exit code
_reset_mocks
HUMAN_MODE=true
CURRENT_NOTE_ID="n01"
CURRENT_NOTE_LINE=""
CLAIMED_NOTE_IDS="n01"
export HUMAN_MODE CURRENT_NOTE_ID CURRENT_NOTE_LINE CLAIMED_NOTE_IDS
cat > "${TMPDIR}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] [BUG] Fix the thing <!-- note:n01 created:2026-03-28 priority:medium source:cli -->
EOF
_hook_resolve_notes 1
assert "8b.7 resolve_notes_batch called on failure" \
    "$([ -n "${_mock_called[resolve_notes_batch]:-}" ] && echo 0 || echo 1)"
assert_eq "8b.8 batch receives exit code 1 on failure" \
    "1" "${_mock_resolve_batch_exit:-}"

# Reset HUMAN_MODE state
HUMAN_MODE=false
CURRENT_NOTE_ID=""
CURRENT_NOTE_LINE=""
CLAIMED_NOTE_IDS=""
export HUMAN_MODE CURRENT_NOTE_ID CURRENT_NOTE_LINE CLAIMED_NOTE_IDS
rm -f "${TMPDIR}/HUMAN_NOTES.md"

# =============================================================================
# Test Suite 9: _hook_mark_done — success-only, milestone-mode guard
# =============================================================================
echo "=== Test Suite 9: _hook_mark_done guards ==="

_reset_mocks

# On failure: mark_milestone_done should NOT be called
MILESTONE_MODE=true
_CURRENT_MILESTONE="15"
_MOCK_DISPOSITION="COMPLETE_AND_CONTINUE"
_hook_mark_done 1
assert "9.1 mark_done skips on exit_code=1" \
    "$([ -z "${_mock_called[mark_milestone_done]:-}" ] && echo 0 || echo 1)"

# In non-milestone mode: mark_milestone_done should NOT be called
_reset_mocks
MILESTONE_MODE=false
_hook_mark_done 0
assert "9.2 mark_done skips when not in milestone mode" \
    "$([ -z "${_mock_called[mark_milestone_done]:-}" ] && echo 0 || echo 1)"

# With empty _CURRENT_MILESTONE: should NOT be called
_reset_mocks
MILESTONE_MODE=true
_CURRENT_MILESTONE=""
_hook_mark_done 0
assert "9.3 mark_done skips when _CURRENT_MILESTONE is empty" \
    "$([ -z "${_mock_called[mark_milestone_done]:-}" ] && echo 0 || echo 1)"

# Success + milestone mode + milestone set + COMPLETE disposition: should call
_reset_mocks
MILESTONE_MODE=true
_CURRENT_MILESTONE="15"
_MOCK_DISPOSITION="COMPLETE_AND_CONTINUE"
_hook_mark_done 0
assert "9.4 mark_done called on success with COMPLETE_AND_CONTINUE disposition" \
    "$([ -n "${_mock_called[mark_milestone_done]:-}" ] && echo 0 || echo 1)"

# COMPLETE_AND_WAIT disposition: should also call
_reset_mocks
_MOCK_DISPOSITION="COMPLETE_AND_WAIT"
_hook_mark_done 0
assert "9.5 mark_done called with COMPLETE_AND_WAIT disposition" \
    "$([ -n "${_mock_called[mark_milestone_done]:-}" ] && echo 0 || echo 1)"

# PARTIAL disposition: should NOT call mark_milestone_done
_reset_mocks
_MOCK_DISPOSITION="PARTIAL"
_hook_mark_done 0
assert "9.6 mark_done skips on PARTIAL disposition" \
    "$([ -z "${_mock_called[mark_milestone_done]:-}" ] && echo 0 || echo 1)"

# Reset milestone mode
MILESTONE_MODE=false
_CURRENT_MILESTONE=""
_MOCK_DISPOSITION=""

# =============================================================================
# Test Suite 10: _hook_commit — success-only guard
# =============================================================================
echo "=== Test Suite 10: _hook_commit exit-code guard ==="

_reset_mocks

# On failure: generate_commit_message should NOT be called
AUTO_COMMIT=false
_hook_commit 1
assert "10.1 commit hook skips on exit_code=1" \
    "$([ -z "${_mock_called[generate_commit_message]:-}" ] && echo 0 || echo 1)"

# On failure even with FINAL_CHECK_RESULT=0
_reset_mocks
FINAL_CHECK_RESULT=0
_hook_commit 1
assert "10.2 commit hook skips on exit_code=1 regardless of FINAL_CHECK_RESULT" \
    "$([ -z "${_mock_called[generate_commit_message]:-}" ] && echo 0 || echo 1)"

# On success but FINAL_CHECK_RESULT!=0: commit hook skips
_reset_mocks
FINAL_CHECK_RESULT=1
_hook_commit 0
assert "10.3 commit hook skips when FINAL_CHECK_RESULT!=0" \
    "$([ -z "${_mock_called[generate_commit_message]:-}" ] && echo 0 || echo 1)"

FINAL_CHECK_RESULT=0

# =============================================================================
# Test Suite 11: _hook_archive_milestone — guards
# =============================================================================
echo "=== Test Suite 11: _hook_archive_milestone guards ==="

_reset_mocks

# On failure
MILESTONE_MODE=true
_CURRENT_MILESTONE="15"
_COMMIT_SUCCEEDED=true
_MOCK_DISPOSITION="COMPLETE_AND_CONTINUE"
_hook_archive_milestone 1
assert "11.1 archive_milestone skips on exit_code=1" \
    "$([ -z "${_mock_called[archive_completed_milestone]:-}" ] && echo 0 || echo 1)"

# Not milestone mode
_reset_mocks
MILESTONE_MODE=false
_hook_archive_milestone 0
assert "11.2 archive_milestone skips when not in milestone mode" \
    "$([ -z "${_mock_called[archive_completed_milestone]:-}" ] && echo 0 || echo 1)"

# No current milestone
_reset_mocks
MILESTONE_MODE=true
_CURRENT_MILESTONE=""
_hook_archive_milestone 0
assert "11.3 archive_milestone skips when _CURRENT_MILESTONE is empty" \
    "$([ -z "${_mock_called[archive_completed_milestone]:-}" ] && echo 0 || echo 1)"

# All conditions met with COMPLETE disposition (commit no longer gates archive_milestone)
_reset_mocks
MILESTONE_MODE=true
_CURRENT_MILESTONE="15"
_MOCK_DISPOSITION="COMPLETE_AND_CONTINUE"
_hook_archive_milestone 0
assert "11.4 archive_milestone called when all conditions met" \
    "$([ -n "${_mock_called[archive_completed_milestone]:-}" ] && echo 0 || echo 1)"

# PARTIAL disposition — should skip
_reset_mocks
_MOCK_DISPOSITION="PARTIAL"
_hook_archive_milestone 0
assert "11.5 archive_milestone skips on PARTIAL disposition" \
    "$([ -z "${_mock_called[archive_completed_milestone]:-}" ] && echo 0 || echo 1)"

MILESTONE_MODE=false
_CURRENT_MILESTONE=""
_COMMIT_SUCCEEDED=false
_MOCK_DISPOSITION=""

# =============================================================================
# Test Suite 12: _hook_clear_state — guards
# =============================================================================
echo "=== Test Suite 12: _hook_clear_state guards ==="

_reset_mocks

# On failure
MILESTONE_MODE=true
_CURRENT_MILESTONE="15"
_COMMIT_SUCCEEDED=true
_MOCK_DISPOSITION="COMPLETE_AND_CONTINUE"
_hook_clear_state 1
assert "12.1 clear_state skips on exit_code=1" \
    "$([ -z "${_mock_called[clear_milestone_state]:-}" ] && echo 0 || echo 1)"

# Not milestone mode
_reset_mocks
MILESTONE_MODE=false
_hook_clear_state 0
assert "12.2 clear_state skips when not in milestone mode" \
    "$([ -z "${_mock_called[clear_milestone_state]:-}" ] && echo 0 || echo 1)"

# All conditions met with COMPLETE disposition (commit no longer gates clear_state)
_reset_mocks
MILESTONE_MODE=true
_CURRENT_MILESTONE="15"
_MOCK_DISPOSITION="COMPLETE_AND_CONTINUE"
_hook_clear_state 0
assert "12.3 clear_state called when all conditions met" \
    "$([ -n "${_mock_called[clear_milestone_state]:-}" ] && echo 0 || echo 1)"

# PARTIAL disposition — should skip
_reset_mocks
_MOCK_DISPOSITION="PARTIAL"
_hook_clear_state 0
assert "12.4 clear_state skips on PARTIAL disposition" \
    "$([ -z "${_mock_called[clear_milestone_state]:-}" ] && echo 0 || echo 1)"

MILESTONE_MODE=false
_CURRENT_MILESTONE=""
_COMMIT_SUCCEEDED=false
_MOCK_DISPOSITION=""

# =============================================================================
# Test Suite 13: Always-run hooks (_hook_drift_artifacts, _hook_record_metrics,
#                _hook_archive_reports) run on failure too
# =============================================================================
echo "=== Test Suite 13: always-run hooks run on failure ==="

_reset_mocks
_hook_drift_artifacts 1
assert "13.1 drift_artifacts runs on exit_code=1" \
    "$([ -n "${_mock_called[process_drift_artifacts]:-}" ] && echo 0 || echo 1)"

_reset_mocks
_hook_record_metrics 1
assert "13.2 record_metrics runs on exit_code=1" \
    "$([ -n "${_mock_called[record_run_metrics]:-}" ] && echo 0 || echo 1)"

_reset_mocks
_hook_archive_reports 1
assert "13.3 archive_reports runs on exit_code=1" \
    "$([ -n "${_mock_called[archive_reports]:-}" ] && echo 0 || echo 1)"

_reset_mocks
_hook_drift_artifacts 0
assert "13.4 drift_artifacts runs on exit_code=0" \
    "$([ -n "${_mock_called[process_drift_artifacts]:-}" ] && echo 0 || echo 1)"

_reset_mocks
_hook_record_metrics 0
assert "13.5 record_metrics runs on exit_code=0" \
    "$([ -n "${_mock_called[record_run_metrics]:-}" ] && echo 0 || echo 1)"

_reset_mocks
_hook_archive_reports 0
assert "13.6 archive_reports runs on exit_code=0" \
    "$([ -n "${_mock_called[archive_reports]:-}" ] && echo 0 || echo 1)"

_reset_mocks
_hook_update_check 1
assert "13.7 update_check runs on exit_code=1" \
    "$([ -n "${_mock_called[check_for_updates]:-}" ] && echo 0 || echo 1)"

_reset_mocks
_hook_update_check 0
assert "13.8 update_check runs on exit_code=0" \
    "$([ -n "${_mock_called[check_for_updates]:-}" ] && echo 0 || echo 1)"

# =============================================================================
# Test Suite 14: finalize_run 0 vs finalize_run 1 through real hooks
# =============================================================================
echo "=== Test Suite 14: finalize_run 0 calls all real hooks ==="

restore_hooks

# Set up state so real hooks can execute without erroring out.
# SKIP_FINAL_CHECKS=true causes _hook_final_checks to skip run_final_checks
# and set FINAL_CHECK_RESULT=1, which prevents _hook_commit from running
# (avoiding tty reads and git operations in the test environment).
MILESTONE_MODE=false
_CURRENT_MILESTONE=""
AUTO_COMMIT=false
FINAL_CHECK_RESULT=0
_COMMIT_SUCCEEDED=false
SKIP_FINAL_CHECKS=true

_reset_mocks
finalize_run 0

# Hook a: SKIP_FINAL_CHECKS=true means run_final_checks is bypassed by the guard
assert "14.1 run_final_checks NOT called when SKIP_FINAL_CHECKS=true" \
    "$([ -z "${_mock_called[run_final_checks]:-}" ] && echo 0 || echo 1)"
# Hooks b, c always run regardless
assert "14.2 process_drift_artifacts called on success" \
    "$([ -n "${_mock_called[process_drift_artifacts]:-}" ] && echo 0 || echo 1)"
assert "14.3 record_run_metrics called on success" \
    "$([ -n "${_mock_called[record_run_metrics]:-}" ] && echo 0 || echo 1)"
# hook f always runs
assert "14.4 archive_reports called on success" \
    "$([ -n "${_mock_called[archive_reports]:-}" ] && echo 0 || echo 1)"
# hook n (update check) always runs — guards against future hook ordering changes
assert "14.6 check_for_updates called on success (finalize_run 0)" \
    "$([ -n "${_mock_called[check_for_updates]:-}" ] && echo 0 || echo 1)"

# Test _hook_final_checks directly with SKIP_FINAL_CHECKS=false
_reset_mocks
SKIP_FINAL_CHECKS=false
_hook_final_checks 0
assert "14.5 run_final_checks called when SKIP_FINAL_CHECKS=false" \
    "$([ -n "${_mock_called[run_final_checks]:-}" ] && echo 0 || echo 1)"

SKIP_FINAL_CHECKS=true  # restore safe default

echo "=== Test Suite 15: finalize_run 1 skips success-only hooks ==="

_reset_mocks
SKIP_FINAL_CHECKS=false
finalize_run 1

# Hooks a, b, c, f always run
assert "15.1 run_final_checks called on failure" \
    "$([ -n "${_mock_called[run_final_checks]:-}" ] && echo 0 || echo 1)"
assert "15.2 process_drift_artifacts called on failure" \
    "$([ -n "${_mock_called[process_drift_artifacts]:-}" ] && echo 0 || echo 1)"
assert "15.3 record_run_metrics called on failure" \
    "$([ -n "${_mock_called[record_run_metrics]:-}" ] && echo 0 || echo 1)"
assert "15.4 archive_reports called on failure" \
    "$([ -n "${_mock_called[archive_reports]:-}" ] && echo 0 || echo 1)"

# Success-only hooks d, e, g, h, i, j should NOT run
assert "15.5 clear_resolved_nonblocking_notes NOT called on failure" \
    "$([ -z "${_mock_called[clear_resolved_nonblocking_notes]:-}" ] && echo 0 || echo 1)"
# 15.6 removed: resolve_human_notes was eliminated in M42 (unified CLAIMED_NOTE_IDS
# path). The assertion was vacuously true because the function is never called by
# finalize.sh. The equivalent live guard is in Suite 8b (8b.4 + 8b.7).
assert "15.7 mark_milestone_done NOT called on failure" \
    "$([ -z "${_mock_called[mark_milestone_done]:-}" ] && echo 0 || echo 1)"
assert "15.8 generate_commit_message NOT called on failure" \
    "$([ -z "${_mock_called[generate_commit_message]:-}" ] && echo 0 || echo 1)"
assert "15.9 archive_completed_milestone NOT called on failure" \
    "$([ -z "${_mock_called[archive_completed_milestone]:-}" ] && echo 0 || echo 1)"
assert "15.10 clear_milestone_state NOT called on failure" \
    "$([ -z "${_mock_called[clear_milestone_state]:-}" ] && echo 0 || echo 1)"
# hook n (update check) always runs — guards against future hook ordering changes
assert "15.11 check_for_updates called on failure (finalize_run 1)" \
    "$([ -n "${_mock_called[check_for_updates]:-}" ] && echo 0 || echo 1)"

restore_hooks

# =============================================================================
# Test Suite 16: _hook_express_persist — behavior
# =============================================================================
echo "=== Test Suite 16: _hook_express_persist behavior ==="

# 16.1 No-op on failure: persist_express_config must NOT be called
_reset_mocks
EXPRESS_MODE_ACTIVE=true
EXPRESS_PERSIST_CONFIG=true
EXPRESS_PERSIST_ROLES=false
export EXPRESS_MODE_ACTIVE EXPRESS_PERSIST_CONFIG EXPRESS_PERSIST_ROLES
_hook_express_persist 1
assert "16.1 persist_express_config NOT called when exit_code=1" \
    "$([ -z "${_mock_called[persist_express_config]:-}" ] && echo 0 || echo 1)"
assert "16.2 persist_express_roles NOT called when exit_code=1" \
    "$([ -z "${_mock_called[persist_express_roles]:-}" ] && echo 0 || echo 1)"

# 16.3 No-op when EXPRESS_MODE_ACTIVE != "true"
_reset_mocks
EXPRESS_MODE_ACTIVE=false
EXPRESS_PERSIST_CONFIG=true
export EXPRESS_MODE_ACTIVE EXPRESS_PERSIST_CONFIG
_hook_express_persist 0
assert "16.3 persist_express_config NOT called when EXPRESS_MODE_ACTIVE=false" \
    "$([ -z "${_mock_called[persist_express_config]:-}" ] && echo 0 || echo 1)"

# 16.4 Calls persist_express_config on success with EXPRESS_MODE_ACTIVE=true
_reset_mocks
EXPRESS_MODE_ACTIVE=true
EXPRESS_PERSIST_CONFIG=true
EXPRESS_PERSIST_ROLES=false
export EXPRESS_MODE_ACTIVE EXPRESS_PERSIST_CONFIG EXPRESS_PERSIST_ROLES
_hook_express_persist 0
assert "16.4 persist_express_config called when mode active and exit_code=0" \
    "$([ -n "${_mock_called[persist_express_config]:-}" ] && echo 0 || echo 1)"

# 16.5 Does NOT call persist_express_roles when EXPRESS_PERSIST_ROLES=false
assert "16.5 persist_express_roles NOT called when EXPRESS_PERSIST_ROLES=false" \
    "$([ -z "${_mock_called[persist_express_roles]:-}" ] && echo 0 || echo 1)"

# 16.6 Calls persist_express_roles when EXPRESS_PERSIST_ROLES=true
_reset_mocks
EXPRESS_MODE_ACTIVE=true
EXPRESS_PERSIST_CONFIG=true
EXPRESS_PERSIST_ROLES=true
export EXPRESS_MODE_ACTIVE EXPRESS_PERSIST_CONFIG EXPRESS_PERSIST_ROLES
_hook_express_persist 0
assert "16.6 persist_express_config called when EXPRESS_PERSIST_ROLES=true" \
    "$([ -n "${_mock_called[persist_express_config]:-}" ] && echo 0 || echo 1)"
assert "16.7 persist_express_roles called when EXPRESS_PERSIST_ROLES=true" \
    "$([ -n "${_mock_called[persist_express_roles]:-}" ] && echo 0 || echo 1)"

# 16.8 Does NOT call persist_express_config when EXPRESS_PERSIST_CONFIG=false
_reset_mocks
EXPRESS_MODE_ACTIVE=true
EXPRESS_PERSIST_CONFIG=false
EXPRESS_PERSIST_ROLES=false
export EXPRESS_MODE_ACTIVE EXPRESS_PERSIST_CONFIG EXPRESS_PERSIST_ROLES
_hook_express_persist 0
assert "16.8 persist_express_config NOT called when EXPRESS_PERSIST_CONFIG=false" \
    "$([ -z "${_mock_called[persist_express_config]:-}" ] && echo 0 || echo 1)"

# Reset express state
EXPRESS_MODE_ACTIVE=false
EXPRESS_PERSIST_CONFIG=true
EXPRESS_PERSIST_ROLES=false
export EXPRESS_MODE_ACTIVE EXPRESS_PERSIST_CONFIG EXPRESS_PERSIST_ROLES

restore_hooks

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  finalize_run tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All finalize_run tests passed"
