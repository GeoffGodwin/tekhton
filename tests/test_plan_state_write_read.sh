#!/usr/bin/env bash
# Test: Planning state write and read round-trip
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

# Test 1: Write state and verify file was created
write_plan_state "interview" "web-app" "/path/to/web-app.md"
[ -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file not created"; exit 1; }

# Test 2: Verify state file contains expected content
grep -q "interview" "$PLAN_STATE_FILE" || { echo "FAIL: Stage not in state file"; exit 1; }
grep -q "web-app" "$PLAN_STATE_FILE" || { echo "FAIL: Project type not in state file"; exit 1; }
grep -q "/path/to/web-app.md" "$PLAN_STATE_FILE" || { echo "FAIL: Template file not in state file"; exit 1; }

# Test 3: Read state back and verify variables are set
read_plan_state || { echo "FAIL: read_plan_state returned non-zero"; exit 1; }
[ "$PLAN_SAVED_STAGE" = "interview" ] || { echo "FAIL: PLAN_SAVED_STAGE is '${PLAN_SAVED_STAGE}', expected 'interview'"; exit 1; }
[ "$PLAN_SAVED_PROJECT_TYPE" = "web-app" ] || { echo "FAIL: PLAN_SAVED_PROJECT_TYPE is '${PLAN_SAVED_PROJECT_TYPE}', expected 'web-app'"; exit 1; }
[ "$PLAN_SAVED_TEMPLATE_FILE" = "/path/to/web-app.md" ] || { echo "FAIL: PLAN_SAVED_TEMPLATE_FILE is '${PLAN_SAVED_TEMPLATE_FILE}', expected '/path/to/web-app.md'"; exit 1; }

# Test 4: Overwrite state with new values
write_plan_state "generation" "cli-tool" "/path/to/cli-tool.md"
read_plan_state || { echo "FAIL: read_plan_state after overwrite returned non-zero"; exit 1; }
[ "$PLAN_SAVED_STAGE" = "generation" ] || { echo "FAIL: Stage not updated"; exit 1; }
[ "$PLAN_SAVED_PROJECT_TYPE" = "cli-tool" ] || { echo "FAIL: Project type not updated"; exit 1; }

# Test 5: Clear state and verify file is removed
clear_plan_state
[ ! -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file not cleared"; exit 1; }

# Test 6: read_plan_state returns 1 when state file doesn't exist
read_plan_state || rc=$?
[ "$rc" = "1" ] || { echo "FAIL: read_plan_state should return 1 when no state file, got $rc"; exit 1; }

echo "PASS: Planning state write/read tests passed"
