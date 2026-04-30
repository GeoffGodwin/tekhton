#!/usr/bin/env bash
# Test TUI stage completion — verify that stage duration and turns are correctly recorded.
# Tests the integration between tekhton.sh TUI calls and the status JSON written by tui_ops.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEKHTON_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(mktemp -d)"
trap "rm -rf '$PROJECT_DIR'" EXIT

pass() {
    echo "✓ PASS: $1"
    return 0
}

fail() {
    echo "✗ FAIL: $1" >&2
    exit 1
}

# Create a minimal mock project structure
mkdir -p "$PROJECT_DIR/.claude/logs"
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-project"
ANALYZE_CMD="echo 'OK'"
BUILD_CHECK_CMD="echo 'OK'"
TEST_CMD="echo 'OK'"
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
EOF

mkdir -p "$PROJECT_DIR/.claude/agents"
touch "$PROJECT_DIR/.claude/agents/coder.md"
touch "$PROJECT_DIR/.claude/agents/reviewer.md"
touch "$PROJECT_DIR/.claude/agents/tester.md"

# Source required libraries
# shellcheck disable=SC1090
source "$TEKHTON_HOME/lib/common.sh" || fail "Failed to source common.sh"
# shellcheck disable=SC1090
source "$TEKHTON_HOME/lib/tui_helpers.sh" || fail "Failed to source tui_helpers.sh"
# shellcheck disable=SC1090
source "$TEKHTON_HOME/lib/tui.sh" || fail "Failed to source tui.sh"
# shellcheck disable=SC1090
source "$TEKHTON_HOME/lib/tui_ops.sh" || fail "Failed to source tui_ops.sh"

# Test 1: tui_stage_end computes elapsed time from wall-clock _TUI_STAGE_START_TS
test_tui_stage_end_elapsed_secs() {
    local status_file="$PROJECT_DIR/tui_status.json"

    # Initialize TUI state
    _TUI_ACTIVE="true"
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_STAGES_COMPLETE=()
    _TUI_CURRENT_LIFECYCLE_ID="lifecycle_test_001"
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    # Let time pass so elapsed is measurable
    sleep 1

    # Call tui_stage_end with explicit time string (caller responsibility)
    # The internal computation of _TUI_AGENT_ELAPSED_SECS should reflect real elapsed time
    tui_stage_end "coder" "claude-opus-4-7" "15/50" "0s" "PASS"

    # Verify that _TUI_AGENT_ELAPSED_SECS was computed from wall-clock time
    # It should be >= 1 second since we slept
    if (( ${_TUI_AGENT_ELAPSED_SECS:-0} >= 1 )); then
        pass "tui_stage_end computed elapsed time: ${_TUI_AGENT_ELAPSED_SECS}s"
    else
        fail "Elapsed time not computed correctly: ${_TUI_AGENT_ELAPSED_SECS}s (expected >= 1)"
    fi
}

# Test 2: tui_stage_end records turns correctly
test_tui_stage_end_turns() {
    local status_file="$PROJECT_DIR/tui_status2.json"

    # Initialize TUI state
    _TUI_ACTIVE="true"
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_STAGES_COMPLETE=()
    _TUI_CURRENT_LIFECYCLE_ID="lifecycle_test_002"
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    # Call tui_stage_end with turns
    tui_stage_end "review" "claude-sonnet-4-6" "8/15" "90s" "PASS"

    # Verify the JSON was written
    [[ -f "$status_file" ]] || fail "Status file not created at $status_file"

    # Extract the turns record
    local turns_str
    turns_str=$(grep -o '"turns":"[^"]*"' "$status_file" | head -1 | cut -d'"' -f4)

    # Turns should be "8/15"
    [[ "$turns_str" == "8/15" ]] && pass "tui_stage_end recorded turns: $turns_str" || fail "Turns mismatch: $turns_str (expected 8/15)"
}

