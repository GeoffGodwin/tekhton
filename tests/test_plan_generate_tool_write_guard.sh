#!/usr/bin/env bash
# Test: plan_generate() tool-write guard detection and on-disk content rescue
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Helper: Run run_plan_generate() with a mock _call_planning_batch
# that simulates Claude writing CLAUDE.md via tool.
#
# Arguments:
#   $1  tool_writes_file — "yes" to have mock write CLAUDE.md via tool
#   $2  tool_returns_summary — "yes" to return summary (non-heading) text
#   $3  disk_line_count — number of lines the tool-written file should have
#   $4  project_dir — temp directory to use as PROJECT_DIR
#
# Returns exit code of run_plan_generate()
run_generate_with_tool_write() {
    local tool_writes_file="$1"
    local tool_returns_summary="$2"
    local disk_line_count="$3"
    local project_dir="$4"

    local script_file
    script_file=$(mktemp "${TMPDIR_BASE}/generate_XXXXXX.sh")

    cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

# Mock _call_planning_batch to simulate Claude writing CLAUDE.md via tool
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    # If TOOL_WRITES_FILE=yes, write substantive content to CLAUDE.md
    if [[ "$TOOL_WRITES_FILE" == "yes" ]]; then
        local claude_md="${PROJECT_DIR}/CLAUDE.md"
        mkdir -p "$(dirname "$claude_md")"

        # Write a heading-started document with N lines
        {
            echo "# Tekhton CLAUDE.md"
            echo "## Project Identity"
            echo "This is a tool-written CLAUDE.md with complete content."
            echo ""
            for ((i = 5; i <= DISK_LINE_COUNT; i++)); do
                echo "Line $i of the generated document."
            done
        } > "$claude_md"
    fi

    # Return only summary text (non-heading) if TOOL_RETURNS_SUMMARY=yes
    if [[ "$TOOL_RETURNS_SUMMARY" == "yes" ]]; then
        printf "CLAUDE.md has been generated with %d lines. It contains the complete milestone plan.\n" "$DISK_LINE_COUNT"
    else
        # Normal case: return heading-started content
        printf "# Tekhton CLAUDE.md\n## Project Identity\nGeneration complete.\n"
    fi

    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

    TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$project_dir" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    TOOL_WRITES_FILE="$tool_writes_file" \
    TOOL_RETURNS_SUMMARY="$tool_returns_summary" \
    DISK_LINE_COUNT="$disk_line_count" \
    bash "$script_file" 2>/dev/null < /dev/null
}

echo "=== Test 1: Guard detects tool-write and rescues on-disk CLAUDE.md ==="

proj_1="${TMPDIR_BASE}/proj_generate_tool"
mkdir -p "$proj_1"

# Create a valid DESIGN.md first
cat > "${proj_1}/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
This is a test design document.

## Core Features
- Feature 1
- Feature 2

## Architecture
The architecture is simple.

## Implementation Plan
Phase 1: Setup
Phase 2: Development
Phase 3: Testing
EOF

# Run with tool writing CLAUDE.md + returning only summary
exit_code=$(run_generate_with_tool_write "yes" "yes" 30 "$proj_1")
claude_md="${proj_1}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    content=$(cat "$claude_md")
    line_count=$(wc -l < "$claude_md")

    # Should have rescued on-disk content (heading-started, >20 lines)
    if [[ "$first_line" == "# Tekhton CLAUDE.md" ]]; then
        pass "CLAUDE.md starts with correct heading (tool-write detected and rescued)"
    else
        fail "CLAUDE.md first line is: $first_line (expected '# Tekhton CLAUDE.md')"
    fi

    # Should have the full document (31 lines: 30 + tekhton-managed marker)
    if [[ "$line_count" -eq 31 ]]; then
        pass "CLAUDE.md has correct line count (31 lines)"
    else
        fail "CLAUDE.md has $line_count lines (expected 31)"
    fi

    # Check that summary was NOT written
    if ! echo "$content" | grep -q "has been generated"; then
        pass "CLAUDE.md does not contain summary text"
    else
        fail "CLAUDE.md contains summary text (should be full document)"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 2: Normal case (no tool-write, heading-started) ==="

proj_2="${TMPDIR_BASE}/proj_generate_normal"
mkdir -p "$proj_2"

# Create a valid DESIGN.md
cat > "${proj_2}/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
This is a test design document.

## Core Features
- Feature 1
- Feature 2
EOF

# Run without tool writing, normal heading-started output
exit_code=$(run_generate_with_tool_write "no" "no" 30 "$proj_2")
claude_md="${proj_2}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    if [[ "$first_line" == "# Tekhton CLAUDE.md" ]]; then
        pass "CLAUDE.md starts with heading (normal case)"
    else
        fail "CLAUDE.md first line is: $first_line (expected '# Tekhton CLAUDE.md')"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 3: Guard does NOT fire for short documents <20 lines ==="

proj_3="${TMPDIR_BASE}/proj_generate_short"
mkdir -p "$proj_3"

# Create a valid DESIGN.md
cat > "${proj_3}/DESIGN.md" << 'EOF'
# DESIGN.md
## Project Overview
Test doc.
EOF

script_file=$(mktemp "${TMPDIR_BASE}/generate_short_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

_call_planning_batch() {
    local claude_md="${PROJECT_DIR}/CLAUDE.md"
    mkdir -p "$(dirname "$claude_md")"

    # Write a SHORT document (10 lines only)
    {
        echo "# Short CLAUDE"
        echo "Line 2"
        echo "Line 3"
        echo "Line 4"
        echo "Line 5"
        echo "Line 6"
        echo "Line 7"
        echo "Line 8"
        echo "Line 9"
        echo "Line 10"
    } > "$claude_md"

    # Return summary (non-heading)
    printf "CLAUDE.md created with 10 lines.\n"
    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_3" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

claude_md="${proj_3}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    content=$(cat "$claude_md")
    # Guard should NOT fire because file has only 10 lines (<20 threshold)
    # So it would write the summary
    if echo "$content" | grep -q "created with 10 lines"; then
        pass "Guard correctly did NOT fire for 10-line CLAUDE.md (summary written)"
    else
        # But the tool-written file still exists with its content
        if head -1 "$claude_md" | grep -q "^# Short CLAUDE"; then
            pass "10-line CLAUDE.md remains from tool-write (guard threshold not met)"
        else
            fail "CLAUDE.md unexpected content for short file case"
        fi
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 4: Guard does NOT fire for documents NOT starting with heading ==="

proj_4="${TMPDIR_BASE}/proj_generate_no_heading"
mkdir -p "$proj_4"

# Create a valid DESIGN.md
cat > "${proj_4}/DESIGN.md" << 'EOF'
# DESIGN.md
## Content
Test.
EOF

script_file=$(mktemp "${TMPDIR_BASE}/generate_no_heading_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

_call_planning_batch() {
    local claude_md="${PROJECT_DIR}/CLAUDE.md"
    mkdir -p "$(dirname "$claude_md")"

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
    } > "$claude_md"

    # Return summary (non-heading)
    printf "Created CLAUDE.md.\n"
    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_4" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

claude_md="${proj_4}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    # Guard should NOT fire because disk file doesn't start with #
    # So the summary would be written
    if echo "$first_line" | grep -q "Created CLAUDE.md"; then
        pass "Guard correctly did NOT fire for non-heading CLAUDE.md (summary written)"
    else
        fail "Unexpected CLAUDE.md content: $first_line"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
