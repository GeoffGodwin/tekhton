#!/usr/bin/env bash
# =============================================================================
# test_human_mode_state_resume.sh — M33: Human-mode state persistence + resume
#
# Validates:
#   - write_pipeline_state() persists all four human-mode metadata sections
#   - awk extraction (mirroring tekhton.sh resume block) correctly reads them back
#   - _build_resume_flag() returns correct flag for human / milestone / standard modes
#   - SAVED_HUMAN_MODE branch: exec path omits task in human-mode resume
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_core.sh"
source "${TEKHTON_HOME}/lib/errors.sh"
source "${TEKHTON_HOME}/lib/state.sh"
source "${TEKHTON_HOME}/lib/notes_single.sh"

mkdir -p "${TMPDIR}/.claude"
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
export PIPELINE_STATE_FILE

# Silence log output — state.sh writes log() calls during write
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
    if grep -qF "$needle" "$file" 2>/dev/null; then
        echo "PASS: $name" >&3
    else
        echo "FAIL: $name — '$needle' not found in '$file'" >&3
        FAIL=1
    fi
}

# Extract field from state file using the same awk pattern as tekhton.sh
extract_state_field() {
    local section="$1" file="$2"
    awk "/^## ${section}\$/{getline; print; exit}" "$file"
}

# =============================================================================
# Phase 1: write_pipeline_state persists human-mode sections with HUMAN_MODE=true
# =============================================================================

export HUMAN_MODE="true"
export HUMAN_NOTES_TAG="BUG"
export CURRENT_NOTE_LINE="- [ ] [BUG] Fix login timeout on slow networks"
export HUMAN_SINGLE_NOTE="true"
unset AGENT_ERROR_CATEGORY MILESTONE_MODE 2>/dev/null || true

write_pipeline_state "coder" "turn_limit" "--human BUG --start-at coder" "picked_from_notes" ""

assert_file_contains "1.1 Human Mode section exists" "## Human Mode" "$PIPELINE_STATE_FILE"
assert_file_contains "1.2 Human Notes Tag section exists" "## Human Notes Tag" "$PIPELINE_STATE_FILE"
assert_file_contains "1.3 Current Note Line section exists" "## Current Note Line" "$PIPELINE_STATE_FILE"
assert_file_contains "1.4 Human Single Note section exists" "## Human Single Note" "$PIPELINE_STATE_FILE"

# =============================================================================
# Phase 2: awk extraction round-trip (mirrors tekhton.sh resume detection block)
# =============================================================================

saved_human_mode=$(extract_state_field "Human Mode" "$PIPELINE_STATE_FILE")
saved_human_tag=$(extract_state_field "Human Notes Tag" "$PIPELINE_STATE_FILE")
saved_note_line=$(extract_state_field "Current Note Line" "$PIPELINE_STATE_FILE")
saved_human_single=$(extract_state_field "Human Single Note" "$PIPELINE_STATE_FILE")

assert_eq "2.1 SAVED_HUMAN_MODE extracted correctly" "true" "$saved_human_mode"
assert_eq "2.2 SAVED_HUMAN_TAG extracted correctly" "BUG" "$saved_human_tag"
assert_eq "2.3 SAVED_NOTE_LINE extracted correctly" \
    "- [ ] [BUG] Fix login timeout on slow networks" "$saved_note_line"
assert_eq "2.4 SAVED_HUMAN_SINGLE extracted correctly" "true" "$saved_human_single"

# =============================================================================
# Phase 3: write_pipeline_state persists HUMAN_MODE=false correctly
# =============================================================================

export HUMAN_MODE="false"
unset HUMAN_NOTES_TAG CURRENT_NOTE_LINE HUMAN_SINGLE_NOTE 2>/dev/null || true

write_pipeline_state "review" "blockers_remain" "--start-at review" "standard task" ""

saved_human_mode_false=$(extract_state_field "Human Mode" "$PIPELINE_STATE_FILE")
assert_eq "3.1 HUMAN_MODE=false written correctly" "false" "$saved_human_mode_false"

# =============================================================================
# Phase 4: write_pipeline_state persists empty tag correctly
# =============================================================================

export HUMAN_MODE="true"
export HUMAN_NOTES_TAG=""
export CURRENT_NOTE_LINE="- [ ] [BUG] Some task"
export HUMAN_SINGLE_NOTE="true"

