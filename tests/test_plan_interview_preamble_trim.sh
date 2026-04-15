#!/usr/bin/env bash
# Test: plan_interview.sh correctly trims preamble from DESIGN.md synthesis
# Verifies that _trim_document_preamble is called in run_plan_interview()
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Test 1: DESIGN.md from interview has preamble trimmed ==="

proj_1="${TMPDIR_BASE}/proj_interview_preamble"
mkdir -p "$proj_1"

script_file=$(mktemp "${TMPDIR_BASE}/interview_preamble_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Ensure TEKHTON_DIR exists for DESIGN_FILE writes
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

# Mock _call_planning_batch to return DESIGN.md with preamble
_call_planning_batch() {
    cat << 'DESIGNEND'
Based on your answers, I've synthesized the following DESIGN.md:

# MyWebApp — Design Document

## Project Overview
A modern web application built with React.
Target audience: developers.

## Developer Philosophy
Clean code, composition over inheritance.

## Architecture
Frontend, backend, database separation.

## Implementation Plan
Phase 1: Setup
Phase 2: Core features
DESIGNEND
    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

run_plan_interview > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_1" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="web-app" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_1}/.tekhton/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    content=$(cat "$design_md")

    if [[ "$first_line" == "# MyWebApp — Design Document" ]]; then
        pass "DESIGN.md starts with heading (preamble trimmed)"
    else
        fail "DESIGN.md first line is: $first_line"
    fi

    if ! echo "$content" | grep -q "Based on your answers"; then
        pass "Preamble text 'Based on your answers' removed"
    else
        fail "Preamble text still present"
    fi

    if echo "$content" | grep -q "## Project Overview"; then
        pass "Content after heading preserved"
    else
        fail "Content after heading lost"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 2: DESIGN.md without preamble (normal interview result) ==="

proj_2="${TMPDIR_BASE}/proj_interview_normal"
mkdir -p "$proj_2"

script_file=$(mktemp "${TMPDIR_BASE}/interview_normal_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Ensure TEKHTON_DIR exists for DESIGN_FILE writes
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

# Return DESIGN.md that already starts with heading (no preamble)
_call_planning_batch() {
    cat << 'DESIGNEND'
# APIService — Design Document

## Project Overview
REST API service.

## Architecture
Microservices pattern.
DESIGNEND
    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

run_plan_interview > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_2" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="api-service" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_2}/.tekhton/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    if [[ "$first_line" == "# APIService — Design Document" ]]; then
        pass "Normal DESIGN.md (no preamble) handled correctly"
    else
        fail "First line is: $first_line"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 3: Interview with multi-line preamble ==="

proj_3="${TMPDIR_BASE}/proj_interview_multiline"
mkdir -p "$proj_3"

script_file=$(mktemp "${TMPDIR_BASE}/interview_multiline_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Ensure TEKHTON_DIR exists for DESIGN_FILE writes
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

# Return DESIGN.md with multi-line preamble
_call_planning_batch() {
    cat << 'DESIGNEND'
I've reviewed all your answers from the interview.
I've identified the project scope and key components.
Now let me present the synthesized design:

# MobileApp — Design Document

## Project Overview
Cross-platform mobile application.

## Core Systems
- Authentication
- Data sync
DESIGNEND
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
    PLAN_PROJECT_TYPE="mobile-app" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_3}/.tekhton/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    content=$(cat "$design_md")

    if [[ "$first_line" == "# MobileApp — Design Document" ]]; then
        pass "Multi-line preamble trimmed correctly"
    else
        fail "First line is: $first_line"
    fi

    if ! echo "$content" | grep -q "I've reviewed"; then
        pass "Multi-line preamble completely removed"
    else
        fail "Preamble text still present"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 4: Preamble with various Claude phrases ==="

proj_4="${TMPDIR_BASE}/proj_interview_phrases"
mkdir -p "$proj_4"

script_file=$(mktemp "${TMPDIR_BASE}/interview_phrases_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Ensure TEKHTON_DIR exists for DESIGN_FILE writes
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

# Return DESIGN.md with various Claude preamble phrases
_call_planning_batch() {
    cat << 'DESIGNEND'
Based on the information provided, here is the design document:

# GameApp — Design Document

## Project Overview
A game application with multiplayer support.

## Gameplay Mechanics
Turn-based combat system.
DESIGNEND
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
    PLAN_PROJECT_TYPE="web-game" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_4}/.tekhton/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    if [[ "$first_line" == "# GameApp — Design Document" ]]; then
        pass "'Based on the information' preamble trimmed"
    else
        fail "First line is: $first_line"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Test 5: Tool-write guard + preamble trim (combined) ==="

proj_5="${TMPDIR_BASE}/proj_interview_toolwrite"
mkdir -p "$proj_5"

script_file=$(mktemp "${TMPDIR_BASE}/interview_toolwrite_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"

# Mock Claude writing via tool AND returning summary
_call_planning_batch() {
    # Write substantive DESIGN.md to disk (tool-write)
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"
    mkdir -p "$(dirname "$design_file")"
    {
        echo "# CLITool — Design Document"
        echo "## Project Overview"
        echo "A command-line tool."
        echo "## Architecture"
        echo "Single-file implementation."
        echo "## Features"
        for ((i = 7; i <= 25; i++)); do
            echo "Line $i of tool-written content."
        done
    } > "$design_file"

    # Return only summary (non-heading) text
    printf "DESIGN.md has been written with comprehensive content.\n"
    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

run_plan_interview > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_5" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="cli-tool" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

design_md="${proj_5}/.tekhton/DESIGN.md"

if [[ -f "$design_md" ]]; then
    first_line=$(head -1 "$design_md")
    if [[ "$first_line" == "# CLITool — Design Document" ]]; then
        pass "Tool-write guard + preamble trim work together"
    else
        fail "First line is: $first_line"
    fi
else
    fail "DESIGN.md was not created"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
