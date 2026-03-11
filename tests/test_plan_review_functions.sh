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

echo "=== Test _extract_project_name() ==="

# Test 1: Extract from first # heading
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# MyAwesomeProject

Some content here.
EOF

result=$(_extract_project_name "$PROJECT_DIR/CLAUDE.md")
if [ "$result" = "MyAwesomeProject" ]; then
    pass "_extract_project_name() extracts from # heading"
else
    fail "_extract_project_name() expected 'MyAwesomeProject', got '$result'"
fi

# Test 2: Fall back to directory name when no heading
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
Some content without a heading.
## Milestone 1: Do something
EOF

result=$(_extract_project_name "$PROJECT_DIR/CLAUDE.md")
if [ "$result" = "tekhton_review_test" ]; then
    pass "_extract_project_name() falls back to directory name"
else
    fail "_extract_project_name() expected 'tekhton_review_test', got '$result'"
fi

# Test 3: Ignore # in middle of line
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
This has # in the middle.
# RealProjectName
## Milestone 1
EOF

result=$(_extract_project_name "$PROJECT_DIR/CLAUDE.md")
if [ "$result" = "RealProjectName" ]; then
    pass "_extract_project_name() finds first # heading correctly"
else
    fail "_extract_project_name() expected 'RealProjectName', got '$result'"
fi

echo
echo "=== Test _extract_milestones() ==="

# Test 1: Extract ## Milestone headings
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# Project

## Milestone 1: Setup
## Milestone 2: Core Feature
## Milestone 3: Testing
EOF

result=$(_extract_milestones "$PROJECT_DIR/CLAUDE.md")
count=$(echo "$result" | grep -c '.' || true)

if [ "$count" -eq 3 ]; then
    pass "_extract_milestones() found 3 milestones"
else
    fail "_extract_milestones() expected 3 milestones, found $count"
fi

if echo "$result" | grep -q "Milestone 1: Setup"; then
    pass "_extract_milestones() includes Milestone 1"
else
    fail "_extract_milestones() missing Milestone 1"
fi

# Test 2: Extract ### Milestone headings (three hashes)
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# Project

### Milestone 1: Phase 1
### Milestone 2: Phase 2
EOF

result=$(_extract_milestones "$PROJECT_DIR/CLAUDE.md")
count=$(echo "$result" | grep -c '.' || true)

if [ "$count" -eq 2 ]; then
    pass "_extract_milestones() found 2 ### milestones"
else
    fail "_extract_milestones() expected 2 ### milestones, found $count"
fi

# Test 3: No milestones
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# Project

Some content without milestones.
EOF

result=$(_extract_milestones "$PROJECT_DIR/CLAUDE.md")
count=$(echo "$result" | grep -c '.' || true)

if [ "$count" -eq 0 ]; then
    pass "_extract_milestones() returns empty for no milestones"
else
    fail "_extract_milestones() expected 0 milestones, found $count"
fi

# Test 4: Mix of ## and ### milestones
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# Project

## Milestone 1: Feature A
### Milestone 2: Sub-feature
## Milestone 3: Feature B
EOF

result=$(_extract_milestones "$PROJECT_DIR/CLAUDE.md")
count=$(echo "$result" | grep -c '.' || true)

if [ "$count" -eq 3 ]; then
    pass "_extract_milestones() finds both ## and ### headings"
else
    fail "_extract_milestones() expected 3 mixed milestones, found $count"
fi

echo
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
