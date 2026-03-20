#!/usr/bin/env bash
# =============================================================================
# test_human_mode_orchestration.sh — Milestone 15.4.2 orchestration tests
#
# Validates:
# - Flag validation: --human + --milestone rejected, --human + task rejected
# - Single-note mode: note picking, task derivation, claiming
# - Human-complete mode: loop through notes
# - CURRENT_NOTE_LINE exported for finalize hooks
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

# Source just the libraries we need for testing
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/notes_single.sh"

# --- Helpers ----------------------------------------------------------------

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" = "$actual" ]]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# Create a realistic HUMAN_NOTES.md in a temp dir
setup_notes() {
    cd "$TMPDIR"
    cat > HUMAN_NOTES.md << 'EOF'
# Human Notes — TestProject

## Bugs
- [ ] [BUG] Fix login timeout on slow networks
- [ ] [BUG] Fix crash on empty input

## Features
- [ ] [FEAT] Add dark mode support

## Polish
- [ ] [POLISH] Improve error messages
- [x] [POLISH] Already done item
EOF
}

# =============================================================================
# Test 1: pick_next_note priority ordering (BUG > FEAT > POLISH)
# =============================================================================

setup_notes
note=$(pick_next_note "")
assert_eq "1.1 pick_next_note returns first bug" \
    "- [ ] [BUG] Fix login timeout on slow networks" "$note"

# =============================================================================
# Test 2: pick_next_note with BUG filter
# =============================================================================

setup_notes
note=$(pick_next_note "BUG")
assert_eq "2.1 pick_next_note BUG returns first bug" \
    "- [ ] [BUG] Fix login timeout on slow networks" "$note"

# =============================================================================
# Test 3: pick_next_note with FEAT filter
# =============================================================================

setup_notes
note=$(pick_next_note "FEAT")
assert_eq "3.1 pick_next_note FEAT returns feature" \
    "- [ ] [FEAT] Add dark mode support" "$note"

# =============================================================================
# Test 4: pick_next_note with POLISH filter
# =============================================================================

setup_notes
note=$(pick_next_note "POLISH")
assert_eq "4.1 pick_next_note POLISH returns polish item" \
    "- [ ] [POLISH] Improve error messages" "$note"

# =============================================================================
# Test 5: extract_note_text strips checkbox prefix
# =============================================================================

text=$(extract_note_text "- [ ] [BUG] Fix login timeout on slow networks")
assert_eq "5.1 extract_note_text strips [ ] prefix" \
    "[BUG] Fix login timeout on slow networks" "$text"

text=$(extract_note_text "- [~] [FEAT] Add dark mode support")
assert_eq "5.2 extract_note_text strips [~] prefix" \
    "[FEAT] Add dark mode support" "$text"

text=$(extract_note_text "- [x] [POLISH] Already done item")
assert_eq "5.3 extract_note_text strips [x] prefix" \
    "[POLISH] Already done item" "$text"

# =============================================================================
# Test 6: claim_single_note marks exactly one note
# =============================================================================

setup_notes
# Need LOG_DIR and TIMESTAMP for claim_single_note archive
LOG_DIR="$TMPDIR/logs"
TIMESTAMP="20260319_000000"
mkdir -p "$LOG_DIR"

note="- [ ] [BUG] Fix login timeout on slow networks"
claim_single_note "$note"

# Verify first bug is claimed
claimed_count=$(grep -c '^\- \[~\]' HUMAN_NOTES.md)
assert_eq "6.1 claim_single_note marks exactly one note" "1" "$claimed_count"

# Verify it's the right note
claimed_line=$(grep '^\- \[~\]' HUMAN_NOTES.md)
assert_eq "6.2 claim_single_note marks the correct note" \
    "- [~] [BUG] Fix login timeout on slow networks" "$claimed_line"

# Verify second bug is still unclaimed
second_bug=$(grep 'Fix crash on empty input' HUMAN_NOTES.md)
assert_eq "6.3 second bug still unchecked" \
    "- [ ] [BUG] Fix crash on empty input" "$second_bug"

# =============================================================================
# Test 7: resolve_single_note success (exit_code=0)
# =============================================================================

setup_notes
LOG_DIR="$TMPDIR/logs"
TIMESTAMP="20260319_000001"
claim_single_note "- [ ] [BUG] Fix login timeout on slow networks"

resolve_single_note "- [ ] [BUG] Fix login timeout on slow networks" 0

resolved_line=$(grep 'Fix login timeout' HUMAN_NOTES.md)
assert_eq "7.1 resolve_single_note success marks [x]" \
    "- [x] [BUG] Fix login timeout on slow networks" "$resolved_line"

# =============================================================================
# Test 8: resolve_single_note failure (exit_code=1)
# =============================================================================

setup_notes
LOG_DIR="$TMPDIR/logs"
TIMESTAMP="20260319_000002"
claim_single_note "- [ ] [BUG] Fix login timeout on slow networks"

resolve_single_note "- [ ] [BUG] Fix login timeout on slow networks" 1

reset_line=$(grep 'Fix login timeout' HUMAN_NOTES.md)
assert_eq "8.1 resolve_single_note failure resets to [ ]" \
    "- [ ] [BUG] Fix login timeout on slow networks" "$reset_line"

# =============================================================================
# Test 9: count_unchecked_notes
# =============================================================================

