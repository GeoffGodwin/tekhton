#!/usr/bin/env bash
# Test: init_synthesize.sh _synthesize_claude() — marker appending
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Helper: Run _synthesize_claude in subshell with mocked _call_planning_batch
run_synthesize_with_mock() {
    local project_dir="$1"

    local script_file
    script_file=$(mktemp "${TMPDIR_BASE}/synthesize_marker_XXXXXX.sh")

    cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

# Mock _call_planning_batch to return CLAUDE.md content
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    # Return CLAUDE.md content with optional preamble
    cat << 'EOF'
Some preamble text that is not a heading
More preamble
# Tekhton CLAUDE.md
## Project Identity
Generated CLAUDE.md from init synthesis.

## Non-Negotiable Rules
- Rule 1

## Milestone Plan
### M1: Setup
Setup phase.
EOF

    return 0
}

# Mock _trim_document_preamble (from lib/plan.sh)
_trim_document_preamble() {
    # Remove lines before first top-level heading
    awk '/^# / { found=1 } found { print }'
}

source "${TEKHTON_HOME}/stages/init_synthesize.sh"

_synthesize_claude "$1" > /dev/null 2>&1
echo $?
INNERSCRIPT

    TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$project_dir" \
    DESIGN_FILE="DESIGN.md" \
    TEKHTON_DIR=".tekhton" \
    SYNTHESIS_MODEL="test-model" \
    SYNTHESIS_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" "$project_dir" 2>/dev/null < /dev/null
}

echo "=== Test 1: _synthesize_claude appends marker correctly ==="

proj_1="${TMPDIR_BASE}/proj_synthesize_marker"
mkdir -p "$proj_1"

# Create DESIGN.md (required by _synthesize_claude)
cat > "${proj_1}/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
Test design document.

## Core Features
- Feature 1

## Architecture
Simple.

## Implementation Plan
One phase.
EOF

# Run synthesis
run_synthesize_with_mock "$proj_1" > /dev/null

claude_md="${proj_1}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    content=$(cat "$claude_md")

    # Verify marker is present
    if echo "$content" | grep -q '<!-- tekhton-managed -->'; then
        pass "Marker is appended to CLAUDE.md"
    else
        fail "Marker not found in CLAUDE.md"
    fi

    # Verify marker appears exactly once
    marker_count=$(echo "$content" | grep -c '<!-- tekhton-managed -->' || true)
    if [[ $marker_count -eq 1 ]]; then
        pass "Marker appears exactly once"
    else
        fail "Marker appears $marker_count times (expected 1)"
    fi

    # Verify marker is at the end
    last_line=$(tail -1 "$claude_md")
    if [[ "$last_line" == "<!-- tekhton-managed -->" ]]; then
        pass "Marker is at the end of file"
    else
        fail "Marker not at end (last line: $last_line)"
    fi

    # Verify preamble was trimmed
    first_line=$(head -1 "$claude_md")
    if [[ "$first_line" == "# Tekhton CLAUDE.md" ]]; then
        pass "Preamble correctly trimmed before first heading"
    else
        fail "Preamble not trimmed (first line: $first_line)"
    fi

    # Verify content is present
    if echo "$content" | grep -q "Generated CLAUDE.md from init synthesis"; then
        pass "Generated content is present"
    else
        fail "Generated content not found"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 2: Marker appending with complex content ==="

proj_2="${TMPDIR_BASE}/proj_complex_synthesis"
mkdir -p "$proj_2"

# Create DESIGN.md
cat > "${proj_2}/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
Complex design.

## Core Features
- F1
- F2

## Architecture
Complex arch.

## Implementation Plan
Multiple phases.
EOF

# Update script to return more complex content
script_file=$(mktemp "${TMPDIR_BASE}/synthesize_complex_XXXXXX.sh")

cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

# Mock with multiline complex content
_call_planning_batch() {
    cat << 'EOF'
# Tekhton CLAUDE.md
## Project Identity
This is a complex CLAUDE.md with multiple sections.

## Non-Negotiable Rules
1. Rule one
2. Rule two
3. Rule three

## Milestone Plan
### M1: Planning
Initial planning.

### M2: Development
Main development work.

### M3: Testing
Testing phase.

### M4: Deployment
Deployment.

## Architecture Guidelines
The system uses a modular architecture.
- Layer 1: Frontend
- Layer 2: Backend
- Layer 3: Data

## Testing Strategy
Unit tests + Integration tests + e2e tests.
EOF

    return 0
}

