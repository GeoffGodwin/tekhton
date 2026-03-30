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
REVIEWER_MIN_TURNS=10
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
source "${TEKHTON_HOME}/lib/metrics.sh"
source "${TEKHTON_HOME}/lib/metrics_calibration.sh"
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

# 2b: Report with bold-formatted fields (common LLM format drift)
cat > "${TMPDIR}/BOLD_SCOUT.md" << 'EOF'
## Relevant Files
- lib/foo.dart — some file

## Complexity Estimate

**Files to modify:** 4
**Estimated lines of change:** 250
**Interconnected systems:** medium
**Recommended coder turns:** 45
**Recommended reviewer turns:** 10
**Recommended tester turns:** 35
EOF

if parse_scout_complexity "${TMPDIR}/BOLD_SCOUT.md"; then
    assert_eq "2b.1 bold files_to_modify" "4" "$SCOUT_FILES_TO_MODIFY"
    assert_eq "2b.2 bold lines_of_change" "250" "$SCOUT_LINES_OF_CHANGE"
    assert_eq "2b.3 bold interconnected" "medium" "$SCOUT_INTERCONNECTED"
    assert_eq "2b.4 bold rec_coder_turns" "45" "$SCOUT_REC_CODER_TURNS"
    assert_eq "2b.5 bold rec_reviewer_turns" "10" "$SCOUT_REC_REVIEWER_TURNS"
    assert_eq "2b.6 bold rec_tester_turns" "35" "$SCOUT_REC_TESTER_TURNS"
else
    echo "FAIL: 2b.0 parse_scout_complexity should handle bold formatting"
    FAIL=1
fi

# 2c: Report with range values (e.g. "25-30")
cat > "${TMPDIR}/RANGE_SCOUT.md" << 'EOF'
## Complexity Estimate
**Files to modify:** 4
**Estimated lines of change:** 200-270
**Interconnected systems:** medium
**Recommended coder turns:** 25-30
**Recommended reviewer turns:** 5-8
**Recommended tester turns:** 15-20
EOF

if parse_scout_complexity "${TMPDIR}/RANGE_SCOUT.md"; then
    assert_eq "2c.1 range files_to_modify" "4" "$SCOUT_FILES_TO_MODIFY"
    assert_eq "2c.2 range lines first number" "200" "$SCOUT_LINES_OF_CHANGE"
    assert_eq "2c.3 range interconnected" "medium" "$SCOUT_INTERCONNECTED"
    assert_eq "2c.4 range rec_coder_turns first" "25" "$SCOUT_REC_CODER_TURNS"
    assert_eq "2c.5 range rec_reviewer_turns first" "5" "$SCOUT_REC_REVIEWER_TURNS"
    assert_eq "2c.6 range rec_tester_turns first" "15" "$SCOUT_REC_TESTER_TURNS"
else
    echo "FAIL: 2c.0 parse_scout_complexity should handle range values"
    FAIL=1
fi

# 2d: Report with bullet-prefixed fields
cat > "${TMPDIR}/BULLET_SCOUT.md" << 'EOF'
## Complexity Estimate
- Files to modify: 6
- Estimated lines of change: 300
- Interconnected systems: high
- Recommended coder turns: 60
- Recommended reviewer turns: 12
- Recommended tester turns: 40
EOF

if parse_scout_complexity "${TMPDIR}/BULLET_SCOUT.md"; then
    assert_eq "2d.1 bullet files_to_modify" "6" "$SCOUT_FILES_TO_MODIFY"
    assert_eq "2d.2 bullet rec_coder_turns" "60" "$SCOUT_REC_CODER_TURNS"
else
    echo "FAIL: 2d.0 parse_scout_complexity should handle bullet prefixes"
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

# Scout recommends below config default — floor kicks in (never reduce below configured default)
assert_eq "4.4 coder floored to config default" "35" "$ADJUSTED_CODER_TURNS"
assert_eq "4.5 reviewer clamped to min" "10" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "4.6 tester floored to config default" "30" "$ADJUSTED_TESTER_TURNS"

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
# Phase 6: estimate_post_coder_turns — formula + fallback heuristic
# =============================================================================

# 6.1: Fallback heuristic — small change, no actual turns (e.g., --start-at review)
SCOUT_REC_REVIEWER_TURNS=0

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

# No actual_coder_turns → falls back to heuristic
estimate_post_coder_turns 0 2>/dev/null

