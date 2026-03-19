#!/usr/bin/env bash
# =============================================================================
# test_human_notes_lifecycle.sh — Three-state human notes tracking
#
# Tests the [ ] → [~] → [x] / [ ] lifecycle:
#   1. count/extract on fresh file
#   2. claim_human_notes marks filtered items [~]
#   3. resolve with structured CODER_SUMMARY → selective [x] / [ ]
#   4. resolve fallback (no structured section, COMPLETE status) → all [x]
#   5. resolve fallback (no summary) → all reset to [ ]
#   6. [~] never persists after resolve
#   7. Notes filter respects tags
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

notes_file="${TMPDIR}/HUMAN_NOTES.md"
cd "$TMPDIR"

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
# Phase 4: resolve with structured CODER_SUMMARY — selective completion
# =============================================================================

cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
Fixed the Law increment bug.
## Human Notes Status
- COMPLETED: [BUG] Card flips auto-increment Law even when locked
- NOT_ADDRESSED: [BUG] Foundation scoring counts twice on aces (out of scope)
EOF

resolve_human_notes 2>/dev/null

assert_file_contains "4.1 completed item marked [x]" "$notes_file" '^\- \[x\] \[BUG\] Card flips'
assert_file_contains "4.2 not-addressed reset to [ ]" "$notes_file" '^\- \[ \] \[BUG\] Foundation scoring'
assert_file_contains "4.3 FEAT unchanged" "$notes_file" '^\- \[ \] \[FEAT\]'
assert_file_not_contains "4.4 no [~] items remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 5: resolve fallback — COMPLETE status, no structured section
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [BUG] Bug two
- [ ] [FEAT] Feature one
EOF

cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
Fixed both bugs.
EOF

NOTES_FILTER="BUG"
resolve_human_notes 2>/dev/null

assert_file_contains "5.1 fallback COMPLETE: all [~] → [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug one'
assert_file_contains "5.2 fallback COMPLETE: second also [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug two'
assert_file_contains "5.3 FEAT untouched" "$notes_file" '^\- \[ \] \[FEAT\]'
assert_file_not_contains "5.4 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 6: resolve fallback — no CODER_SUMMARY → reset all [~] to [ ]
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [BUG] Bug two
- [ ] [FEAT] Feature one
EOF

rm -f "${TMPDIR}/CODER_SUMMARY.md"

resolve_human_notes 2>/dev/null

assert_file_contains "6.1 no summary: [~] reset to [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug one'
assert_file_contains "6.2 no summary: second also [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug two'
assert_file_not_contains "6.3 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 7: resolve fallback — IN PROGRESS status → reset to [ ]
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [BUG] Bug two
EOF

cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: IN PROGRESS
## What Was Implemented
Started on bug one.
## Remaining Work
Bug two still open.
EOF

resolve_human_notes 2>/dev/null

assert_file_contains "7.1 IN PROGRESS: all [~] reset to [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug one'
assert_file_contains "7.2 IN PROGRESS: second also [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug two'
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
# Phase 9: structured resolve with partial CODER_SUMMARY (some items unmentioned)
# =============================================================================

# notes_file still has [~] items from Phase 8
cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## Human Notes Status
- COMPLETED: [BUG] Bug one
EOF

resolve_human_notes 2>/dev/null

assert_file_contains "9.1 mentioned COMPLETED → [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug one'
# Unmentioned [~] items should be reset to [ ] (safety net)
assert_file_not_contains "9.2 no [~] remain (safety reset)" "$notes_file" '^\- \[~\]'
assert_file_contains "9.3 unmentioned FEAT reset to [ ]" "$notes_file" '^\- \[ \] \[FEAT\] Feature one'

# =============================================================================
# Phase 10: pipeline exit code awareness — missing summary, pipeline succeeded
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [FEAT] Feature one
EOF

rm -f "${TMPDIR}/CODER_SUMMARY.md"
_PIPELINE_EXIT_CODE=0
resolve_human_notes 2>/dev/null

assert_file_contains "10.1 pipeline success + no summary → [x]" "$notes_file" '^\- \[x\] \[BUG\] Bug one'
assert_file_contains "10.2 pipeline success + no summary → [x]" "$notes_file" '^\- \[x\] \[FEAT\] Feature one'
assert_file_not_contains "10.3 no [~] remain" "$notes_file" '^\- \[~\]'

# =============================================================================
# Phase 11: pipeline exit code awareness — missing summary, pipeline failed
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Playtester Notes

- [~] [BUG] Bug one
- [~] [FEAT] Feature one
EOF

rm -f "${TMPDIR}/CODER_SUMMARY.md"
_PIPELINE_EXIT_CODE=1
resolve_human_notes 2>/dev/null

assert_file_contains "11.1 pipeline failed + no summary → [ ]" "$notes_file" '^\- \[ \] \[BUG\] Bug one'
assert_file_contains "11.2 pipeline failed + no summary → [ ]" "$notes_file" '^\- \[ \] \[FEAT\] Feature one'
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
