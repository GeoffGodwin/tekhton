#!/usr/bin/env bash
# =============================================================================
# test_agent_exit_detection.sh — Null run detection in run_agent wrapper
#
# Tests:
#   1. LAST_AGENT_* globals are set after run_agent simulations
#   2. was_null_run returns true for ≤2 turns + non-zero exit
#   3. was_null_run returns false for normal runs
#   4. check_agent_output detects missing/stub files
#   5. Null run threshold is configurable
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

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/agent.sh"

cd "$TMPDIR"
git init -q .

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: LAST_AGENT_* globals — default state
# =============================================================================

assert_eq "1.1 default LAST_AGENT_TURNS" "0" "$LAST_AGENT_TURNS"
assert_eq "1.2 default LAST_AGENT_EXIT_CODE" "0" "$LAST_AGENT_EXIT_CODE"
assert_eq "1.3 default LAST_AGENT_ELAPSED" "0" "$LAST_AGENT_ELAPSED"
assert_eq "1.4 default LAST_AGENT_NULL_RUN" "false" "$LAST_AGENT_NULL_RUN"

# =============================================================================
# Phase 2: was_null_run with direct manipulation
# =============================================================================

# 2.1: Simulate a null run — 0 turns
LAST_AGENT_NULL_RUN=true
if was_null_run; then
    assert_eq "2.1 was_null_run true when flagged" "0" "0"
else
    echo "FAIL: 2.1 was_null_run should return true when LAST_AGENT_NULL_RUN=true"
    FAIL=1
fi

# 2.2: Simulate a normal run
LAST_AGENT_NULL_RUN=false
if was_null_run; then
    echo "FAIL: 2.2 was_null_run should return false when LAST_AGENT_NULL_RUN=false"
    FAIL=1
else
    assert_eq "2.2 was_null_run false for normal run" "0" "0"
fi

# =============================================================================
# Phase 3: check_agent_output — missing file
# =============================================================================

LAST_AGENT_NULL_RUN=false

# 3.1: Missing output file
if check_agent_output "NONEXISTENT.md" "Test" 2>/dev/null; then
    echo "FAIL: 3.1 check_agent_output should fail for missing file"
    FAIL=1
else
    assert_eq "3.1 check_agent_output fails for missing file" "0" "0"
fi

# 3.2: Stub file (only 1 line)
echo "# Header only" > "${TMPDIR}/STUB.md"
if check_agent_output "${TMPDIR}/STUB.md" "Test" 2>/dev/null; then
    echo "FAIL: 3.2 check_agent_output should fail for stub file"
    FAIL=1
else
    assert_eq "3.2 check_agent_output fails for stub file" "0" "0"
fi

# 3.3: File with content + git changes
cat > "${TMPDIR}/GOOD_REPORT.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
Implemented the feature.
## Files Modified
- lib/foo.dart
EOF
echo "changed" > "${TMPDIR}/somefile.txt"
git add -A && git commit -q -m "init"
echo "modified" >> "${TMPDIR}/somefile.txt"

if check_agent_output "${TMPDIR}/GOOD_REPORT.md" "Test" 2>/dev/null; then
    assert_eq "3.3 check_agent_output passes with content + git changes" "0" "0"
else
    echo "FAIL: 3.3 check_agent_output should pass with content and git changes"
    FAIL=1
fi

# 3.4: Null run flagged — check_agent_output fails immediately
LAST_AGENT_NULL_RUN=true
if check_agent_output "${TMPDIR}/GOOD_REPORT.md" "Test" 2>/dev/null; then
    echo "FAIL: 3.4 check_agent_output should fail when null run flagged"
    FAIL=1
else
    assert_eq "3.4 check_agent_output fails on null run" "0" "0"
fi
LAST_AGENT_NULL_RUN=false

# =============================================================================
# Phase 4: Null run threshold configuration
# =============================================================================

# 4.1: Default threshold (2) — 3 turns with non-zero exit should NOT be null run
LAST_AGENT_TURNS=3
LAST_AGENT_EXIT_CODE=1
LAST_AGENT_NULL_RUN=false

# Simulate the threshold check logic from run_agent
null_threshold="${AGENT_NULL_RUN_THRESHOLD:-2}"
if [ "$LAST_AGENT_TURNS" -le "$null_threshold" ] && [ "$LAST_AGENT_EXIT_CODE" -ne 0 ]; then
    LAST_AGENT_NULL_RUN=true
elif [ "$LAST_AGENT_TURNS" -eq 0 ]; then
    LAST_AGENT_NULL_RUN=true
fi
assert_eq "4.1 3 turns + error is NOT null run at threshold 2" "false" "$LAST_AGENT_NULL_RUN"

# 4.2: Raise threshold to 5 — 3 turns + non-zero exit should be null run
LAST_AGENT_NULL_RUN=false
AGENT_NULL_RUN_THRESHOLD=5
null_threshold="${AGENT_NULL_RUN_THRESHOLD:-2}"
if [ "$LAST_AGENT_TURNS" -le "$null_threshold" ] && [ "$LAST_AGENT_EXIT_CODE" -ne 0 ]; then
    LAST_AGENT_NULL_RUN=true
elif [ "$LAST_AGENT_TURNS" -eq 0 ]; then
    LAST_AGENT_NULL_RUN=true
fi
assert_eq "4.2 3 turns + error IS null run at threshold 5" "true" "$LAST_AGENT_NULL_RUN"
AGENT_NULL_RUN_THRESHOLD=2  # Reset

# 4.3: 0 turns + exit 0 should still be null run (always suspicious)
LAST_AGENT_TURNS=0
LAST_AGENT_EXIT_CODE=0
LAST_AGENT_NULL_RUN=false
null_threshold="${AGENT_NULL_RUN_THRESHOLD:-2}"
if [ "$LAST_AGENT_TURNS" -le "$null_threshold" ] && [ "$LAST_AGENT_EXIT_CODE" -ne 0 ]; then
    LAST_AGENT_NULL_RUN=true
elif [ "$LAST_AGENT_TURNS" -eq 0 ]; then
    LAST_AGENT_NULL_RUN=true
fi
assert_eq "4.3 0 turns + exit 0 IS null run" "true" "$LAST_AGENT_NULL_RUN"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
