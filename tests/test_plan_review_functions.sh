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
# DAG defaults (config_defaults.sh needs _clamp_config_value from config.sh)
: "${MILESTONE_DAG_ENABLED:=true}"
: "${MILESTONE_DIR:=.claude/milestones}"
: "${MILESTONE_MANIFEST:=MANIFEST.cfg}"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_io.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"

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

if echo "$output" | grep -q "No milestones found"; then
    pass "_display_milestone_summary() warns when no milestones found"
else
    fail "_display_milestone_summary() should warn about no milestones"
fi

echo "=== Test _display_milestone_summary() with DAG milestones ==="

# Test 4: DAG milestones are read from MANIFEST.cfg
MILESTONE_DAG_ENABLED="true"
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
mkdir -p "$PROJECT_DIR/.claude/milestones"
cat > "$PROJECT_DIR/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Setup Foundation|pending||m01-setup.md|foundation
m02|Build Feature|pending|m01|m02-feature.md|core
m03|Final Polish|pending|m02|m03-polish.md|core
EOF

# CLAUDE.md has no inline milestones — DAG should supply them
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# DAGProject

No inline milestones here.
EOF

output=$(_display_milestone_summary "$PROJECT_DIR/CLAUDE.md" 2>&1 | head -20)

if echo "$output" | grep -q "Milestones: 3"; then
    pass "_display_milestone_summary() counts DAG milestones correctly"
else
    fail "_display_milestone_summary() should show 3 DAG milestones, got: $(echo "$output" | grep 'Milestones:')"
fi

if echo "$output" | grep -q "DAGProject"; then
    pass "_display_milestone_summary() shows project name with DAG milestones"
else
    fail "_display_milestone_summary() missing project name with DAG milestones"
fi

if echo "$output" | grep -q "Setup Foundation"; then
    pass "_display_milestone_summary() shows DAG milestone title"
else
    fail "_display_milestone_summary() missing DAG milestone title"
fi

# Test 5: DAG mode falls back to CLAUDE.md when no manifest exists
rm -rf "$PROJECT_DIR/.claude/milestones"
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# FallbackProject

## Milestone 1: Inline Feature
## Milestone 2: Another Feature
EOF

output=$(_display_milestone_summary "$PROJECT_DIR/CLAUDE.md" 2>&1 | head -20)

if echo "$output" | grep -q "Milestones: 2"; then
    pass "_display_milestone_summary() falls back to inline milestones when no manifest"
else
    fail "_display_milestone_summary() should fall back to inline milestones, got: $(echo "$output" | grep 'Milestones:')"
fi

# Test 6: DAG disabled uses inline milestones
MILESTONE_DAG_ENABLED="false"
mkdir -p "$PROJECT_DIR/.claude/milestones"
cat > "$PROJECT_DIR/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Only|pending||m01.md|
EOF
cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# MixedProject

## Milestone 1: Inline Only
EOF

output=$(_display_milestone_summary "$PROJECT_DIR/CLAUDE.md" 2>&1 | head -20)

if echo "$output" | grep -q "Milestones: 1" && echo "$output" | grep -q "Inline Only"; then
    pass "_display_milestone_summary() uses inline milestones when DAG disabled"
else
    fail "_display_milestone_summary() should use inline milestones when DAG disabled"
fi

# Test 7: Empty manifest (DAG enabled, manifest exists but has no entries)
# This is the coverage gap: manifest file exists but contains zero milestones
MILESTONE_DAG_ENABLED="true"
mkdir -p "$PROJECT_DIR/.claude/milestones"
cat > "$PROJECT_DIR/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
EOF

cat > "$PROJECT_DIR/CLAUDE.md" << 'EOF'
# EmptyDAGProject

## Milestone 1: Fallback Feature
## Milestone 2: Another Fallback
EOF

output=$(_display_milestone_summary "$PROJECT_DIR/CLAUDE.md" 2>&1 | head -20)

if echo "$output" | grep -q "Milestones: 2"; then
    pass "_display_milestone_summary() falls back to inline when manifest is empty"
else
    fail "_display_milestone_summary() should fall back to 2 inline milestones when manifest is empty, got: $(echo "$output" | grep 'Milestones:')"
fi

if echo "$output" | grep -q "Fallback Feature"; then
    pass "_display_milestone_summary() displays inline milestone titles when manifest is empty"
else
    fail "_display_milestone_summary() should show inline milestone title when manifest is empty"
fi

# Reset for any remaining tests
MILESTONE_DAG_ENABLED="true"
rm -rf "$PROJECT_DIR/.claude/milestones"

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