# Test 3: Multiple stages recorded in sequence
test_tui_multiple_stages_recorded() {
    local status_file="$PROJECT_DIR/tui_status3.json"

    # Initialize TUI state
    _TUI_ACTIVE="true"
    _TUI_STAGES_COMPLETE=()
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    # Record first stage
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_CURRENT_LIFECYCLE_ID="lifecycle_001"
    tui_stage_end "intake" "claude-haiku-4-5" "2/10" "16s" "PASS"

    # Record second stage
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_CURRENT_LIFECYCLE_ID="lifecycle_002"
    tui_stage_end "coder" "claude-opus-4-7" "25/50" "300s" "PASS"

    # Verify both stages in the JSON
    [[ -f "$status_file" ]] || fail "Status file not created"

    # Both stages should be recorded
    grep -q '"label":"intake"' "$status_file" || fail "intake stage not found in status"
    grep -q '"label":"coder"' "$status_file" || fail "coder stage not found in status"

    pass "Multiple stages recorded correctly"
}

# Test 4: Stage metrics arrays are correctly passed through to TUI JSON
test_tui_stage_metrics_arrays() {
    local status_file="$PROJECT_DIR/tui_status4.json"

    # Initialize TUI state
    _TUI_ACTIVE="true"
    _TUI_STAGES_COMPLETE=()
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    # Simulate what tekhton.sh does: set arrays before calling tui_stage_end
    # This tests the path from tekhton.sh:2530-2538 where arrays control TUI output
    declare -A _STAGE_DURATION
    declare -A _STAGE_TURNS
    declare -A _STAGE_BUDGET
    _STAGE_DURATION["review"]=90
    _STAGE_TURNS["review"]=8
    _STAGE_BUDGET["review"]=15

    # Simulate the tekhton.sh stage completion call
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_CURRENT_LIFECYCLE_ID="lifecycle_review_001"
    sleep 1

    # Call tui_stage_end with values from the arrays (as tekhton.sh does)
    tui_stage_end "review" "${CLAUDE_STANDARD_MODEL:-claude-opus-4-7}" \
        "${_STAGE_TURNS[review]:-0}/${_STAGE_BUDGET[review]:-0}" \
        "${_STAGE_DURATION[review]:-0}s" ""

    # Verify the JSON was written
    [[ -f "$status_file" ]] || fail "Status file not created"

    # Extract recorded duration and turns
    local duration_str turns_str
    duration_str=$(grep -o '"time":"[^"]*"' "$status_file" | head -1 | cut -d'"' -f4)
    turns_str=$(grep -o '"turns":"[^"]*"' "$status_file" | head -1 | cut -d'"' -f4)

    # Verify the array values made it through
    [[ "$duration_str" == "90s" ]] || fail "Duration mismatch: $duration_str (expected 90s from array)"
    [[ "$turns_str" == "8/15" ]] || fail "Turns mismatch: $turns_str (expected 8/15 from array)"
    pass "Stage metrics arrays correctly passed to TUI JSON"
}

# Test 5: Stage with empty turns
test_tui_stage_empty_turns() {
    local status_file="$PROJECT_DIR/tui_status5.json"

    # Initialize TUI state
    _TUI_ACTIVE="true"
    _TUI_STAGE_START_TS=$(date +%s)
    _TUI_STAGES_COMPLETE=()
    _TUI_CURRENT_LIFECYCLE_ID="lifecycle_test_005"
    _TUI_STATUS_FILE="$status_file"
    _TUI_STATUS_TMP="${status_file}.tmp"
    _TUI_PIPELINE_START_TS=$(date +%s)

    # Call tui_stage_end with empty turns (pre-flight doesn't have turns)
    tui_stage_end "preflight" "" "" "45s" "PASS"

    # Verify the JSON was written
    [[ -f "$status_file" ]] || fail "Status file not created"

    # Extract the turns (should be empty or absent)
    local turns_str
    turns_str=$(grep -o '"turns":"[^"]*"' "$status_file" | head -1 | cut -d'"' -f4)

    # Turns should be empty string
    [[ -z "$turns_str" ]] && pass "Empty turns recorded correctly" || fail "Expected empty turns, got: $turns_str"
}

# Run all tests
test_tui_stage_end_elapsed_secs
test_tui_stage_end_turns
test_tui_multiple_stages_recorded
test_tui_stage_metrics_arrays
test_tui_stage_empty_turns

echo ""
echo "All tests passed!"
exit 0
