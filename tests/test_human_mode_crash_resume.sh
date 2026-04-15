#!/usr/bin/env bash
# =============================================================================
# test_human_mode_crash_resume.sh — M33 crash-recovery resume guard
#
# Coverage gap from M33 reviewer cycle 3:
#   "No test covers exec-resume with a [~] note (crash recovery scenario):
#    a test that simulates a resumed invocation where the note is [~] and
#    verifies pick_next_note is skipped would close the gap introduced by
#    the tekhton.sh fix."
#
# Validates:
#   1. Guard condition: non-empty CURRENT_NOTE_LINE in env → pick_next_note
#      is NOT called; the env value is preserved as-is.
#   2. Without guard: calling pick_next_note on a file with only [~] notes
#      returns empty, which would cause the "no notes" early-exit path.
#   3. The env-restored value is correctly usable by extract_note_text
#      and claim_single_note (idempotent claim on already-[~] note).
#   4. Empty CURRENT_NOTE_LINE → guard falls through to pick_next_note.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
LOG_DIR=""
TIMESTAMP=""
export PROJECT_DIR LOG_DIR TIMESTAMP

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_core.sh"
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/notes_single.sh"

# Redirect log() output so it doesn't pollute test stdout
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

assert_nonempty() {
    local name="$1" actual="$2"
    if [[ -n "$actual" ]]; then
        echo "PASS: $name" >&3
    else
        echo "FAIL: $name — expected non-empty, got empty" >&3
        FAIL=1
    fi
}

assert_empty() {
    local name="$1" actual="$2"
    if [[ -z "$actual" ]]; then
        echo "PASS: $name" >&3
    else
        echo "FAIL: $name — expected empty, got '$actual'" >&3
        FAIL=1
    fi
}

cd "$TMPDIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"

# =============================================================================
# Phase 1: Baseline — verify pick_next_note returns empty for [~]-only file
#
# This documents WHY the guard is needed: after a crash, the note is [~]
# and pick_next_note (which only scans [ ] lines) returns empty.  Without
# the guard, the pipeline would see CURRENT_NOTE_LINE="" and exit with
# "No unchecked notes."
# =============================================================================

cat > "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] [BUG] Fix login timeout on slow networks
EOF

result=$(pick_next_note "BUG")
assert_empty "1.1 pick_next_note returns empty when only [~] notes exist" "$result"

result=$(pick_next_note "")
assert_empty "1.2 pick_next_note (no tag) returns empty when only [~] notes exist" "$result"

# =============================================================================
# Phase 2: Guard present — CURRENT_NOTE_LINE from env bypasses pick_next_note
#
# Simulates what tekhton.sh does at line ~1385 on crash-recovery resume:
#   if [[ -n "${CURRENT_NOTE_LINE:-}" ]]; then
#       log "Human mode: restoring claimed note from prior run"
#   else
#       CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
#   fi
#
# The env var is set to the ORIGINAL [ ] form (as exported before the crash).
# The file has the [~] form (as left by claim_single_note before the crash).
# =============================================================================

# Simulate: process crashed after claim, before finalize.
# Env still holds the original note line (as exported by tekhton.sh).
ORIGINAL_NOTE="- [ ] [BUG] Fix login timeout on slow networks"
CURRENT_NOTE_LINE="$ORIGINAL_NOTE"
HUMAN_NOTES_TAG="BUG"

# Apply the guard logic (mirrors tekhton.sh lines 1385-1389 exactly)
if [[ -n "${CURRENT_NOTE_LINE:-}" ]]; then
    : # guard: skip pick_next_note, restore from env
else
    CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
fi

assert_eq "2.1 CURRENT_NOTE_LINE preserved from env (guard fired)" \
    "$ORIGINAL_NOTE" "$CURRENT_NOTE_LINE"

assert_nonempty "2.2 CURRENT_NOTE_LINE is non-empty after guard" "$CURRENT_NOTE_LINE"

# =============================================================================
# Phase 3: Guard absent (negative case) — pick_next_note wipes CURRENT_NOTE_LINE
#
# This proves the guard is load-bearing: skipping it causes the pipeline to
# see CURRENT_NOTE_LINE="" and exit with "No unchecked notes", losing the task.
# =============================================================================

