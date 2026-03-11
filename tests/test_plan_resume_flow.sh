#!/usr/bin/env bash
# Test: State persistence at resume boundaries
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR TEKHTON_TEST_MODE=1

source "${TEKHTON_HOME}/lib/common.sh"

mkdir -p "${PROJECT_DIR}/.claude"
PLAN_STATE_FILE="${PROJECT_DIR}/.claude/PLAN_STATE.md"

source "${TEKHTON_HOME}/lib/plan_state.sh"

# Create template files for testing
TEMPLATE_DIR="${TMPDIR}/templates"
mkdir -p "$TEMPLATE_DIR"
touch "${TEMPLATE_DIR}/web-app.md"
touch "${TEMPLATE_DIR}/api-service.md"
touch "${TEMPLATE_DIR}/cli-tool.md"

# Test 1: State saved after type selection
write_plan_state "interview" "web-app" "${TEMPLATE_DIR}/web-app.md"
[ -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file should be created after type selection"; exit 1; }
grep -q "interview" "$PLAN_STATE_FILE" || { echo "FAIL: Stage should be 'interview'"; exit 1; }
clear_plan_state

# Test 2: State saved after interview
write_plan_state "completeness" "api-service" "${TEMPLATE_DIR}/api-service.md"
[ -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file should be created after interview"; exit 1; }
grep -q "completeness" "$PLAN_STATE_FILE" || { echo "FAIL: Stage should be 'completeness'"; exit 1; }
clear_plan_state

# Test 3: State saved after completeness check
write_plan_state "generation" "cli-tool" "${TEMPLATE_DIR}/cli-tool.md"
[ -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file should be created after completeness"; exit 1; }
grep -q "generation" "$PLAN_STATE_FILE" || { echo "FAIL: Stage should be 'generation'"; exit 1; }
clear_plan_state

# Test 4: State cleared after successful completion
write_plan_state "review" "web-app" "${TEMPLATE_DIR}/web-app.md"
clear_plan_state
[ ! -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file should be cleared after completion"; exit 1; }

# Test 5: PLAN_PROJECT_TYPE and PLAN_TEMPLATE_FILE restored on resume
write_plan_state "generation" "api-service" "${TEMPLATE_DIR}/api-service.md"
read_plan_state
[ "$PLAN_SAVED_PROJECT_TYPE" = "api-service" ] || { echo "FAIL: Project type not restored"; exit 1; }
[ "$PLAN_SAVED_TEMPLATE_FILE" = "${TEMPLATE_DIR}/api-service.md" ] || { echo "FAIL: Template file not restored"; exit 1; }
clear_plan_state

# Test 6: Multiple state transitions simulate a complete flow
write_plan_state "interview" "web-app" "${TEMPLATE_DIR}/web-app.md"
read_plan_state
SAVED_TYPE="$PLAN_SAVED_PROJECT_TYPE"

write_plan_state "completeness" "$SAVED_TYPE" "${TEMPLATE_DIR}/web-app.md"
read_plan_state
[ "$PLAN_SAVED_STAGE" = "completeness" ] || { echo "FAIL: Stage transition failed"; exit 1; }

write_plan_state "generation" "$SAVED_TYPE" "${TEMPLATE_DIR}/web-app.md"
read_plan_state
[ "$PLAN_SAVED_STAGE" = "generation" ] || { echo "FAIL: Final stage not set"; exit 1; }

clear_plan_state
[ ! -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State not cleared at completion"; exit 1; }

echo "PASS: Planning state persistence tests passed"
