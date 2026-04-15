#!/usr/bin/env bash
# =============================================================================
# test_human_mode_resolve_notes_edge.sh
#   Tests the _hook_resolve_notes fall-through branch:
#   HUMAN_MODE=true + CURRENT_NOTE_LINE="" (empty/lost note line).
#
# Coverage gap identified in M33 review:
#   finalize.sh:115 — warn path when HUMAN_MODE=true but CURRENT_NOTE_LINE
#   is empty. The function falls through to bulk resolution. On success,
#   the orphan safety-net (lines 132-141) must resolve orphaned [~] notes
#   to [x]. On failure, the early-return guard (line 120) must leave [~]
#   notes untouched.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Redirect stderr for cleaner test output
exec 3>&2 2>/dev/null

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" = "$actual" ]]; then
        echo "PASS: $name" >&3
    else
        echo "FAIL: $name — expected '$expected', got '$actual'" >&3
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" needle="$2" file="$3"
    # Use -- to prevent patterns starting with '-' from being parsed as options
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        echo "PASS: $name" >&3
    else
        echo "FAIL: $name — '$needle' not found in '$file'" >&3
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" needle="$2" file="$3"
    # Use -- to prevent patterns starting with '-' from being parsed as options
    if ! grep -qF -- "$needle" "$file" 2>/dev/null; then
        echo "PASS: $name" >&3
    else
        echo "FAIL: $name — '$needle' unexpectedly found in '$file'" >&3
        FAIL=1
    fi
}

# ---------------------------------------------------------------------------
# Set up global environment expected by sourced libs
# ---------------------------------------------------------------------------
export PROJECT_DIR="$WORK_DIR"
export LOG_DIR="$WORK_DIR/logs"
export TIMESTAMP="test"
export NOTES_FILTER=""
export MILESTONE_MODE="false"
export HUMAN_SINGLE_NOTE="false"
export WITH_NOTES="false"

mkdir -p "$LOG_DIR"

# Source required libraries
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_core.sh"
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/notes_single.sh"

# Stub functions that finalize.sh hooks reference but are not under test.
# These stubs prevent "command not found" errors when finalize.sh is sourced.
archive_reports()                { return 0; }
run_final_checks()               { return 0; }
process_drift_artifacts()        { return 0; }
record_run_metrics()             { return 0; }
clear_resolved_nonblocking_notes() { return 0; }
get_milestone_disposition()      { echo ""; }
mark_milestone_done()            { return 0; }
archive_completed_milestone()    { return 0; }
clear_milestone_state()          { return 0; }
persist_express_config()         { return 0; }
persist_express_roles()          { return 0; }
generate_commit_message()        { echo "feat: test"; }
_check_gitignore_safety()        { return 0; }
tag_milestone_complete()         { return 0; }
print_run_summary()              { return 0; }
_print_action_items()            { return 0; }
emit_event()                     { return 0; }
emit_dashboard_run_state()       { return 0; }
emit_dashboard_metrics()         { return 0; }
emit_dashboard_milestones()      { return 0; }
emit_dashboard_health()          { return 0; }
archive_causal_log()             { return 0; }
reassess_project_health()        { echo "0"; }
_read_json_int()                 { echo "0"; }
write_last_failure_context()     { return 0; }
emit_dashboard_diagnosis()       { return 0; }
check_for_updates()              { return 0; }
update_checkpoint_commit()       { return 0; }

# Stub the two sub-source files so finalize.sh's inline `source` calls
# do not re-execute them (they are already loaded or stubbed above).
# finalize_display.sh and finalize_summary.sh just define functions;
# _print_action_items and _hook_emit_run_summary are already stubbed.
_hook_emit_run_summary() { return 0; }

# Source finalize.sh — this defines _hook_resolve_notes
source "${TEKHTON_HOME}/lib/finalize.sh"

# ---------------------------------------------------------------------------
# Helper: reset HUMAN_NOTES.md with given content for each test case
# ---------------------------------------------------------------------------
reset_notes() {
    printf '%s\n' "$1" > "${WORK_DIR}/${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"
}

# All notes functions operate on HUMAN_NOTES.md relative to CWD
cd "$WORK_DIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"

# =============================================================================
# Phase 1: Fall-through path — HUMAN_MODE=true, CURRENT_NOTE_LINE empty,
#          exit_code=0 (success), orphaned [~] note exists.
#          Expected: [~] note resolved to [x] (orphan cleanup fires).
# =============================================================================

reset_notes "## Bugs
- [~] [BUG] Orphaned note from crashed run"

export HUMAN_MODE="true"
export CURRENT_NOTE_LINE=""
unset _PIPELINE_EXIT_CODE 2>/dev/null || true

