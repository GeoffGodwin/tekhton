#!/usr/bin/env bash
# Test: Planning state clear function
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Set up state prerequisites
PLAN_STATE_FILE="${TMPDIR}/.claude/PLAN_STATE.md"
mkdir -p "${TMPDIR}/.claude"

source "${TEKHTON_HOME}/lib/plan_state.sh"

# Test 1: Clear when state file exists
write_plan_state "completeness" "library" "/path/to/library.md"
[ -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file not created for clear test"; exit 1; }

clear_plan_state
[ ! -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file not removed"; exit 1; }

# Test 2: Clear when state file doesn't exist (should not error)
clear_plan_state || { echo "FAIL: clear_plan_state errored when state file missing"; exit 1; }

# Test 3: Verify read_plan_state returns 1 after clear
read_plan_state || rc=$?
[ "$rc" = "1" ] || { echo "FAIL: read_plan_state should return 1 after clear, got $rc"; exit 1; }

# Test 4: Write, clear, verify all state variables are unset
write_plan_state "generation" "api-service" "/path/to/api.md"
clear_plan_state
read_plan_state || true  # We expect this to fail, so ignore the return code
[ -z "$PLAN_SAVED_STAGE" ] || { echo "FAIL: PLAN_SAVED_STAGE not empty after clear"; exit 1; }
[ -z "$PLAN_SAVED_PROJECT_TYPE" ] || { echo "FAIL: PLAN_SAVED_PROJECT_TYPE not empty after clear"; exit 1; }
[ -z "$PLAN_SAVED_TEMPLATE_FILE" ] || { echo "FAIL: PLAN_SAVED_TEMPLATE_FILE not empty after clear"; exit 1; }

echo "PASS: Planning state clear tests passed"
