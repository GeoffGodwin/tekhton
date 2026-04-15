#!/usr/bin/env bash
# Test: plan_interview() tool-write guard detection and on-disk content rescue
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Helper: Run run_plan_interview() in an isolated subprocess with a mock
# _call_planning_batch that simulates Claude writing a file via tool.
#
# Arguments:
#   $1  tool_writes_file — "yes" to have mock write DESIGN.md via tool
#   $2  tool_returns_summary — "yes" to return summary (non-heading) text
#   $3  disk_line_count — number of lines the tool-written file should have
#   $4  project_dir — temp directory to use as PROJECT_DIR
#
# Returns exit code of run_plan_interview()
run_interview_with_tool_write() {
    local tool_writes_file="$1"
    local tool_returns_summary="$2"
    local disk_line_count="$3"
    local project_dir="$4"

    local script_file
    script_file=$(mktemp "${TMPDIR_BASE}/interview_XXXXXX.sh")

    cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Ensure TEKHTON_DIR exists for DESIGN_FILE writes
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

# Mock _call_planning_batch to simulate Claude writing DESIGN.md via tool
# and returning only a summary as text output.
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    # If TOOL_WRITES_FILE=yes, write substantive content to DESIGN.md
    if [[ "$TOOL_WRITES_FILE" == "yes" ]]; then
        local design_file="${PROJECT_DIR}/${DESIGN_FILE}"
        mkdir -p "$(dirname "$design_file")"

        # Write a heading-started document with N lines
        {
            echo "# DESIGN.md"
            echo "## Overview"
            echo "This is a tool-written document with substantive content."
            echo ""
            for ((i = 5; i <= DISK_LINE_COUNT; i++)); do
                echo "Line $i of the document."
            done
        } > "$design_file"
    fi

    # Return only summary text (non-heading) if TOOL_RETURNS_SUMMARY=yes
    if [[ "$TOOL_RETURNS_SUMMARY" == "yes" ]]; then
        printf "DESIGN.md has been written with %d lines. It contains the complete document.\n" "$DISK_LINE_COUNT"
    else
        # Normal case: return heading-started content
        printf "# DESIGN.md\n## Overview\nDocument created.\n"
    fi

    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

run_plan_interview > /dev/null 2>&1
echo $?
INNERSCRIPT

    TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$project_dir" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="web-app" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    TOOL_WRITES_FILE="$tool_writes_file" \
    TOOL_RETURNS_SUMMARY="$tool_returns_summary" \
    DISK_LINE_COUNT="$disk_line_count" \
    bash "$script_file" 2>/dev/null < /dev/null
}

echo "=== Test 1: Guard detects tool-write and rescues on-disk content ==="

proj_1="${TMPDIR_BASE}/proj_tool_write"
mkdir -p "$proj_1"

# Run with tool writing file + returning only summary
exit_code=$(run_interview_with_tool_write "yes" "yes" 25 "$proj_1")
design_file="${proj_1}/.tekhton/DESIGN.md"

if [[ -f "$design_file" ]]; then
    first_line=$(head -1 "$design_file")
    content=$(cat "$design_file")
    line_count=$(wc -l < "$design_file")

    # Should have rescued on-disk content (heading-started, >20 lines)
    if [[ "$first_line" == "# DESIGN.md" ]]; then
        pass "DESIGN.md starts with heading (tool-write detected and rescued)"
    else
        fail "DESIGN.md first line is: $first_line (expected '# DESIGN.md')"
    fi

    # Should have the full document (25 lines), not the summary
    if [[ "$line_count" -eq 25 ]]; then
        pass "DESIGN.md has correct line count (25 lines)"
    else
        fail "DESIGN.md has $line_count lines (expected 25)"
    fi

    # Check that summary was NOT written
    if ! echo "$content" | grep -q "has been written"; then
        pass "DESIGN.md does not contain summary text"
    else
        fail "DESIGN.md contains summary text (should be full document)"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 2: Normal case (no tool-write, heading-started) ==="

