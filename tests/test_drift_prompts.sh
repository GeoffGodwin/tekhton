#!/usr/bin/env bash
# Test: ACP and drift observation sections render correctly in prompts
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

FAIL=0

assert_contains() {
    local name="$1" content="$2" pattern="$3"
    if ! echo "$content" | grep -q "$pattern"; then
        echo "FAIL: $name — expected pattern '$pattern' not found"
        FAIL=1
    fi
}

assert_not_contains() {
    local name="$1" content="$2" pattern="$3"
    if echo "$content" | grep -q "$pattern"; then
        echo "FAIL: $name — unexpected pattern '$pattern' found"
        FAIL=1
    fi
}

# --- Test 1: Coder prompt includes ACP section (always present) ---
# Set minimal required variables for rendering
export PROJECT_NAME="Test" TASK="Implement feature" CODER_ROLE_FILE=".claude/agents/coder.md"
export PROJECT_RULES_FILE="CLAUDE.md" ARCHITECTURE_FILE="ARCHITECTURE.md"
export ANALYZE_CMD="echo ok" TEST_CMD="echo ok"
export DESIGN_FILE=""  # Empty — Design Observations should be stripped

CODER_OUTPUT=$(render_prompt "coder")
assert_contains "Coder ACP section present" "$CODER_OUTPUT" "Architecture Change Proposals"
assert_not_contains "Design Obs stripped when no DESIGN_FILE" "$CODER_OUTPUT" "Design Observations"

# --- Test 2: Coder prompt includes Design Observations when DESIGN_FILE is set ---
export DESIGN_FILE="docs/GDD.md"
CODER_OUTPUT_WITH_DESIGN=$(render_prompt "coder")
assert_contains "Design Obs present with DESIGN_FILE" "$CODER_OUTPUT_WITH_DESIGN" "Design Observations"
assert_contains "Design file name in prompt" "$CODER_OUTPUT_WITH_DESIGN" "docs/GDD.md"

# --- Test 3: Reviewer prompt includes ACP Evaluation and Drift sections ---
export REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
export REVIEW_CYCLE="1" MAX_REVIEW_CYCLES="2"
export ARCHITECTURE_CONTENT="# Architecture"
export PRIOR_BLOCKERS_BLOCK=""
export INLINE_CONTRACT_PATTERN=""

REVIEWER_OUTPUT=$(render_prompt "reviewer")
assert_contains "Reviewer ACP eval section" "$REVIEWER_OUTPUT" "Architecture Change Proposal Evaluation"
assert_contains "Reviewer drift obs section" "$REVIEWER_OUTPUT" "Drift Observations"
assert_contains "Reviewer ACP verdicts heading" "$REVIEWER_OUTPUT" "ACP Verdicts"

# --- Test 4: Coder rework prompt mentions ACP handling ---
REWORK_OUTPUT=$(render_prompt "coder_rework")
assert_contains "Rework mentions ACP" "$REWORK_OUTPUT" "REJECTED or MODIFIED ACPs"

# --- Test 5: Existing prompts still render (backward compat) ---
# These should not error out
export JR_AFTER_SENIOR="" JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
render_prompt "jr_coder" > /dev/null
render_prompt "coder_rework" > /dev/null

if [ "$FAIL" -eq 0 ]; then
    echo "All drift prompt tests passed."
else
    exit 1
fi
