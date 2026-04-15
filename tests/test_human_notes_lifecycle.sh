#!/usr/bin/env bash
# =============================================================================
# test_human_notes_lifecycle.sh — Three-state human notes tracking
#
# Tests the [ ] → [~] → [x] / [ ] lifecycle:
#   1. count/extract on fresh file
#   2. claim_human_notes marks filtered items [~]
#   3. resolve via exit code — pipeline success → [x], failure → [ ]
#   4. claim with no filter — all items claimed
#   5-6. Structured resolve edge cases (partial mentions, already [x])
#   7-8. Pipeline exit code awareness
#
# M40: Resolution is now exit-code-based (via _PIPELINE_EXIT_CODE), not
# CODER_SUMMARY.md parsing. Selective per-note parsing was removed.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Minimal pipeline globals ------------------------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR="${TMPDIR}/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP="20260308_120000"
NOTES_FILTER=""

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_core.sh"
source "${TEKHTON_HOME}/lib/notes.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' should NOT be in $file"
        FAIL=1
    fi
}

notes_file="${TMPDIR}/${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md"
cd "$TMPDIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"

# =============================================================================
# Phase 1: No file — clean baseline
# =============================================================================
assert_eq "1.1 count with no file" "0" "$(count_human_notes)"

extracted=$(extract_human_notes)
assert_eq "1.2 extract with no file" "" "$extracted"

# =============================================================================
# Phase 2: Count and extract basics
# =============================================================================
cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [ ] [BUG] Card flips auto-increment Law even when locked
- [ ] [BUG] Foundation scoring counts twice on aces
- [ ] [FEAT] Add card selection hover animation
- [ ] [POLISH] Win state Fate Orb should fade to gray
- [x] [BUG] Previously fixed bug stays marked
EOF

assert_eq "2.1 count all unchecked" "4" "$(count_human_notes)"

NOTES_FILTER="BUG"
assert_eq "2.2 count BUG only" "2" "$(count_human_notes)"

NOTES_FILTER="FEAT"
assert_eq "2.3 count FEAT only" "1" "$(count_human_notes)"

NOTES_FILTER="POLISH"
assert_eq "2.4 count POLISH only" "1" "$(count_human_notes)"

NOTES_FILTER=""
extracted=$(extract_human_notes)
line_count=$(echo "$extracted" | grep -c "^- " || true)
assert_eq "2.5 extract all returns 4 items" "4" "$line_count"

NOTES_FILTER="BUG"
extracted=$(extract_human_notes)
line_count=$(echo "$extracted" | grep -c "^- " || true)
assert_eq "2.6 extract BUG returns 2 items" "2" "$line_count"

# =============================================================================
# Phase 3: claim_human_notes marks [ ] → [~] for filtered items
# =============================================================================

# Reset file
cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [ ] [BUG] Card flips auto-increment Law even when locked
- [ ] [BUG] Foundation scoring counts twice on aces
- [ ] [FEAT] Add card selection hover animation
- [ ] [POLISH] Win state Fate Orb should fade to gray
EOF

NOTES_FILTER="BUG"
claim_human_notes 2>/dev/null

assert_file_contains "3.1 BUG items marked [~]" "$notes_file" '^\- \[~\] \[BUG\] Card flips'
assert_file_contains "3.2 second BUG also [~]" "$notes_file" '^\- \[~\] \[BUG\] Foundation scoring'
assert_file_contains "3.3 FEAT still [ ]" "$notes_file" '^\- \[ \] \[FEAT\]'
assert_file_contains "3.4 POLISH still [ ]" "$notes_file" '^\- \[ \] \[POLISH\]'

# Verify archive was created
assert_file_contains "3.5 archive created" "${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md" '\[ \] \[BUG\] Card flips'

# =============================================================================
# Phase 4: resolve with pipeline success → [~] → [x]
# M40: Resolution is exit-code-based, not CODER_SUMMARY parsing.
# =============================================================================

_PIPELINE_EXIT_CODE=0
resolve_human_notes 2>/dev/null