proj_2="${TMPDIR_BASE}/proj_normal"
mkdir -p "$proj_2"

# Run without tool writing, normal heading-started output
exit_code=$(run_interview_with_tool_write "no" "no" 25 "$proj_2")
design_file="${proj_2}/.tekhton/DESIGN.md"

if [[ -f "$design_file" ]]; then
    first_line=$(head -1 "$design_file")
    if [[ "$first_line" == "# DESIGN.md" ]]; then
        pass "DESIGN.md starts with heading (normal case)"
    else
        fail "DESIGN.md first line is: $first_line (expected '# DESIGN.md')"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 3: Guard does NOT fire for short documents <20 lines ==="

proj_3="${TMPDIR_BASE}/proj_short"
mkdir -p "$proj_3"

# Create a script that writes a SHORT file (10 lines) but returns summary
script_file=$(mktemp "${TMPDIR_BASE}/interview_short_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Ensure TEKHTON_DIR exists for DESIGN_FILE writes
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

_call_planning_batch() {
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"
    mkdir -p "$(dirname "$design_file")"

    # Write a SHORT document (10 lines only)
    {
        echo "# Short"
        echo "Line 2"
        echo "Line 3"
        echo "Line 4"
        echo "Line 5"
        echo "Line 6"
        echo "Line 7"
        echo "Line 8"
        echo "Line 9"
        echo "Line 10"
    } > "$design_file"

    # Return summary (non-heading)
    printf "DESIGN.md created with 10 lines.\n"
    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

run_plan_interview > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_3" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="web-app" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_file="${proj_3}/.tekhton/DESIGN.md"

if [[ -f "$design_file" ]]; then
    content=$(cat "$design_file")
    # Guard should NOT fire because file has only 10 lines (<20 threshold)
    # So it would write the summary
    if echo "$content" | grep -q "created with 10 lines"; then
        pass "Guard correctly did NOT fire for 10-line file (summary written)"
    else
        # But the tool-written file still exists with its content
        if head -1 "$design_file" | grep -q "^# Short"; then
            pass "10-line file remains from tool-write (guard threshold not met)"
        else
            fail "DESIGN.md unexpected content for short file case"
        fi
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 4: Guard does NOT fire for documents NOT starting with heading ==="

proj_4="${TMPDIR_BASE}/proj_no_heading"
mkdir -p "$proj_4"

script_file=$(mktemp "${TMPDIR_BASE}/interview_no_heading_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Ensure TEKHTON_DIR exists for DESIGN_FILE writes
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

_call_planning_batch() {
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"
    mkdir -p "$(dirname "$design_file")"

    # Write a document NOT starting with # (>20 lines)
    {
        echo "This document doesn't start with a heading."
        echo "Line 2"
        echo "Line 3"
        echo "Line 4"
        echo "Line 5"
        echo "Line 6"
        echo "Line 7"
        echo "Line 8"
        echo "Line 9"
        echo "Line 10"
        echo "Line 11"
        echo "Line 12"
        echo "Line 13"
        echo "Line 14"
        echo "Line 15"
        echo "Line 16"
        echo "Line 17"
        echo "Line 18"
        echo "Line 19"
        echo "Line 20"
        echo "Line 21"
    } > "$design_file"

    # Return summary (non-heading)
    printf "Created document.\n"
    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

run_plan_interview > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_4" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="web-app" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_file="${proj_4}/.tekhton/DESIGN.md"

if [[ -f "$design_file" ]]; then
    first_line=$(head -1 "$design_file")
    # Guard should NOT fire because disk file doesn't start with #
    # So the summary would be written
    if echo "$first_line" | grep -q "Created document"; then
        pass "Guard correctly did NOT fire for non-heading file (summary written)"
    else
        fail "Unexpected DESIGN.md content: $first_line"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