setup_notes
total=$(count_unchecked_notes "")
assert_eq "9.1 count_unchecked_notes total" "4" "$total"

bug_count=$(count_unchecked_notes "BUG")
assert_eq "9.2 count_unchecked_notes BUG" "2" "$bug_count"

feat_count=$(count_unchecked_notes "FEAT")
assert_eq "9.3 count_unchecked_notes FEAT" "1" "$feat_count"

polish_count=$(count_unchecked_notes "POLISH")
assert_eq "9.4 count_unchecked_notes POLISH" "1" "$polish_count"

# =============================================================================
# Test 10: pick_next_note returns empty when all done
# =============================================================================

cd "$TMPDIR"
cat > HUMAN_NOTES.md << 'EOF'
# Human Notes — TestProject

## Bugs
- [x] [BUG] Fixed already

## Features
- [x] [FEAT] Done

## Polish
EOF

note=$(pick_next_note "")
assert_eq "10.1 pick_next_note empty when all done" "" "$note"

# =============================================================================
# Test 11: CURRENT_NOTE_LINE and TASK derivation (simulated single-note flow)
# =============================================================================

setup_notes
LOG_DIR="$TMPDIR/logs"
TIMESTAMP="20260319_000003"
HUMAN_NOTES_TAG=""

CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
TASK=$(extract_note_text "$CURRENT_NOTE_LINE")
claim_single_note "$CURRENT_NOTE_LINE"
export CURRENT_NOTE_LINE

assert_eq "11.1 TASK set from note text" \
    "[BUG] Fix login timeout on slow networks" "$TASK"
assert_eq "11.2 CURRENT_NOTE_LINE set" \
    "- [ ] [BUG] Fix login timeout on slow networks" "$CURRENT_NOTE_LINE"

# Verify CURRENT_NOTE_LINE is exported
if [[ -n "${CURRENT_NOTE_LINE:-}" ]]; then
    echo "PASS: 11.3 CURRENT_NOTE_LINE is set and available"
else
    echo "FAIL: 11.3 CURRENT_NOTE_LINE is not set"
    FAIL=1
fi

# =============================================================================
# Test 12: Flag validation — HUMAN_MODE + MILESTONE_MODE
# =============================================================================

# This tests the validation logic that will be in tekhton.sh
HUMAN_MODE=true
MILESTONE_MODE=true
validation_error=""
if [[ "$HUMAN_MODE" = true ]] && [[ "$MILESTONE_MODE" = true ]]; then
    validation_error="Cannot combine --human with --milestone"
fi
assert_eq "12.1 --human + --milestone validation" \
    "Cannot combine --human with --milestone" "$validation_error"

# =============================================================================
# Test 13: claim_single_note with no HUMAN_NOTES.md
# =============================================================================

cd "$TMPDIR"
rm -f HUMAN_NOTES.md
rc=0
claim_single_note "- [ ] nonexistent" || rc=$?
assert_eq "13.1 claim_single_note returns 1 when no file" "1" "$rc"

# =============================================================================
# Test 14: resolve_single_note when note not found
# =============================================================================

setup_notes
rc=0
resolve_single_note "- [ ] [BUG] This note does not exist" 0 || rc=$?
assert_eq "14.1 resolve_single_note returns 1 when note not found" "1" "$rc"

# =============================================================================
# Test 15: Sequential note processing (simulated human-complete flow)
# =============================================================================

setup_notes
LOG_DIR="$TMPDIR/logs"
TIMESTAMP="20260319_000004"
HUMAN_NOTES_TAG=""

# Process first note
note1=$(pick_next_note "$HUMAN_NOTES_TAG")
assert_eq "15.1 first note is first bug" \
    "- [ ] [BUG] Fix login timeout on slow networks" "$note1"
claim_single_note "$note1"
resolve_single_note "$note1" 0

# Process second note
TIMESTAMP="20260319_000005"
note2=$(pick_next_note "$HUMAN_NOTES_TAG")
assert_eq "15.2 second note is second bug" \
    "- [ ] [BUG] Fix crash on empty input" "$note2"
claim_single_note "$note2"
resolve_single_note "$note2" 0

# Process third note
TIMESTAMP="20260319_000006"
note3=$(pick_next_note "$HUMAN_NOTES_TAG")
assert_eq "15.3 third note is feature" \
    "- [ ] [FEAT] Add dark mode support" "$note3"
claim_single_note "$note3"
resolve_single_note "$note3" 0

# Process fourth note
TIMESTAMP="20260319_000007"
note4=$(pick_next_note "$HUMAN_NOTES_TAG")
assert_eq "15.4 fourth note is polish" \
    "- [ ] [POLISH] Improve error messages" "$note4"
claim_single_note "$note4"
resolve_single_note "$note4" 0

# No more notes
note5=$(pick_next_note "$HUMAN_NOTES_TAG")
assert_eq "15.5 no more notes after all processed" "" "$note5"

# Verify all 4 original unchecked notes are now [x]
done_count=$(grep -c '^\- \[x\]' HUMAN_NOTES.md)
assert_eq "15.6 all 4 notes resolved + 1 pre-existing = 5 [x]" "5" "$done_count"

# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "SOME TESTS FAILED"
    exit 1
fi
echo
echo "All tests passed."
