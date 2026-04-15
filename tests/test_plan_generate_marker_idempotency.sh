#!/usr/bin/env bash
# Test: plan_generate() marker idempotency — CLAUDE.md already has marker
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Helper: Run run_plan_generate() in subshell with mocked _call_planning_batch
run_generate_with_preexisting_marker() {
    local project_dir="$1"

    local script_file
    script_file=$(mktemp "${TMPDIR_BASE}/generate_marker_XXXXXX.sh")

    cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

# Mock _call_planning_batch to return new content
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    # Return fresh content (heading-started)
    cat << 'EOF'
# Tekhton CLAUDE.md
## Project Identity
This is new content from Claude.

## Non-Negotiable Rules
- Rule 1
- Rule 2

## Milestone Plan
### M1: Setup
Initial setup phase.

### M2: Development
Core development phase.
EOF

    return 0
}

source "${TEKHTON_HOME}/stages/plan_generate.sh"

run_plan_generate > /dev/null 2>&1
echo $?
INNERSCRIPT

    TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$project_dir" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE=".tekhton/DESIGN.md" \
    PLAN_GENERATION_MODEL="test-model" \
    PLAN_GENERATION_MAX_TURNS="1" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" 2>/dev/null < /dev/null
}

echo "=== Test 1: CLAUDE.md with preexisting marker (idempotency) ==="

proj_1="${TMPDIR_BASE}/proj_existing_marker"
mkdir -p "$proj_1/.tekhton"

# Create DESIGN.md
cat > "${proj_1}/.tekhton/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
Test design document.

## Core Features
- Feature 1
- Feature 2

## Architecture
Simple architecture.

## Implementation Plan
Phase 1: Setup
Phase 2: Development
Phase 3: Testing
EOF

# Pre-create CLAUDE.md with the marker already present
cat > "${proj_1}/CLAUDE.md" << 'EOF'
# Old Tekhton CLAUDE.md
## Project Identity
This is old content.
<!-- tekhton-managed -->
EOF

# Run plan_generate — should replace content but not duplicate marker
exit_code=$(run_generate_with_preexisting_marker "$proj_1")
claude_md="${proj_1}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    content=$(cat "$claude_md")

    # Count how many times the marker appears
    marker_count=$(echo "$content" | grep -c '<!-- tekhton-managed -->' || true)

    if [[ $marker_count -eq 1 ]]; then
        pass "Marker appears exactly once (idempotency guard works)"
    else
        fail "Marker appears $marker_count times (should be 1)"
    fi

    # Verify the new content is present
    if echo "$content" | grep -q "new content from Claude"; then
        pass "New content from Claude is present in file"
    else
        fail "New content from Claude not found in file"
    fi

    # Verify old content is replaced
    if ! echo "$content" | grep -q "This is old content"; then
        pass "Old content was replaced by new generation"
    else
        fail "Old content still present (should be replaced)"
    fi

    # Verify marker is at the end
    last_line=$(tail -1 "$claude_md")
    if [[ "$last_line" == "<!-- tekhton-managed -->" ]]; then
        pass "Marker is at the end of file"
    else
        fail "Marker is not at end (last line: $last_line)"
    fi

    # Verify first line is correct
    first_line=$(head -1 "$claude_md")
    if [[ "$first_line" == "# Tekhton CLAUDE.md" ]]; then
        pass "File starts with correct heading"
    else
        fail "File first line incorrect: $first_line"
    fi
else
    fail "CLAUDE.md was not created"
fi

echo ""
echo "=== Test 2: Normal case — no preexisting marker ==="

proj_2="${TMPDIR_BASE}/proj_no_preexisting_marker"
mkdir -p "$proj_2/.tekhton"

# Create DESIGN.md
cat > "${proj_2}/.tekhton/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
Fresh design document.

## Core Features
- Feature 1

## Architecture
Simple.

## Implementation Plan
One phase.
EOF

# Run without preexisting marker
exit_code=$(run_generate_with_preexisting_marker "$proj_2")
claude_md="${proj_2}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    content=$(cat "$claude_md")
    marker_count=$(echo "$content" | grep -c '<!-- tekhton-managed -->' || true)

    if [[ $marker_count -eq 1 ]]; then
        pass "Marker added (no duplicate when marker doesn't exist)"
    else
        fail "Marker count is $marker_count (expected 1)"
    fi

    last_line=$(tail -1 "$claude_md")
    if [[ "$last_line" == "<!-- tekhton-managed -->" ]]; then
        pass "Marker correctly positioned at end"
    else
        fail "Marker not at end"
    fi
else
    fail "CLAUDE.md not created"
fi

echo ""
echo "=== Test 3: CLAUDE.md with marker in middle (malformed) ==="

proj_3="${TMPDIR_BASE}/proj_marker_in_middle"
mkdir -p "$proj_3/.tekhton"

# Create DESIGN.md
cat > "${proj_3}/.tekhton/DESIGN.md" << 'EOF'
# DESIGN.md

## Project Overview
Design.

## Core Features
- F1

## Architecture
Simple.

## Implementation Plan
Phase 1.
EOF

# Pre-create CLAUDE.md with marker in the middle (malformed)
cat > "${proj_3}/CLAUDE.md" << 'EOF'
# Old CLAUDE
<!-- tekhton-managed -->
Some content after the marker
More content
EOF

# Run plan_generate
exit_code=$(run_generate_with_preexisting_marker "$proj_3")
claude_md="${proj_3}/CLAUDE.md"

if [[ -f "$claude_md" ]]; then
    content=$(cat "$claude_md")
    marker_count=$(echo "$content" | grep -c '<!-- tekhton-managed -->' || true)

    if [[ $marker_count -eq 1 ]]; then
        pass "Marker deduplicated (only one instance despite malformed input)"
    else
        fail "Marker count is $marker_count (expected 1)"
    fi

    last_line=$(tail -1 "$claude_md")
    if [[ "$last_line" == "<!-- tekhton-managed -->" ]]; then
        pass "Marker moved to end of file"
    else
        fail "Marker not at end after replacement"
    fi
else
    fail "CLAUDE.md not created"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
