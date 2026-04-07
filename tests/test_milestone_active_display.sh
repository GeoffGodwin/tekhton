#!/usr/bin/env bash
# =============================================================================
# test_milestone_active_display.sh — Regression test for milestone "Active"
#                                     status display in Watchtower dashboard
#
# Verifies that when emit_milestone_metadata() sets "in_progress" status,
# followed by emit_dashboard_milestones(), the generated milestones.js
# file reflects the correct "in_progress" status before finalization.
# This is a regression test for the bug where milestones remained in the
# READY column without ever showing in the ACTIVE column.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals that functions expect ---
PROJECT_DIR="$TMPDIR"
DASHBOARD_DIR=".claude/dashboard"
MILESTONE_DIR="${TMPDIR}/.claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_DAG_ENABLED=true
PROJECT_RULES_FILE="${TMPDIR}/CLAUDE.md"
LOG_FILE="$TMPDIR/test.log"

export PROJECT_DIR DASHBOARD_DIR MILESTONE_DIR MILESTONE_MANIFEST
export MILESTONE_DAG_ENABLED PROJECT_RULES_FILE LOG_FILE

mkdir -p "$MILESTONE_DIR" "$TMPDIR/.claude/dashboard/data"
touch "$LOG_FILE"

# --- Source dependencies ---
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/causality.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_io.sh"
source "${TEKHTON_HOME}/lib/dashboard.sh"
source "${TEKHTON_HOME}/lib/dashboard_emitters.sh"
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# --- Test helpers ---
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — did not find '$needle' in output"
        FAIL=$((FAIL + 1))
    fi
}

# --- Test Suite 1: Milestone Active Status Display ---
echo "=== Test Suite 1: Milestone Active Status Display ==="

# Create a milestone manifest with test milestones
cat > "$MILESTONE_DIR/$MILESTONE_MANIFEST" << 'MANIFEST'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Test Milestone 1|pending||test_m01.md|
m02|Test Milestone 2|pending|m01|test_m02.md|
MANIFEST

# Create milestone files with basic content
cat > "$MILESTONE_DIR/test_m01.md" << 'MS01'
# Milestone 1: Test Milestone 1

Test content for milestone 1

## Acceptance Criteria
- [ ] Item 1
- [ ] Item 2
MS01

cat > "$MILESTONE_DIR/test_m02.md" << 'MS02'
# Milestone 2: Test Milestone 2

Test content for milestone 2

## Acceptance Criteria
- [ ] Item 1
MS02

# Initialize the DAG system
_DAG_LOADED=false
load_manifest

# Test 1.1: Set m01 to "in_progress"
echo "Test 1.1: Setting milestone m01 to in_progress..."
dag_set_status "m01" "in_progress"
save_manifest

# Test 1.2: Verify manifest was updated
manifest_content=$(cat "$MILESTONE_DIR/$MILESTONE_MANIFEST")
assert_contains "1.2 manifest contains in_progress for m01" "$manifest_content" "m01.*in_progress"

# Test 1.3: Generate dashboard data
echo "Test 1.3: Generating dashboard milestones data..."
emit_dashboard_milestones

# Test 1.4: Check that milestones.js was created
if [[ -f "$TMPDIR/.claude/dashboard/data/milestones.js" ]]; then
    echo "  PASS: milestones.js file was created"
    PASS=$((PASS + 1))
else
    echo "  FAIL: milestones.js file was not created"
    FAIL=$((FAIL + 1))
fi

# Test 1.5: Verify milestones.js contains the "in_progress" status
milestones_js=$(cat "$TMPDIR/.claude/dashboard/data/milestones.js" 2>/dev/null || echo "")
assert_contains "1.5 milestones.js contains in_progress status" "$milestones_js" "in_progress"

# Test 1.6: Verify m01 appears with in_progress status (extract JSON)
# The milestones.js file should have window.TK_MILESTONES = [...]
if echo "$milestones_js" | grep -q '"id":"m01".*"status":"in_progress"'; then
    echo "  PASS: milestones.js has correct m01 in_progress status"
    PASS=$((PASS + 1))
else
    echo "  FAIL: milestones.js does not have m01 with in_progress status"
    FAIL=$((FAIL + 1))
fi

# Test 1.7: Verify m02 remains in pending status
if echo "$milestones_js" | grep -q '"id":"m02".*"status":"pending"'; then
    echo "  PASS: milestones.js has correct m02 pending status"
    PASS=$((PASS + 1))
else
    echo "  FAIL: milestones.js does not have m02 with pending status"
    FAIL=$((FAIL + 1))
fi

# --- Test Suite 2: Status Transitions ---
echo "=== Test Suite 2: Status Transitions ==="

# Test 2.1: Transition m01 to "done"
echo "Test 2.1: Transitioning m01 to done..."
dag_set_status "m01" "done"
save_manifest

# Regenerate dashboard
emit_dashboard_milestones
milestones_js=$(cat "$TMPDIR/.claude/dashboard/data/milestones.js" 2>/dev/null || echo "")

# Test 2.2: Verify m01 is now "done"
if echo "$milestones_js" | grep -q '"id":"m01".*"status":"done"'; then
    echo "  PASS: milestone m01 transitioned to done status"
    PASS=$((PASS + 1))
else
    echo "  FAIL: milestone m01 did not transition to done"
    FAIL=$((FAIL + 1))
fi

# Test 2.3: Set m02 to in_progress
echo "Test 2.3: Setting milestone m02 to in_progress..."
dag_set_status "m02" "in_progress"
save_manifest
emit_dashboard_milestones
milestones_js=$(cat "$TMPDIR/.claude/dashboard/data/milestones.js" 2>/dev/null || echo "")

# Test 2.4: Verify m02 shows as in_progress
if echo "$milestones_js" | grep -q '"id":"m02".*"status":"in_progress"'; then
    echo "  PASS: milestone m02 transitioned to in_progress status"
    PASS=$((PASS + 1))
else
    echo "  FAIL: milestone m02 did not transition to in_progress"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  milestone_active_display tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All milestone active display tests passed"