# Should be the small-change heuristic, floored to config defaults (reviewer=15, tester=30)
assert_eq "6.1 fallback small reviewer" "15" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "6.2 fallback small tester" "30" "$ADJUSTED_TESTER_TURNS"

# 6.3: Formula with actual_coder_turns=50, files=2
# reviewer = max(10, 50*0.35 + 2*1.5) = max(10, 17+3) = 20
# tester   = max(10, 50*0.5 + 2*2.0) = max(10, 25+4) = 29
estimate_post_coder_turns 50 2>/dev/null
assert_eq "6.3 formula reviewer (50 turns, 2 files)" "20" "$ADJUSTED_REVIEWER_TURNS"
# Formula gives 29, but floor is TESTER_MAX_TURNS=30
assert_eq "6.4 formula tester (50 turns, 2 files)" "30" "$ADJUSTED_TESTER_TURNS"

# 6.5: Formula overrides scout values (the whole point of Milestone 9)
SCOUT_REC_REVIEWER_TURNS=15
estimate_post_coder_turns 50 2>/dev/null
assert_eq "6.5 formula overrides scout reviewer" "20" "$ADJUSTED_REVIEWER_TURNS"
SCOUT_REC_REVIEWER_TURNS=0

# 6.6: Formula with large turns — clamped to max
# reviewer = 300*0.35 + 2*1.5 = 105+3 = 108 → clamped to 30
# tester   = 300*0.5  + 2*2.0 = 150+4 = 154 → clamped to 100
estimate_post_coder_turns 300 2>/dev/null
assert_eq "6.6 formula clamped reviewer max" "30" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "6.7 formula clamped tester max" "100" "$ADJUSTED_TESTER_TURNS"

# 6.8: Formula with small turns — clamped to min, then floored to config default
# reviewer = 5*0.35 + 2*1.5 = 1+3 = 4 → clamped to REVIEWER_MIN_TURNS=10 → floor REVIEWER_MAX_TURNS=10
# tester   = 5*0.5  + 2*2.0 = 2+4 = 6 → clamped to TESTER_MIN_TURNS=10 → floor TESTER_MAX_TURNS=30
estimate_post_coder_turns 5 2>/dev/null
assert_eq "6.8 formula clamped reviewer min" "10" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "6.9 formula clamped tester floored to config" "30" "$ADJUSTED_TESTER_TURNS"

# 6.10: Formula with many files
cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## Files Modified
- lib/a.dart
- lib/b.dart
- lib/c.dart
- lib/d.dart
- lib/e.dart
- lib/f.dart
- lib/g.dart
- lib/h.dart
- lib/i.dart
- lib/j.dart
EOF

# reviewer = 40*0.35 + 10*1.5 = 14+15 = 29
# tester   = 40*0.5  + 10*2.0 = 20+20 = 40
estimate_post_coder_turns 40 2>/dev/null
assert_eq "6.10 formula many files reviewer" "29" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "6.11 formula many files tester" "40" "$ADJUSTED_TESTER_TURNS"

# 6.12: Dynamic turns disabled — uses defaults regardless
DYNAMIC_TURNS_ENABLED=false
# Clear adjusted values so the disabled path falls through to defaults
unset ADJUSTED_REVIEWER_TURNS ADJUSTED_TESTER_TURNS
estimate_post_coder_turns 50 2>/dev/null
assert_eq "6.12 disabled reviewer uses default" "$REVIEWER_MAX_TURNS" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "6.13 disabled tester uses default" "$TESTER_MAX_TURNS" "$ADJUSTED_TESTER_TURNS"
DYNAMIC_TURNS_ENABLED=true

# 6.14: Absent CODER_SUMMARY.md — files_modified defaults to 0 in formula path
# reviewer = 50*35/100 + 0*15/10 = 17 → floor REVIEWER_MAX_TURNS=10 → 17
# tester   = 50*50/100 + 0*20/10 = 25 → floor TESTER_MAX_TURNS=30 → 30
DYNAMIC_TURNS_ENABLED=true
rm -f "${TMPDIR}/CODER_SUMMARY.md"
estimate_post_coder_turns 50 2>/dev/null
assert_eq "6.14 absent summary: reviewer with files=0" "17" "$ADJUSTED_REVIEWER_TURNS"
assert_eq "6.15 absent summary: tester with files=0" "30" "$ADJUSTED_TESTER_TURNS"

# Restore small coder summary for remaining tests
cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## Files Modified
- lib/foo.dart
- lib/bar.dart
EOF

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
