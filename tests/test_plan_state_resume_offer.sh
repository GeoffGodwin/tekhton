#!/usr/bin/env bash
# Test: Planning state resume offer UI (_offer_plan_resume)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR TEKHTON_TEST_MODE=1

source "${TEKHTON_HOME}/lib/common.sh"

# Set up state prerequisites
PLAN_STATE_FILE="${TMPDIR}/.claude/PLAN_STATE.md"
mkdir -p "${TMPDIR}/.claude"

source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"

# Create template files for testing
TEMPLATE_DIR="${TMPDIR}/templates"
mkdir -p "$TEMPLATE_DIR"
touch "${TEMPLATE_DIR}/web-game.md"
touch "${TEMPLATE_DIR}/mobile-app.md"
touch "${TEMPLATE_DIR}/cli-tool.md"
touch "${TEMPLATE_DIR}/api-service.md"
touch "${TEMPLATE_DIR}/library.md"

# Test 1: No state file exists → returns 1 (start fresh)
rc=0
_offer_plan_resume < /dev/null || rc=$?
[ "$rc" = "1" ] || { echo "FAIL: Should return 1 when no state and no DESIGN.md, got $rc"; exit 1; }

# Test 2: State file exists, user chooses [y] (resume)
write_plan_state "completeness" "web-game" "${TEMPLATE_DIR}/web-game.md"
rc=0
INPUT_FILE=$(mktemp)
echo "y" > "$INPUT_FILE"
_offer_plan_resume < "$INPUT_FILE" || rc=$?
rm -f "$INPUT_FILE"
[ "$rc" = "0" ] || { echo "FAIL: Should return 0 on resume, got $rc"; exit 1; }
[ "$PLAN_RESUME_STAGE" = "completeness" ] || { echo "FAIL: PLAN_RESUME_STAGE should be 'completeness', got '$PLAN_RESUME_STAGE'"; exit 1; }
[ "$PLAN_PROJECT_TYPE" = "web-game" ] || { echo "FAIL: PLAN_PROJECT_TYPE should be 'web-game', got '$PLAN_PROJECT_TYPE'"; exit 1; }

# Test 3: State file exists, user chooses [f] (fresh start)
write_plan_state "generation" "mobile-app" "${TEMPLATE_DIR}/mobile-app.md"
rc=0
INPUT_FILE=$(mktemp)
echo "f" > "$INPUT_FILE"
_offer_plan_resume < "$INPUT_FILE" || rc=$?
rm -f "$INPUT_FILE"
[ "$rc" = "1" ] || { echo "FAIL: Should return 1 on fresh start, got $rc"; exit 1; }
[ ! -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file should be cleared after [f]"; exit 1; }

# Test 4: State file exists, user chooses [n] (abort)
write_plan_state "interview" "cli-tool" "${TEMPLATE_DIR}/cli-tool.md"
rc=0
INPUT_FILE=$(mktemp)
echo "n" > "$INPUT_FILE"
_offer_plan_resume < "$INPUT_FILE" || rc=$?
rm -f "$INPUT_FILE"
[ "$rc" = "2" ] || { echo "FAIL: Should return 2 on abort, got $rc"; exit 1; }
[ -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file should be preserved after [n]"; exit 1; }

# Test 5: DESIGN.md exists without state file, user chooses [r] (resume from completeness)
rm -f "$PLAN_STATE_FILE"
touch "${PROJECT_DIR}/DESIGN.md"
# Mock select_project_type to just set PLAN_PROJECT_TYPE
select_project_type() {
    PLAN_PROJECT_TYPE="api-service"
    PLAN_TEMPLATE_FILE="${TEMPLATE_DIR}/api-service.md"
    return 0
}
export -f select_project_type
rc=0
INPUT_FILE=$(mktemp)
echo "r" > "$INPUT_FILE"
_offer_plan_resume < "$INPUT_FILE" || rc=$?
rm -f "$INPUT_FILE"
[ "$rc" = "0" ] || { echo "FAIL: Should return 0 on resume from DESIGN.md, got $rc"; exit 1; }
[ "$PLAN_RESUME_STAGE" = "completeness" ] || { echo "FAIL: PLAN_RESUME_STAGE should be 'completeness' when resuming from DESIGN.md, got '$PLAN_RESUME_STAGE'"; exit 1; }

# Test 6: DESIGN.md exists without state file, user chooses [f] (fresh start)
rm -f "$PLAN_STATE_FILE"  # Clean up previous test
touch "${PROJECT_DIR}/DESIGN.md"
rc=0
INPUT_FILE=$(mktemp)
echo "f" > "$INPUT_FILE"
_offer_plan_resume < "$INPUT_FILE" || rc=$?
rm -f "$INPUT_FILE"
[ "$rc" = "1" ] || { echo "FAIL: Should return 1 when starting fresh with existing DESIGN.md, got $rc"; exit 1; }

# Test 7: DESIGN.md exists without state file, user chooses [n] (abort)
rm -f "$PLAN_STATE_FILE"  # Clean up previous test
touch "${PROJECT_DIR}/DESIGN.md"
rc=0
INPUT_FILE=$(mktemp)
echo "n" > "$INPUT_FILE"
_offer_plan_resume < "$INPUT_FILE" || rc=$?
rm -f "$INPUT_FILE"
[ "$rc" = "2" ] || { echo "FAIL: Should return 2 on abort with existing DESIGN.md, got $rc"; exit 1; }

# Test 8: Invalid template path in saved state → should clear state and return 1
write_plan_state "generation" "library" "/path/that/does/not/exist.md"
rc=0
INPUT_FILE=$(mktemp)
echo "y" > "$INPUT_FILE"
_offer_plan_resume < "$INPUT_FILE" || rc=$?
rm -f "$INPUT_FILE"
[ "$rc" = "1" ] || { echo "FAIL: Should return 1 when saved template is missing, got $rc"; exit 1; }
[ ! -f "$PLAN_STATE_FILE" ] || { echo "FAIL: State file should be cleared when template is missing"; exit 1; }

echo "PASS: Planning state resume offer UI tests passed"
