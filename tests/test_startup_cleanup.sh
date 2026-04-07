#!/usr/bin/env bash
# Test: Startup cleanup of resolved/completed items across all three log files.
# Verifies that clear_completed_human_notes, clear_completed_nonblocking_notes,
# clear_resolved_drift_observations, and clear_resolved_nonblocking_notes
# correctly remove stale items while preserving active items.

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"

DRIFT_LOG_FILE="DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="Test task"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"
source "${TEKHTON_HOME}/lib/drift_artifacts.sh"
source "${TEKHTON_HOME}/lib/notes.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "✓ PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "✗ FAIL: $label (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "✓ PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "✗ FAIL: $label (pattern '$pattern' not found in $file)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "✗ FAIL: $label (pattern '$pattern' unexpectedly found in $file)"
        FAIL=$((FAIL + 1))
    else
        echo "✓ PASS: $label"
        PASS=$((PASS + 1))
    fi
}

# ============================================================================
# Test 1: clear_completed_human_notes removes [x] items, preserves [ ] and [~]
# ============================================================================
echo "--- Test 1: HUMAN_NOTES.md [x] cleanup ---"

cat > "$TMPDIR/HUMAN_NOTES.md" << 'EOF'
# Human Notes

## Bugs
- [x] [BUG] Fixed bug one
- [ ] [BUG] Open bug two
- [~] [BUG] In-progress bug three
- [x] [BUG] Fixed bug four

## Features
- [ ] [FEAT] Open feature
- [x] [FEAT] Completed feature
EOF

clear_completed_human_notes

assert_file_not_contains "No [x] items remain" "$TMPDIR/HUMAN_NOTES.md" '^\- \[x\] '
assert_file_contains "Open bug preserved" "$TMPDIR/HUMAN_NOTES.md" '^\- \[ \] \[BUG\] Open bug two'
assert_file_contains "In-progress bug preserved" "$TMPDIR/HUMAN_NOTES.md" '^\- \[~\] \[BUG\] In-progress bug three'
assert_file_contains "Open feature preserved" "$TMPDIR/HUMAN_NOTES.md" '^\- \[ \] \[FEAT\] Open feature'
assert_file_contains "Section headers preserved" "$TMPDIR/HUMAN_NOTES.md" '^## Bugs'

# ============================================================================
# Test 2: clear_completed_human_notes is no-op when no [x] items
# ============================================================================
echo ""
echo "--- Test 2: HUMAN_NOTES.md no-op when no completed items ---"

cat > "$TMPDIR/HUMAN_NOTES.md" << 'EOF'
# Human Notes

## Bugs
- [ ] [BUG] Open bug
EOF

local_before=$(cat "$TMPDIR/HUMAN_NOTES.md")
clear_completed_human_notes
local_after=$(cat "$TMPDIR/HUMAN_NOTES.md")

assert_eq "File unchanged when no [x] items" "$local_before" "$local_after"

# ============================================================================
# Test 3: clear_completed_human_notes is no-op when file missing
# ============================================================================
echo ""
echo "--- Test 3: HUMAN_NOTES.md no-op when file missing ---"

rm -f "$TMPDIR/HUMAN_NOTES.md"
clear_completed_human_notes
# If we get here without error, it passed
echo "✓ PASS: No error when HUMAN_NOTES.md missing"
PASS=$((PASS + 1))

# ============================================================================
# Test 4: clear_resolved_nonblocking_notes clears Resolved section
# ============================================================================
echo ""
echo "--- Test 4: NON_BLOCKING_LOG.md Resolved section cleanup ---"

cat > "$TMPDIR/NON_BLOCKING_LOG.md" << 'EOF'
# Non-Blocking Notes Log

## Open
- [ ] [2026-03-29 | "task"] Open note one
- [ ] [2026-03-29 | "task"] Open note two

## Resolved
- [x] Fixed item A
- [x] Fixed item B
- [x] Fixed item C
EOF

