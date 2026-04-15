#!/usr/bin/env bash
# Test: init_synthesize.sh correctly trims preamble from DESIGN.md and CLAUDE.md
# Verifies that _trim_document_preamble is called in _synthesize_design() and _synthesize_claude()
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Test 1: DESIGN.md synthesis trims preamble ==="

proj_1="${TMPDIR_BASE}/proj_design_preamble"
mkdir -p "$proj_1"

# Create a script that tests _synthesize_design with preamble
script_file=$(mktemp "${TMPDIR_BASE}/synth_design_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/context.sh"
source "${TEKHTON_HOME}/lib/context_compiler.sh"

# Mock PROJECT_INDEX and detection content
export PROJECT_INDEX_CONTENT="Sample index"
export DETECTION_REPORT_CONTENT="Sample detection"

# Mock _call_planning_batch to return DESIGN.md with preamble
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    # Return DESIGN.md content WITH preamble
    cat << 'DESIGNEND'
Based on the project index provided, here is the DESIGN.md document:

# TestProject — Design Document

## Project Overview
This project is a test system built to verify the synthesis pipeline.
It demonstrates correct preamble trimming.

## Developer Philosophy
The project follows clean architecture principles and composition patterns.

## Architecture
The system is organized into modules with clear boundaries.
DESIGNEND
    return 0
}

# Set up minimal context
export PLAN_GENERATION_MODEL="test-model"
export PLAN_GENERATION_MAX_TURNS="1"

# Create a function wrapper to test _synthesize_design
test_synthesize_design() {
    local project_dir="$1"

    # Source the init_synthesize module
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"

    # Call _synthesize_design
    _synthesize_design "$project_dir" > /dev/null 2>&1
    echo $?
}

exit_code=$(test_synthesize_design "$PROJECT_DIR")
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_1" \
    DESIGN_FILE="DESIGN.md" \
    TEKHTON_DIR=".tekhton" \
    SYNTHESIS_MODEL="test-model" \
    SYNTHESIS_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_1}/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    content=$(cat "$design_md")

    if [[ "$first_line" == "# TestProject — Design Document" ]]; then
        pass "DESIGN.md starts with heading (preamble trimmed)"
    else
        fail "DESIGN.md first line is: $first_line"
    fi

    if ! echo "$content" | grep -q "Based on the project index"; then
        pass "Preamble text removed from DESIGN.md"
    else
        fail "Preamble text still present in DESIGN.md"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 2: CLAUDE.md synthesis trims preamble ==="

proj_2="${TMPDIR_BASE}/proj_claude_preamble"
mkdir -p "$proj_2"

# Create DESIGN.md first so _synthesize_claude can read it
cat > "${proj_2}/DESIGN.md" << 'EOF'
# TestProject — Design Document

## Project Overview
Test project.
EOF

