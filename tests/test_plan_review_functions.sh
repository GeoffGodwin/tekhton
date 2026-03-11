#!/usr/bin/env bash
# Test: Planning phase milestone review helper functions
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export PROJECT_DIR="/tmp/tekhton_review_test"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Setup and cleanup
setup() {
    mkdir -p "$PROJECT_DIR"
}

cleanup() {
    rm -rf "$PROJECT_DIR"
}

trap cleanup EXIT

# Source libraries
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

setup

echo "=== Test _display_milestone_summary() ==="

# Test 1: Display with valid milestones (capture output)
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# TestProject

## Milestone 1: Feature One
## Milestone 2: Feature Two
EOF

output=$(_display_milestone_summary "$PROJECT_DIR/CLAUDE.md" 2>&1 | head -20)

if echo "$output" | grep -q "TestProject"; then
    pass "_display_milestone_summary() includes project name"
else
    fail "_display_milestone_summary() missing project name"
fi

if echo "$output" | grep -q "Milestones: 2"; then
    pass "_display_milestone_summary() shows correct milestone count"
else
    fail "_display_milestone_summary() incorrect milestone count in output"
fi

# Test 2: Display with menu options
output=$(_display_milestone_summary "$PROJECT_DIR/CLAUDE.md" 2>&1)

if echo "$output" | grep -q '\[y\]'; then
    pass "_display_milestone_summary() includes [y] option"
else
    fail "_display_milestone_summary() missing [y] option"
fi

if echo "$output" | grep -q '\[e\]'; then
    pass "_display_milestone_summary() includes [e] option"
else
    fail "_display_milestone_summary() missing [e] option"
fi

if echo "$output" | grep -q '\[r\]'; then
    pass "_display_milestone_summary() includes [r] option"
else
    fail "_display_milestone_summary() missing [r] option"
fi

if echo "$output" | grep -q '\[n\]'; then
    pass "_display_milestone_summary() includes [n] option"
else
    fail "_display_milestone_summary() missing [n] option"
fi

# Test 3: No milestones warning
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# Project

Content without milestones.
EOF

output=$(_display_milestone_summary "$PROJECT_DIR/CLAUDE.md" 2>&1)

if echo "$output" | grep -q "No milestone headings found"; then
    pass "_display_milestone_summary() warns when no milestones found"
else
    fail "_display_milestone_summary() should warn about no milestones"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