clear_resolved_nonblocking_notes > /dev/null

assert_file_contains "Open note one preserved" "$TMPDIR/NON_BLOCKING_LOG.md" 'Open note one'
assert_file_contains "Open note two preserved" "$TMPDIR/NON_BLOCKING_LOG.md" 'Open note two'
assert_file_not_contains "Resolved items removed" "$TMPDIR/NON_BLOCKING_LOG.md" '^- \[x\] Fixed item'
assert_file_contains "Resolved heading preserved" "$TMPDIR/NON_BLOCKING_LOG.md" '^## Resolved'

# ============================================================================
# Test 5: clear_resolved_drift_observations clears DRIFT_LOG Resolved
# ============================================================================
echo ""
echo "--- Test 5: DRIFT_LOG.md Resolved section cleanup ---"

cat > "$TMPDIR/DRIFT_LOG.md" << 'EOF'
# Drift Log

## Unresolved Observations
- [2026-03-29 | "task"] Unresolved observation

## Resolved
- [RESOLVED 2026-03-28] Old resolved item
- [RESOLVED 2026-03-27] Another resolved item

## Runs Since Last Audit
3
EOF

clear_resolved_drift_observations

assert_file_contains "Unresolved observation preserved" "$TMPDIR/DRIFT_LOG.md" 'Unresolved observation'
assert_file_not_contains "Resolved items removed" "$TMPDIR/DRIFT_LOG.md" 'Old resolved item'
assert_file_not_contains "Second resolved item removed" "$TMPDIR/DRIFT_LOG.md" 'Another resolved item'
assert_file_contains "Resolved heading preserved" "$TMPDIR/DRIFT_LOG.md" '^## Resolved'

# ============================================================================
# Test 6: Combined cleanup of all three files
# ============================================================================
echo ""
echo "--- Test 6: Combined cleanup of all three log files ---"

cat > "$TMPDIR/HUMAN_NOTES.md" << 'EOF'
# Human Notes
- [x] [BUG] Done
- [ ] [BUG] Still open
EOF

cat > "$TMPDIR/NON_BLOCKING_LOG.md" << 'EOF'
# Non-Blocking Notes Log

## Open
- [x] [2026-03-29 | "task"] Completed open note
- [ ] [2026-03-29 | "task"] Still open note

## Resolved
- [x] Resolved entry
EOF

cat > "$TMPDIR/DRIFT_LOG.md" << 'EOF'
# Drift Log

## Unresolved Observations
- [2026-03-29 | "task"] Still unresolved

## Resolved
- [RESOLVED 2026-03-28] Done drift entry
EOF

# Run all four cleanup functions in startup order
clear_completed_nonblocking_notes
clear_resolved_drift_observations
clear_completed_human_notes
clear_resolved_nonblocking_notes > /dev/null

assert_file_not_contains "HUMAN_NOTES: no [x]" "$TMPDIR/HUMAN_NOTES.md" '^\- \[x\]'
assert_file_contains "HUMAN_NOTES: [ ] preserved" "$TMPDIR/HUMAN_NOTES.md" 'Still open'
assert_file_not_contains "NB_LOG: no [x] in Open" "$TMPDIR/NON_BLOCKING_LOG.md" '^\- \[x\]'
assert_file_contains "NB_LOG: [ ] in Open preserved" "$TMPDIR/NON_BLOCKING_LOG.md" 'Still open note'
assert_file_not_contains "NB_LOG: Resolved entries gone" "$TMPDIR/NON_BLOCKING_LOG.md" 'Resolved entry'
assert_file_contains "DRIFT: unresolved preserved" "$TMPDIR/DRIFT_LOG.md" 'Still unresolved'
assert_file_not_contains "DRIFT: resolved gone" "$TMPDIR/DRIFT_LOG.md" 'Done drift entry'

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Test Results:"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

exit 0
