#!/usr/bin/env bash
# =============================================================================
# test_dynamic_turn_limits.sh — Scout-driven turn limit estimation
#
# Tests:
#   1. clamp_turns clamps values to [min, max]
#   2. parse_scout_complexity extracts fields from scout report
#   3. parse_scout_complexity returns 1 when no report/section exists
#   4. apply_scout_turn_limits applies clamped recommendations
#   5. apply_scout_turn_limits falls back to defaults when disabled
#   6. estimate_post_coder_turns estimates from file count / diff size
#   7. Milestone mode caps override dynamic limits correctly
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Minimal pipeline globals ------------------------------------------------
PROJECT_DIR="$TMPDIR"
PROJECT_NAME="test-project"
LOG_DIR="${TMPDIR}/logs"
mkdir -p "$LOG_DIR"

# Simulate loaded config values
CODER_MAX_TURNS=35
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=30
CODER_MIN_TURNS=15
CODER_MAX_TURNS_CAP=200
REVIEWER_MIN_TURNS=5
REVIEWER_MAX_TURNS_CAP=30
TESTER_MIN_TURNS=10
TESTER_MAX_TURNS_CAP=100
DYNAMIC_TURNS_ENABLED=true
AGENT_NULL_RUN_THRESHOLD=2

# Agent globals needed by turns.sh
LAST_AGENT_TURNS=0
LAST_AGENT_EXIT_CODE=0
LAST_AGENT_ELAPSED=0
LAST_AGENT_NULL_RUN=false
TOTAL_TURNS=0
TOTAL_TIME=0
STAGE_SUMMARY=""

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/agent.sh"
source "${TEKHTON_HOME}/lib/turns.sh"

cd "$TMPDIR"
git init -q .
echo "init" > init.txt && git add -A && git commit -q -m "init"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: clamp_turns
# =============================================================================

assert_eq "1.1 clamp within range" "50" "$(clamp_turns 50 10 100)"
assert_eq "1.2 clamp below min" "10" "$(clamp_turns 5 10 100)"
assert_eq "1.3 clamp above max" "100" "$(clamp_turns 150 10 100)"
assert_eq "1.4 clamp at min" "10" "$(clamp_turns 10 10 100)"
assert_eq "1.5 clamp at max" "100" "$(clamp_turns 100 10 100)"

# =============================================================================
# Phase 2: parse_scout_complexity — valid report
# =============================================================================

cat > "${TMPDIR}/SCOUT_REPORT.md" << 'EOF'
## Relevant Files
- lib/engine/rules/move_validator.dart — validates card moves
- lib/engine/state/game_state.dart — game state model

## Key Symbols
- MoveValidator / validateMove — move_validator.dart

## Suspected Root Cause Areas
- MoveValidator doesn't check stack size correctly

## Complexity Estimate
Files to modify: 5
Estimated lines of change: 200
Interconnected systems: medium
Recommended coder turns: 40
Recommended reviewer turns: 10
Recommended tester turns: 30
EOF

if parse_scout_complexity "${TMPDIR}/SCOUT_REPORT.md"; then
    assert_eq "2.1 files_to_modify" "5" "$SCOUT_FILES_TO_MODIFY"
    assert_eq "2.2 lines_of_change" "200" "$SCOUT_LINES_OF_CHANGE"
    assert_eq "2.3 interconnected" "medium" "$SCOUT_INTERCONNECTED"
    assert_eq "2.4 rec_coder_turns" "40" "$SCOUT_REC_CODER_TURNS"
    assert_eq "2.5 rec_reviewer_turns" "10" "$SCOUT_REC_REVIEWER_TURNS"
    assert_eq "2.6 rec_tester_turns" "30" "$SCOUT_REC_TESTER_TURNS"
else
    echo "FAIL: 2.0 parse_scout_complexity should return 0 for valid report"
    FAIL=1
fi

# =============================================================================
# Phase 3: parse_scout_complexity — missing/invalid reports
# =============================================================================

# 3.1: No file
if parse_scout_complexity "${TMPDIR}/NONEXISTENT.md" 2>/dev/null; then
    echo "FAIL: 3.1 parse_scout_complexity should fail for missing file"
    FAIL=1
else
    assert_eq "3.1 missing file returns 1" "0" "0"
fi

# 3.2: File without complexity section
cat > "${TMPDIR}/MINIMAL_SCOUT.md" << 'EOF'
## Relevant Files
- lib/foo.dart — some file
EOF

if parse_scout_complexity "${TMPDIR}/MINIMAL_SCOUT.md" 2>/dev/null; then
    echo "FAIL: 3.2 parse_scout_complexity should fail for report without complexity section"
    FAIL=1
else
    assert_eq "3.2 no complexity section returns 1" "0" "0"
fi

# 3.3: Complexity section with 0 for coder turns
cat > "${TMPDIR}/ZERO_SCOUT.md" << 'EOF'
## Complexity Estimate
Files to modify: 3
Estimated lines of change: 50
Interconnected systems: low
Recommended coder turns: 0
Recommended reviewer turns: 5
Recommended tester turns: 10
EOF