assert_file_contains "4.1 success: BUG item 1 marked [x]" "$notes_file" '^\- \[x\] \[BUG\] Card flips'
assert_file_contains "4.2 success: BUG item 2 marked [x]" "$notes_file" '^\- \[x\] \[BUG\] Foundation scoring'
assert_file_contains "4.3 FEAT unchanged" "$notes_file" '^\- \[ \] \[FEAT\]'
assert_file_not_contains "4.4 no [~] items remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 5: resolve with pipeline success → all [~] → [x]
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [BUG] Bug two
- [ ] [FEAT] Feature one
EOF

_PIPELINE_EXIT_CODE=0
NOTES_FILTER="BUG"
resolve_human_notes 2>/dev/null

assert_file_contains "5.1 success: all [~] → [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug one'
assert_file_contains "5.2 success: second also [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug two'
assert_file_contains "5.3 FEAT untouched" "$notes_file" '^\- \[ \] \[FEAT\]'
assert_file_not_contains "5.4 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 6: resolve with pipeline failure → all [~] → [ ]
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [BUG] Bug two
- [ ] [FEAT] Feature one
EOF

_PIPELINE_EXIT_CODE=1
resolve_human_notes 2>/dev/null

assert_file_contains "6.1 failure: [~] reset to [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug one'
assert_file_contains "6.2 failure: second also [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug two'
assert_file_not_contains "6.3 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 7: resolve with no summary, pipeline failure → reset to [ ]
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [BUG] Bug two
EOF

_PIPELINE_EXIT_CODE=1
resolve_human_notes 2>/dev/null

assert_file_contains "7.1 failure: all [~] reset to [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug one'
assert_file_contains "7.2 failure: second also [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug two'
assert_file_not_contains "7.3 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 8: claim with no filter — all items claimed
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [ ] [BUG] Bug one
- [ ] [FEAT] Feature one
- [ ] [POLISH] Polish one
- [x] [BUG] Already done
EOF

NOTES_FILTER=""
TIMESTAMP="20260308_130000"
claim_human_notes 2>/dev/null

assert_file_contains "8.1 all unchecked marked [~]" "$notes_file" '^\- \[~\] \[BUG\] Bug one'
assert_file_contains "8.2 FEAT also [~]" "$notes_file" '^\- \[~\] \[FEAT\] Feature one'
assert_file_contains "8.3 POLISH also [~]" "$notes_file" '^\- \[~\] \[POLISH\] Polish one'
assert_file_contains "8.4 already [x] unchanged" "$notes_file" '^\- \[x\] \[BUG\] Already done'

# =============================================================================
# Phase 9: resolve all claimed notes on pipeline success
# M40: All [~] → [x] on success (no selective CODER_SUMMARY parsing).
# =============================================================================

# notes_file still has [~] items from Phase 8
_PIPELINE_EXIT_CODE=0
resolve_human_notes 2>/dev/null

assert_file_contains "9.1 success: BUG → [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug one'
assert_file_contains "9.2 success: FEAT → [x]" "$notes_file" '^\- \[x\] \[FEAT\] Feature one'
assert_file_contains "9.3 success: POLISH → [x]" "$notes_file" '^\- \[x\] \[POLISH\] Polish one'
assert_file_not_contains "9.4 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 10: pipeline exit code awareness — pipeline succeeded → [x]
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [FEAT] Feature one
EOF

_PIPELINE_EXIT_CODE=0
resolve_human_notes 2>/dev/null

assert_file_contains "10.1 pipeline success → [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug one'
assert_file_contains "10.2 pipeline success → [x]" "$notes_file" '^\- \[x\] \[FEAT\] Feature one'
assert_file_not_contains "10.3 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 11: pipeline exit code awareness — pipeline failed → [ ]
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [FEAT] Feature one
EOF

_PIPELINE_EXIT_CODE=1
resolve_human_notes 2>/dev/null

assert_file_contains "11.1 pipeline failed → [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug one'
assert_file_contains "11.2 pipeline failed → [ ]" "$notes_file" '^\- \[ \] \[FEAT\] Feature one'
assert_file_not_contains "11.3 no [~] remain" "$notes_file" '^\- \[~\]'

# Clean up pipeline exit code
unset _PIPELINE_EXIT_CODE

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "All human notes lifecycle tests passed."
