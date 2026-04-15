#!/usr/bin/env bash
# Test: plan_generate.sh correctly trims preamble from Claude output
# Verifies that _trim_document_preamble is called in run_plan_generate()
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Test 1: CLAUDE.md generation with preamble text trimmed ==="

proj_1="${TMPDIR_BASE}/proj_preamble_trim"
mkdir -p "$proj_1/.tekhton"

# Create a valid DESIGN.md
cat > "${proj_1}/.tekhton/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
This is a test design document.

## Architecture Philosophy
The system follows standard patterns.

## Implementation Plan
Phase 1: Foundation
Phase 2: Features
Phase 3: Polish
EOF

# Create a script that runs plan_generate with preamble-containing output
script_file=$(mktemp "${TMPDIR_BASE}/generate_preamble_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

# Mock _call_planning_batch to return preamble + CLAUDE.md content
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    # Return CLAUDE.md content WITH preamble text
    cat << 'CLAUDEEND'
I've analyzed the DESIGN.md and generated a comprehensive CLAUDE.md below.

# TestProject
## Project Identity
This project builds a test system.

## Architecture Philosophy
Follows composition pattern.

## Implementation Milestones
### Milestone 1: Foundation
**Scope:** Set up project structure
**Deliverables:**
- Project skeleton
- Build system

### Milestone 2: Features
**Scope:** Implement core features
**Deliverables:**
- Feature 1
- Feature 2
CLAUDEEND
    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_1" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

claude_md="${proj_1}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    content=$(cat "$claude_md")

    # Verify preamble was trimmed
    if [[ "$first_line" == "# TestProject" ]]; then
        pass "CLAUDE.md starts with heading (preamble trimmed)"
    else
        fail "CLAUDE.md first line is: $first_line (expected '# TestProject')"
    fi

    # Verify preamble text is NOT in the file
    if ! echo "$content" | grep -q "I've analyzed"; then
        pass "Preamble text 'I've analyzed' was removed"
    else
        fail "Preamble text still present in CLAUDE.md"
    fi

    # Verify content after heading is preserved
    if echo "$content" | grep -q "## Project Identity"; then
        pass "Content after heading preserved"
    else
        fail "Content after heading was lost"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 2: CLAUDE.md generation without preamble (normal case) ==="

proj_2="${TMPDIR_BASE}/proj_no_preamble"
mkdir -p "$proj_2/.tekhton"

cat > "${proj_2}/.tekhton/DESIGN.md" << 'EOF'
# DESIGN.md
## Overview
Test doc.
EOF

script_file=$(mktemp "${TMPDIR_BASE}/generate_no_preamble_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

_call_planning_batch() {
    # Return content that ALREADY starts with heading (no preamble)
    cat << 'CLAUDEEND'
# Normal CLAUDE.md
## Section 1
Content here.
CLAUDEEND
    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_2" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

claude_md="${proj_2}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    if [[ "$first_line" == "# Normal CLAUDE.md" ]]; then
        pass "Normal (non-preamble) CLAUDE.md generated correctly"
    else
        fail "CLAUDE.md first line is: $first_line"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 3: Multi-line preamble followed by CLAUDE.md ==="

proj_3="${TMPDIR_BASE}/proj_multiline_preamble"
mkdir -p "$proj_3/.tekhton"

cat > "${proj_3}/.tekhton/DESIGN.md" << 'EOF'
# DESIGN.md
## Content
Test.
EOF

script_file=$(mktemp "${TMPDIR_BASE}/generate_multiline_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

_call_planning_batch() {
    # Return content with multiple preamble lines
    cat << 'CLAUDEEND'
Based on your DESIGN.md, I've created a comprehensive CLAUDE.md.
This file includes all 12 sections as requested.
Here it is:

# ProjectName
## Project Identity
A description.

## Architecture
Pattern-based design.
CLAUDEEND
    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_3" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

claude_md="${proj_3}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    content=$(cat "$claude_md")

    if [[ "$first_line" == "# ProjectName" ]]; then
        pass "Multi-line preamble trimmed correctly"
    else
        fail "First line is: $first_line (expected '# ProjectName')"
    fi

    # Verify preamble lines are gone
    if ! echo "$content" | grep -q "Based on your DESIGN.md"; then
        pass "Multi-line preamble completely removed"
    else
        fail "Some preamble text still in CLAUDE.md"
    fi

    if echo "$content" | grep -q "## Project Identity"; then
        pass "Post-heading content preserved"
    else
        fail "Post-heading content lost"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 4: CLAUDE.md with varied preamble phrases ==="

proj_4="${TMPDIR_BASE}/proj_varied_preamble"
mkdir -p "$proj_4/.tekhton"

cat > "${proj_4}/.tekhton/DESIGN.md" << 'EOF'
# DESIGN.md
## Test
Simple test design.
EOF

script_file=$(mktemp "${TMPDIR_BASE}/generate_varied_XXXXXX.sh")
cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

_call_planning_batch() {
    # Return with various preamble phrases that Claude might use
    cat << 'CLAUDEEND'
Here is the generated CLAUDE.md file:

# MyApp
## Project Identity
MyApp is a web application.

## Architecture Philosophy
Clean architecture principles apply.
CLAUDEEND
    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

exit_code=$(TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_4" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null)

claude_md="${proj_4}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    first_line=$(head -1 "$claude_md")
    if [[ "$first_line" == "# MyApp" ]]; then
        pass "'Here is the generated' preamble trimmed"
    else
        fail "First line is: $first_line"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