if parse_scout_complexity "${TMPDIR}/ZERO_SCOUT.md" 2>/dev/null; then
    echo "FAIL: 3.3 parse_scout_complexity should fail for 0 coder turns"
    FAIL=1
else
    assert_eq "3.3 zero coder turns returns 1" "0" "0"
fi

# =============================================================================
# Phase 4: apply_scout_turn_limits — applies clamped recommendations
# =============================================================================

cat > "${TMPDIR}/SCOUT_REPORT.md" << 'EOF'
## Complexity Estimate
Files to modify: 12
Estimated lines of change: 800
Interconnected systems: high
Recommended coder turns: 80
Recommended reviewer turns: 15
Recommended tester turns: 50
EOF

DYNAMIC_TURNS_ENABLED=true
apply_scout_turn_limits "${TMPDIR}/SCOUT_REPORT.md" 2>/dev/null

assert_eq "4.1 coder turns applied" "80" "$ADJUSTED_CODER_TURNS"
assert_eq "4.2 reviewer turns applied" "15" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "4.3 tester turns applied" "50" "$ADJUSTED_TESTER_TURNS"

# 4.4: Recommendation below minimum
cat > "${TMPDIR}/SCOUT_REPORT.md" << 'EOF'
## Complexity Estimate
Files to modify: 1
Estimated lines of change: 10
Interconnected systems: low
Recommended coder turns: 5
Recommended reviewer turns: 3
Recommended tester turns: 4
EOF

apply_scout_turn_limits "${TMPDIR}/SCOUT_REPORT.md" 2>/dev/null

assert_eq "4.4 coder clamped to min" "15" "$ADJUSTED_CODER_TURNS"
assert_eq "4.5 reviewer clamped to min" "5" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "4.6 tester clamped to min" "10" "$ADJUSTED_TESTER_TURNS"

# 4.7: Recommendation above maximum
cat > "${TMPDIR}/SCOUT_REPORT.md" << 'EOF'
## Complexity Estimate
Files to modify: 50
Estimated lines of change: 5000
Interconnected systems: high
Recommended coder turns: 500
Recommended reviewer turns: 100
Recommended tester turns: 300
EOF

apply_scout_turn_limits "${TMPDIR}/SCOUT_REPORT.md" 2>/dev/null

assert_eq "4.7 coder clamped to max" "200" "$ADJUSTED_CODER_TURNS"
assert_eq "4.8 reviewer clamped to max" "30" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "4.9 tester clamped to max" "100" "$ADJUSTED_TESTER_TURNS"

# =============================================================================
# Phase 5: apply_scout_turn_limits — disabled
# =============================================================================

DYNAMIC_TURNS_ENABLED=false
apply_scout_turn_limits "${TMPDIR}/SCOUT_REPORT.md" 2>/dev/null

assert_eq "5.1 disabled: coder uses default" "$CODER_MAX_TURNS" "$ADJUSTED_CODER_TURNS"
assert_eq "5.2 disabled: reviewer uses default" "$REVIEWER_MAX_TURNS" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "5.3 disabled: tester uses default" "$TESTER_MAX_TURNS" "$ADJUSTED_TESTER_TURNS"

DYNAMIC_TURNS_ENABLED=true

# =============================================================================
# Phase 6: estimate_post_coder_turns — heuristic from files/diff
# =============================================================================

# 6.1: Small change — few files, small diff
SCOUT_REC_REVIEWER_TURNS=0  # Reset so estimate_post_coder_turns runs its heuristic

cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
Fixed the bug.
## Files Modified
- lib/foo.dart
- lib/bar.dart
EOF

# Create a small diff
echo "small change" >> "${TMPDIR}/init.txt"

estimate_post_coder_turns 2>/dev/null

# Should be the small-change estimate (reviewer ~8, tester ~20)
assert_eq "6.1 small change reviewer" "8" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "6.2 small change tester" "20" "$ADJUSTED_TESTER_TURNS"

# 6.3: When scout already set values, don't override
SCOUT_REC_REVIEWER_TURNS=15
estimate_post_coder_turns 2>/dev/null
assert_eq "6.3 scout values preserved" "8" "$ADJUSTED_REVIEWER_TURNS"

# Reset for future tests
SCOUT_REC_REVIEWER_TURNS=0

# =============================================================================
# Phase 7: apply_scout_turn_limits — no scout report falls back to defaults
# =============================================================================

rm -f "${TMPDIR}/SCOUT_REPORT.md"
apply_scout_turn_limits "${TMPDIR}/SCOUT_REPORT.md" 2>/dev/null

assert_eq "7.1 no report: coder uses default" "$CODER_MAX_TURNS" "$ADJUSTED_CODER_TURNS"
assert_eq "7.2 no report: reviewer uses default" "$REVIEWER_MAX_TURNS" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "7.3 no report: tester uses default" "$TESTER_MAX_TURNS" "$ADJUSTED_TESTER_TURNS"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