_trim_document_preamble() {
    awk '/^# / { found=1 } found { print }'
}

source "${TEKHTON_HOME}/stages/init_synthesize.sh"

_synthesize_claude "$1" > /dev/null 2>&1
echo $?
INNERSCRIPT

TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_2" \
    DESIGN_FILE="DESIGN.md" \
    TEKHTON_DIR=".tekhton" \
    SYNTHESIS_MODEL="test-model" \
    SYNTHESIS_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" "$proj_2" 2>/dev/null < /dev/null

claude_md="${proj_2}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    content=$(cat "$claude_md")

    # Verify complex content is intact
    if echo "$content" | grep -q "modular architecture"; then
        pass "Complex content preserved (architecture section)"
    else
        fail "Architecture section missing"
    fi

    if echo "$content" | grep -q "Integration tests"; then
        pass "Complex content preserved (testing section)"
    else
        fail "Testing section missing"
    fi

    # Verify marker is still at the end despite complex content
    last_line=$(tail -1 "$claude_md")
    if [[ "$last_line" == "<!-- tekhton-managed -->" ]]; then
        pass "Marker at end despite complex multiline content"
    else
        fail "Marker not at end with complex content"
    fi

    # Verify line count includes the marker
    line_count=$(wc -l < "$claude_md" | tr -d '[:space:]')
    # Expected: 35 lines of complex content + 1 marker line = 36 lines
    if [[ $line_count -gt 30 ]]; then
        pass "File has expected line count for complex document"
    else
        fail "File has $line_count lines (expected >30)"
    fi
else
    fail "CLAUDE.md was not created for complex content test"
fi

echo ""
echo "=== Test 3: Marker appending with preamble present ==="

proj_3="${TMPDIR_BASE}/proj_preamble_synthesis"
mkdir -p "$proj_3"

# Create DESIGN.md
cat > "${proj_3}/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
Preamble test design.

## Core Features
- F1

## Architecture
Simple.

## Implementation Plan
Phase 1.
EOF

script_file=$(mktemp "${TMPDIR_BASE}/synthesize_preamble_XXXXXX.sh")

cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

_call_planning_batch() {
    # Return content with significant preamble
    cat << 'EOF'
This is preamble line 1
This is preamble line 2
This is preamble line 3

# Tekhton CLAUDE.md
## Project Identity
The actual content starts here.
EOF

    return 0
}

_trim_document_preamble() {
    awk '/^# / { found=1 } found { print }'
}

source "${TEKHTON_HOME}/stages/init_synthesize.sh"

_synthesize_claude "$1" > /dev/null 2>&1
echo $?
INNERSCRIPT

TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$proj_3" \
    DESIGN_FILE="DESIGN.md" \
    TEKHTON_DIR=".tekhton" \
    SYNTHESIS_MODEL="test-model" \
    SYNTHESIS_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" "$proj_3" 2>/dev/null < /dev/null

claude_md="${proj_3}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    content=$(cat "$claude_md")
    first_line=$(head -1 "$claude_md")

    # Verify preamble was trimmed
    if [[ "$first_line" == "# Tekhton CLAUDE.md" ]]; then
        pass "Preamble trimmed correctly (first line is heading)"
    else
        fail "Preamble not trimmed (first line: $first_line)"
    fi

    # Verify preamble lines don't exist in file
    if ! echo "$content" | grep -q "This is preamble"; then
        pass "Preamble content removed from file"
    else
        fail "Preamble content still in file"
    fi

    # Verify marker is still present and at end
    last_line=$(tail -1 "$claude_md")
    if [[ "$last_line" == "<!-- tekhton-managed -->" ]]; then
        pass "Marker appended after preamble trim"
    else
        fail "Marker not at end after preamble trim"
    fi
else
    fail "CLAUDE.md not created for preamble test"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