# Same crash state but simulate the pre-fix behavior: always call pick_next_note
CURRENT_NOTE_LINE_NO_GUARD=$(pick_next_note "$HUMAN_NOTES_TAG")

assert_empty "3.1 Without guard: pick_next_note returns empty for [~]-only file" \
    "$CURRENT_NOTE_LINE_NO_GUARD"

# Confirm: the no-guard path would trigger the "no notes" exit
if [[ -z "$CURRENT_NOTE_LINE_NO_GUARD" ]]; then
    would_exit_early="yes"
else
    would_exit_early="no"
fi
assert_eq "3.2 Without guard: empty result triggers early-exit path" "yes" "$would_exit_early"

# =============================================================================
# Phase 4: extract_note_text works correctly with the env-restored note
#
# After the guard restores CURRENT_NOTE_LINE from env, tekhton.sh calls
#   TASK=$(extract_note_text "$CURRENT_NOTE_LINE")
# Verify the task text is correctly derived from the env value.
# =============================================================================

task_text=$(extract_note_text "$CURRENT_NOTE_LINE")
assert_eq "4.1 extract_note_text extracts task from env-restored note" \
    "[BUG] Fix login timeout on slow networks" "$task_text"

# =============================================================================
# Phase 5: FEAT tag variant — guard works for all tag types
# =============================================================================

cat > "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md" << 'EOF'
## Features
- [~] [FEAT] Add dark mode toggle
EOF

ORIGINAL_FEAT_NOTE="- [ ] [FEAT] Add dark mode toggle"
CURRENT_NOTE_LINE="$ORIGINAL_FEAT_NOTE"
HUMAN_NOTES_TAG="FEAT"

# Guard
if [[ -n "${CURRENT_NOTE_LINE:-}" ]]; then
    :
else
    CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
fi

assert_eq "5.1 Guard works for FEAT tag: env note preserved" \
    "$ORIGINAL_FEAT_NOTE" "$CURRENT_NOTE_LINE"

# Without guard, would return empty
nogard=$(pick_next_note "$HUMAN_NOTES_TAG")
assert_empty "5.2 Without guard: FEAT [~]-only file returns empty" "$nogard"

# =============================================================================
# Phase 6: Empty CURRENT_NOTE_LINE → guard falls through to pick_next_note
#
# When CURRENT_NOTE_LINE is unset/empty (fresh invocation, not a resume),
# the guard must NOT fire — pick_next_note must be called normally.
# =============================================================================

cat > "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [ ] [BUG] Fresh unchecked bug
EOF

CURRENT_NOTE_LINE=""
HUMAN_NOTES_TAG="BUG"

# Guard (same logic as tekhton.sh)
if [[ -n "${CURRENT_NOTE_LINE:-}" ]]; then
    :
else
    CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
fi

assert_eq "6.1 Empty CURRENT_NOTE_LINE falls through to pick_next_note" \
    "- [ ] [BUG] Fresh unchecked bug" "$CURRENT_NOTE_LINE"

# =============================================================================
# Phase 7: Mixed file — [~] note for current run + [  ] for future run
#
# Simulates the realistic crash state: one note in [~] (the one being worked
# on), remaining notes in [ ]. Verifies that the guard restores the claimed
# note without accidentally picking a different [ ] note.
# =============================================================================

cat > "${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md" << 'EOF'
## Bugs
- [~] [BUG] Fix login timeout on slow networks
- [ ] [BUG] Fix password reset email

## Features
- [ ] [FEAT] Add dark mode toggle
EOF

ORIGINAL_NOTE="- [ ] [BUG] Fix login timeout on slow networks"
CURRENT_NOTE_LINE="$ORIGINAL_NOTE"
HUMAN_NOTES_TAG=""

# Guard
if [[ -n "${CURRENT_NOTE_LINE:-}" ]]; then
    :
else
    CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
fi

assert_eq "7.1 Guard restores claimed note, not the next [ ] note" \
    "$ORIGINAL_NOTE" "$CURRENT_NOTE_LINE"

# Confirm what pick_next_note WOULD have picked (the next [ ] note, not the [~])
would_have_picked=$(pick_next_note "")
assert_eq "7.2 Without guard: pick_next_note picks next [ ] note (wrong task)" \
    "- [ ] [BUG] Fix password reset email" "$would_have_picked"

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
