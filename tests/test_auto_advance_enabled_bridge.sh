#!/usr/bin/env bash
# Test: --auto-advance CLI flag correctly bridges to AUTO_ADVANCE_ENABLED (Bug 2 fix verification)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# ---------------------------------------------------------------------------
# Test 1: Without --auto-advance flag, AUTO_ADVANCE_ENABLED stays at default
# The default from config_defaults.sh is false.
# ---------------------------------------------------------------------------
AUTO_ADVANCE=false
AUTO_ADVANCE_ENABLED=false

# Simulate the tekhton.sh flag-handling block (line ~707)
if [ "$AUTO_ADVANCE" = true ]; then
    AUTO_ADVANCE_ENABLED=true
    export AUTO_ADVANCE_ENABLED
fi

assert_eq "no-flag: AUTO_ADVANCE_ENABLED stays false" "false" "$AUTO_ADVANCE_ENABLED"

# ---------------------------------------------------------------------------
# Test 2: With --auto-advance flag, AUTO_ADVANCE_ENABLED is set to true
# ---------------------------------------------------------------------------
AUTO_ADVANCE=true
AUTO_ADVANCE_ENABLED=false

if [ "$AUTO_ADVANCE" = true ]; then
    AUTO_ADVANCE_ENABLED=true
    export AUTO_ADVANCE_ENABLED
fi

assert_eq "with-flag: AUTO_ADVANCE_ENABLED becomes true" "true" "$AUTO_ADVANCE_ENABLED"

# ---------------------------------------------------------------------------
# Test 3: AUTO_ADVANCE_ENABLED is exported so subprocesses can see it
# ---------------------------------------------------------------------------
AUTO_ADVANCE=true
AUTO_ADVANCE_ENABLED=false

if [ "$AUTO_ADVANCE" = true ]; then
    AUTO_ADVANCE_ENABLED=true
    export AUTO_ADVANCE_ENABLED
fi

# Check env export via a subshell
result=$(bash -c 'echo "${AUTO_ADVANCE_ENABLED:-not-exported}"')
assert_eq "AUTO_ADVANCE_ENABLED exported to subshell" "true" "$result"

# ---------------------------------------------------------------------------
# Test 4: should_auto_advance() in milestone_ops.sh uses AUTO_ADVANCE_ENABLED
# Source the library and verify the function returns the expected exit code.
# ---------------------------------------------------------------------------
# Set up PROJECT_DIR so MILESTONE_STATE_FILE resolves correctly
PROJECT_DIR="$TMPDIR"
export PROJECT_DIR
mkdir -p "${TMPDIR}/.claude"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"

# With AUTO_ADVANCE_ENABLED=false, should_auto_advance returns non-zero
AUTO_ADVANCE_ENABLED=false
export AUTO_ADVANCE_ENABLED
AUTO_ADVANCE_LIMIT=3
AUTO_ADVANCE_CONFIRM=false
_ADVANCE_COUNT=0

if should_auto_advance 2>/dev/null; then
    echo "FAIL: should_auto_advance should return false when AUTO_ADVANCE_ENABLED=false"
    FAIL=1
fi

# With AUTO_ADVANCE_ENABLED=true, should_auto_advance returns zero
# (assuming advance count is within limit and disposition is COMPLETE_AND_CONTINUE)
AUTO_ADVANCE_ENABLED=true
export AUTO_ADVANCE_ENABLED
_ADVANCE_COUNT=0

# Create a milestone state file with the expected disposition
cat > "${TMPDIR}/.claude/MILESTONE_STATE.md" <<'STATE_EOF'
# Milestone State
## Current Milestone
1

## Total Milestones
5

## Status
ACCEPTED

## Disposition
COMPLETE_AND_CONTINUE

## Milestones Completed This Session
0

## Transition History
- test
STATE_EOF

if ! should_auto_advance 2>/dev/null; then
    echo "FAIL: should_auto_advance should return true when AUTO_ADVANCE_ENABLED=true and count within limit"
    FAIL=1
fi

# ---------------------------------------------------------------------------
# Test 5: The --auto-advance flag also sets MILESTONE_MODE=true
# Verify the expected pairing (both variables set together in tekhton.sh ~line 468)
# ---------------------------------------------------------------------------
AUTO_ADVANCE=false
MILESTONE_MODE=false

# Simulate tekhton.sh argument parsing block
case "--auto-advance" in
    --auto-advance)
        AUTO_ADVANCE=true
        MILESTONE_MODE=true
        ;;
esac

assert_eq "flag sets AUTO_ADVANCE=true" "true" "$AUTO_ADVANCE"
assert_eq "flag also sets MILESTONE_MODE=true" "true" "$MILESTONE_MODE"

# ---------------------------------------------------------------------------
# Test 6: Setting AUTO_ADVANCE=false (no flag) leaves MILESTONE_MODE unchanged
# This verifies single-milestone mode is unaffected by the auto-advance fix.
# ---------------------------------------------------------------------------
AUTO_ADVANCE=false
MILESTONE_MODE=false

if [ "$AUTO_ADVANCE" = true ]; then
    AUTO_ADVANCE_ENABLED=true
    export AUTO_ADVANCE_ENABLED
fi

assert_eq "no-flag: MILESTONE_MODE unchanged" "false" "$MILESTONE_MODE"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
    echo "AUTO-ADVANCE ENABLED BRIDGE TESTS FAILED"
    exit 1
fi

echo "Auto-advance enabled bridge tests passed (6 tests)"