_hook_resolve_notes 0

assert_file_contains \
    "1.1 orphaned [~] note resolved to [x] on success" \
    "- [x] [BUG] Orphaned note from crashed run" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

assert_file_not_contains \
    "1.2 [~] marker gone after orphan cleanup" \
    "- [~]" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

# =============================================================================
# Phase 2: Fall-through path — HUMAN_MODE=true, CURRENT_NOTE_LINE/ID empty,
#          exit_code=1 (failure), orphaned [~] note exists.
#          M40: [~] notes are now reset to [ ] on failure (not left as [~]).
#          The [~] state is transient and must not persist between runs.
# =============================================================================

reset_notes "## Bugs
- [~] [BUG] Orphaned note from crashed run"

export HUMAN_MODE="true"
export CURRENT_NOTE_LINE=""
export CURRENT_NOTE_ID=""

_hook_resolve_notes 1

assert_file_contains \
    "2.1 [~] note reset to [ ] on failure in fall-through path" \
    "- [ ] [BUG] Orphaned note from crashed run" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

assert_file_not_contains \
    "2.2 [x] marker not written on failure" \
    "- [x]" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

# =============================================================================
# Phase 3: Normal human-mode path (CURRENT_NOTE_LINE non-empty), success.
#          Expected: resolve_single_note fires; specific [~] note → [x].
#          This is the NORMAL path — contrasted with fall-through to confirm
#          the two paths are distinct.
# =============================================================================

reset_notes "## Bugs
- [~] [BUG] Fix login timeout on slow networks
- [ ] [BUG] Another open bug"

export HUMAN_MODE="true"
export CURRENT_NOTE_LINE="- [ ] [BUG] Fix login timeout on slow networks"

_hook_resolve_notes 0

assert_file_contains \
    "3.1 targeted [~] note resolved to [x] via normal path" \
    "- [x] [BUG] Fix login timeout on slow networks" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

assert_file_contains \
    "3.2 unrelated [ ] note left untouched in normal path" \
    "- [ ] [BUG] Another open bug" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

# =============================================================================
# Phase 4: Normal human-mode path (CURRENT_NOTE_LINE non-empty), failure.
#          Expected: resolve_single_note fires; [~] → [ ] (reset, not [x]).
# =============================================================================

reset_notes "## Bugs
- [~] [BUG] Fix login timeout on slow networks"

export HUMAN_MODE="true"
export CURRENT_NOTE_LINE="- [ ] [BUG] Fix login timeout on slow networks"

_hook_resolve_notes 1

assert_file_contains \
    "4.1 [~] note reset to [ ] on failure in normal path" \
    "- [ ] [BUG] Fix login timeout on slow networks" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

assert_file_not_contains \
    "4.2 [x] not written on failure in normal path" \
    "- [x]" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

# =============================================================================
# Phase 5: Fall-through path — success, multiple orphaned [~] notes.
#          Expected: ALL [~] notes resolved to [x].
# =============================================================================

reset_notes "## Bugs
- [~] [BUG] First orphaned note
- [~] [BUG] Second orphaned note
- [ ] [BUG] Still-pending note"

export HUMAN_MODE="true"
export CURRENT_NOTE_LINE=""
unset _PIPELINE_EXIT_CODE 2>/dev/null || true

_hook_resolve_notes 0

assert_file_contains \
    "5.1 first orphaned [~] resolved to [x]" \
    "- [x] [BUG] First orphaned note" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

assert_file_contains \
    "5.2 second orphaned [~] resolved to [x]" \
    "- [x] [BUG] Second orphaned note" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

assert_file_contains \
    "5.3 still-pending [ ] note not touched" \
    "- [ ] [BUG] Still-pending note" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

# =============================================================================
# Phase 6: Fall-through path — HUMAN_MODE=false (standard mode), success.
#          Confirms bulk path is also the standard (non-human) path — no
#          regression from the fall-through sharing the same code.
# =============================================================================

reset_notes "## Bugs
- [~] [BUG] Claimed in standard mode"

export HUMAN_MODE="false"
export CURRENT_NOTE_LINE=""
unset _PIPELINE_EXIT_CODE 2>/dev/null || true

_hook_resolve_notes 0

assert_file_contains \
    "6.1 standard-mode [~] note resolved to [x] on success" \
    "- [x] [BUG] Claimed in standard mode" \
    "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"

# =============================================================================
# Done
# =============================================================================

exec 2>&3 3>&-

if [[ "$FAIL" -ne 0 ]]; then
    echo
    echo "SOME TESTS FAILED"
    exit 1
fi
echo "All tests passed."