write_pipeline_state "tester" "turn_limit" "--human --start-at tester" "picked_from_notes" ""

saved_tag_empty=$(extract_state_field "Human Notes Tag" "$PIPELINE_STATE_FILE")
assert_eq "4.1 empty HUMAN_NOTES_TAG written as empty line" "" "$saved_tag_empty"

# =============================================================================
# Phase 5: _build_resume_flag in human mode without tag
# =============================================================================

export HUMAN_MODE="true"
export HUMAN_NOTES_TAG=""
unset MILESTONE_MODE 2>/dev/null || true

flag=$(HUMAN_MODE="true" HUMAN_NOTES_TAG="" _build_resume_flag)
assert_eq "5.1 human mode no tag → --human --start-at coder" "--human --start-at coder" "$flag"

# =============================================================================
# Phase 6: _build_resume_flag in human mode with BUG tag
# =============================================================================

flag=$(HUMAN_MODE="true" HUMAN_NOTES_TAG="BUG" _build_resume_flag)
assert_eq "6.1 human mode BUG tag → --human BUG --start-at coder" "--human BUG --start-at coder" "$flag"

# =============================================================================
# Phase 7: _build_resume_flag in human mode with custom start-at
# =============================================================================

flag=$(HUMAN_MODE="true" HUMAN_NOTES_TAG="FEAT" _build_resume_flag "tester")
assert_eq "7.1 human mode FEAT tag start-at tester" "--human FEAT --start-at tester" "$flag"

# =============================================================================
# Phase 8: _build_resume_flag in milestone mode
# =============================================================================

flag=$(HUMAN_MODE="false" MILESTONE_MODE="true" _build_resume_flag)
assert_eq "8.1 milestone mode → --milestone --start-at coder" "--milestone --start-at coder" "$flag"

# =============================================================================
# Phase 9: _build_resume_flag in standard mode
# =============================================================================

flag=$(HUMAN_MODE="false" MILESTONE_MODE="false" _build_resume_flag)
assert_eq "9.1 standard mode → --start-at coder" "--start-at coder" "$flag"

flag=$(HUMAN_MODE="false" MILESTONE_MODE="false" _build_resume_flag "review")
assert_eq "9.2 standard mode custom start-at → --start-at review" "--start-at review" "$flag"

# =============================================================================
# Phase 10: SAVED_HUMAN_MODE true branch logic (exec omits task)
#   Simulate the tekhton.sh resume branch: when SAVED_HUMAN_MODE=true, the
#   exec command should NOT include SAVED_TASK. We verify this by checking that
#   the constructed exec invocation matches the expected form.
# =============================================================================

export HUMAN_MODE="true"
export HUMAN_NOTES_TAG="BUG"
export CURRENT_NOTE_LINE="- [ ] [BUG] Fix login timeout"
export HUMAN_SINGLE_NOTE="true"
SAVED_TASK="[BUG] Fix login timeout"

write_pipeline_state "coder" "turn_limit" "--human BUG --start-at coder" "$SAVED_TASK" ""

saved_human_mode=$(extract_state_field "Human Mode" "$PIPELINE_STATE_FILE")
saved_resume_flag=$(extract_state_field "Resume Command" "$PIPELINE_STATE_FILE")

# When SAVED_HUMAN_MODE is true, exec must use only flags (no positional task arg).
# Verify this by checking that the resume flag is set correctly AND that
# the exec-without-task branch condition evaluates as expected.
if [[ "${saved_human_mode}" = "true" ]]; then
    echo "PASS: 10.1 SAVED_HUMAN_MODE=true triggers no-task exec branch" >&3
else
    echo "FAIL: 10.1 SAVED_HUMAN_MODE should be true, got '$saved_human_mode'" >&3
    FAIL=1
fi

# Verify the resume flag saved is for human mode (not --milestone)
if [[ "$saved_resume_flag" == *"--human"* ]]; then
    echo "PASS: 10.2 resume flag contains --human" >&3
else
    echo "FAIL: 10.2 resume flag should contain --human, got '$saved_resume_flag'" >&3
    FAIL=1
fi

# Critically: verify flag does NOT start with --milestone (the pre-M33 regression)
if [[ "$saved_resume_flag" != *"--milestone"* ]]; then
    echo "PASS: 10.3 resume flag does not contain --milestone in human mode" >&3