script_file=$(mktemp "${TMPDIR_BASE}/synth_claude_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/context.sh"
source "${TEKHTON_HOME}/lib/context_compiler.sh"

export PROJECT_INDEX_CONTENT="Sample index"
export DETECTION_REPORT_CONTENT="Sample detection"

# Mock _call_planning_batch to return CLAUDE.md with preamble
_call_planning_batch() {
    cat << 'CLAUDEEND'
I've read the DESIGN.md and created a comprehensive CLAUDE.md file.
This file includes all required sections as specified.

# TestProject
## Project Identity
This is a test project with complete CLAUDE.md.

## Architecture Philosophy
The project uses standard architectural patterns.

## Non-Negotiable Rules
1. All tests must be deterministic
2. No external dependencies in tests
CLAUDEEND
    return 0
}

export PLAN_GENERATION_MODEL="test-model"
export PLAN_GENERATION_MAX_TURNS="1"

test_synthesize_claude() {
    local project_dir="$1"
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"
    _synthesize_claude "$project_dir" > /dev/null 2>&1
    echo $?
}

exit_code=$(test_synthesize_claude "$PROJECT_DIR")
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_2" \
    DESIGN_FILE="DESIGN.md" \
    TEKHTON_DIR=".tekhton" \
    SYNTHESIS_MODEL="test-model" \
    SYNTHESIS_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

claude_md="${proj_2}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    content=$(cat "$claude_md")

    if [[ "$first_line" == "# TestProject" ]]; then
        pass "CLAUDE.md starts with heading (preamble trimmed)"
    else
        fail "CLAUDE.md first line is: $first_line"
    fi

    if ! echo "$content" | grep -q "I've read the DESIGN.md"; then
        pass "Preamble text removed from CLAUDE.md"
    else
        fail "Preamble text still present in CLAUDE.md"
    fi

    if echo "$content" | grep -q "## Project Identity"; then
        pass "Content after heading preserved in CLAUDE.md"
    else
        fail "Content after heading lost"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 3: DESIGN.md synthesis without preamble (normal case) ==="

proj_3="${TMPDIR_BASE}/proj_design_normal"
mkdir -p "$proj_3"

script_file=$(mktemp "${TMPDIR_BASE}/synth_design_normal_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/context.sh"
source "${TEKHTON_HOME}/lib/context_compiler.sh"

export PROJECT_INDEX_CONTENT="Sample index"
export DETECTION_REPORT_CONTENT="Sample detection"

# Return DESIGN.md that already starts with heading (no preamble)
_call_planning_batch() {
    cat << 'DESIGNEND'
# Project — Design Document

## Project Overview
A normal DESIGN.md without preamble.
DESIGNEND
    return 0
}

export PLAN_GENERATION_MODEL="test-model"
export PLAN_GENERATION_MAX_TURNS="1"

test_synthesize_design() {
    local project_dir="$1"
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"
    _synthesize_design "$project_dir" > /dev/null 2>&1
    echo $?
}

exit_code=$(test_synthesize_design "$PROJECT_DIR")
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_3" \
    DESIGN_FILE="DESIGN.md" \
    TEKHTON_DIR=".tekhton" \
    SYNTHESIS_MODEL="test-model" \
    SYNTHESIS_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_3}/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    if [[ "$first_line" == "# Project — Design Document" ]]; then
        pass "Normal DESIGN.md (no preamble) handled correctly"
    else
        fail "First line is: $first_line"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 4: Preamble with multiple paragraphs ==="

proj_4="${TMPDIR_BASE}/proj_multiline_preamble"
mkdir -p "$proj_4"

script_file=$(mktemp "${TMPDIR_BASE}/synth_multiline_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/context.sh"
source "${TEKHTON_HOME}/lib/context_compiler.sh"

export PROJECT_INDEX_CONTENT="Sample index"
export DETECTION_REPORT_CONTENT="Sample detection"

# Return DESIGN.md with multi-line preamble
_call_planning_batch() {
    cat << 'DESIGNEND'
I've analyzed the project structure and files.
Based on the project index, I've identified the key patterns.
The codebase shows clear separation of concerns.
Now, here is the DESIGN.md:

# AnalyzedProject — Design Document

## Project Overview
This project implements a core system.

## Architecture
Multi-layered architecture with clear boundaries.
DESIGNEND
    return 0
}

export PLAN_GENERATION_MODEL="test-model"
export PLAN_GENERATION_MAX_TURNS="1"

test_synthesize_design() {
    local project_dir="$1"
    source "${TEKHTON_HOME}/stages/init_synthesize.sh"
    _synthesize_design "$project_dir" > /dev/null 2>&1
    echo $?
}

exit_code=$(test_synthesize_design "$PROJECT_DIR")
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_4" \
    DESIGN_FILE="DESIGN.md" \
    TEKHTON_DIR=".tekhton" \
    SYNTHESIS_MODEL="test-model" \
    SYNTHESIS_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_4}/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    content=$(cat "$design_md")

    if [[ "$first_line" == "# AnalyzedProject — Design Document" ]]; then
        pass "Multi-line preamble trimmed correctly"
    else
        fail "First line is: $first_line"
    fi

    if ! echo "$content" | grep -q "I've analyzed"; then
        pass "Multi-line preamble completely removed"
    else
        fail "Preamble text still present"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