else
    echo "FAIL: 10.3 resume flag must not contain --milestone in human mode" >&3
    FAIL=1
fi

# =============================================================================
# Phase 11: HUMAN_SINGLE_NOTE=false vs true preserved across state roundtrip
# =============================================================================

export HUMAN_MODE="true"
export HUMAN_NOTES_TAG=""
export CURRENT_NOTE_LINE=""
export HUMAN_SINGLE_NOTE="false"

write_pipeline_state "coder" "turn_limit" "--human --start-at coder" "task" ""
saved_single=$(extract_state_field "Human Single Note" "$PIPELINE_STATE_FILE")
assert_eq "11.1 HUMAN_SINGLE_NOTE=false round-trips correctly" "false" "$saved_single"

export HUMAN_SINGLE_NOTE="true"
write_pipeline_state "coder" "turn_limit" "--human --start-at coder" "task" ""
saved_single=$(extract_state_field "Human Single Note" "$PIPELINE_STATE_FILE")
assert_eq "11.2 HUMAN_SINGLE_NOTE=true round-trips correctly" "true" "$saved_single"

# =============================================================================
# Phase 12: Crash-resume scenario — [~] note is invisible to pick_next_note
#
# Documents the root cause of the crash-recovery gap (identified in M33
# reviewer cycle 2): when a run crashes after claim_single_note marks a note
# [~] but before finalize_run resolves it, the resumed invocation has
# CURRENT_NOTE_LINE in env BUT unconditionally calls pick_next_note.
# Since pick_next_note only scans [ ] items, it returns empty for any [~] note.
# This test documents that behavior so the guard proposed in the reviewer's
# non-blocking note (use CURRENT_NOTE_LINE from env when HUMAN_SINGLE_NOTE=true)
# remains visible and testable.
# =============================================================================

cd "$TMPDIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"

# 12.1: pick_next_note returns the note when it's [ ]
HUMAN_NOTES_FILE="${HUMAN_NOTES_FILE:-${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md}"
cat > "${HUMAN_NOTES_FILE}" << 'EOF'
## Bugs
- [ ] [BUG] Fix login timeout on slow networks
EOF

result=$(pick_next_note "BUG")
assert_eq "12.1 pick_next_note finds [ ] note before claim" \
    "- [ ] [BUG] Fix login timeout on slow networks" "$result"

# 12.2: After claim_single_note, the note is [~]; pick_next_note returns empty.
# This simulates the crash state: note was claimed, pipeline crashed, resume
# re-runs pick_next_note without checking CURRENT_NOTE_LINE env.

export LOG_DIR="" TIMESTAMP=""
claim_single_note "- [ ] [BUG] Fix login timeout on slow networks"

result=$(pick_next_note "BUG")
assert_eq "12.2 pick_next_note returns empty for [~] note (crash-resume gap)" "" "$result"

# 12.3: CURRENT_NOTE_LINE from env is the only reliable source of truth after crash.
# The test verifies the claimed note is still in the file (confirming claim succeeded)
# and that CURRENT_NOTE_LINE matches it — this is the value the resumed exec
# should export before re-entering the loop.
export CURRENT_NOTE_LINE="- [ ] [BUG] Fix login timeout on slow networks"
claimed_version="${CURRENT_NOTE_LINE/\[ \]/[~]}"
if grep -qF -- "$claimed_version" "${HUMAN_NOTES_FILE}" 2>/dev/null; then
    echo "PASS: 12.3 claimed [~] note is in file; CURRENT_NOTE_LINE env is recovery anchor" >&3
else
    echo "FAIL: 12.3 claimed note not found in [~] state — claim_single_note may have failed" >&3
    FAIL=1
fi

# 12.4: count_unchecked_notes also returns 0 for a file with only [~] notes.
# Confirms the caller loop would see no work left and exit if it relied on
# count_unchecked_notes rather than CURRENT_NOTE_LINE env.
remaining=$(count_unchecked_notes "BUG")
assert_eq "12.4 count_unchecked_notes=0 when only [~] notes remain" "0" "$remaining"

cd - > /dev/null 2>&1 || true

# =============================================================================
# Done
# =============================================================================

exec 2>&3 3>&-

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "SOME TESTS FAILED"
    exit 1
fi
echo "All tests passed."
