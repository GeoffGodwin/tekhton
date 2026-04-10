#!/usr/bin/env bash
set -euo pipefail

# Test: Health scoring baseline for greenfield projects
# Verifies that:
# 1. Greenfield projects (no source files) score near 0
# 2. The health report includes "Pre-code baseline" callout
# 3. Code quality and dependency health are 0 when appropriate

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME="$TEST_DIR"
TEMP_DIR=""

trap 'rm -rf "$TEMP_DIR"' EXIT

# Create temp directory for this test
TEMP_DIR=$(mktemp -d)

# Source the library
source "$TEST_DIR/lib/common.sh"
source "$TEST_DIR/lib/health_checks_infra.sh"
source "$TEST_DIR/lib/health_checks.sh"
source "$TEST_DIR/lib/health.sh"

# Test 1: Empty directory gets 0 code quality score
echo "Test 1: Empty directory scores 0 code quality..."
TEST1_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEMP_DIR'" EXIT

# Initialize git to enable proper source file detection
cd "$TEST1_DIR" && git init -q

# Call _check_code_quality directly
RESULT=$(_check_code_quality "$TEST1_DIR" 2>/dev/null || true)

# Extract score (second field, pipe-delimited)
SCORE=$(echo "$RESULT" | cut -d'|' -f2)

if [[ "$SCORE" == "0" ]]; then
    echo "✓ Test 1 PASSED: Code quality score is 0 for empty directory"
else
    echo "✗ Test 1 FAILED: Expected score 0, got $SCORE"
    exit 1
fi

# Test 2: Empty directory gets 0 dependency health score (no manifest)
echo "Test 2: Empty directory with no manifest scores 0 dependency health..."
TEST2_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEMP_DIR'" EXIT

cd "$TEST2_DIR" && git init -q

RESULT=$(_check_dependency_health "$TEST2_DIR" 2>/dev/null || true)
SCORE=$(echo "$RESULT" | cut -d'|' -f2)

if [[ "$SCORE" == "0" ]]; then
    echo "✓ Test 2 PASSED: Dependency health score is 0 for empty directory"
else
    echo "✗ Test 2 FAILED: Expected score 0, got $SCORE"
    exit 1
fi

# Test 3: Health report includes "Pre-code baseline" callout for greenfield
echo "Test 3: Health report includes Pre-code baseline callout..."
TEST3_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEST3_DIR' '$TEMP_DIR'" EXIT

cd "$TEST3_DIR" && git init -q

# Call reassess_project_health which generates the report
PROJECT_DIR="$TEST3_DIR"
HEALTH_REPORT_FILE="HEALTH_REPORT.md"
reassess_project_health "$TEST3_DIR" >/dev/null 2>&1 || true

REPORT_FILE="$TEST3_DIR/$HEALTH_REPORT_FILE"

if [[ -f "$REPORT_FILE" ]]; then
    if grep -q "Pre-code baseline" "$REPORT_FILE"; then
        echo "✓ Test 3 PASSED: Health report contains Pre-code baseline callout"
    else
        echo "✗ Test 3 FAILED: Pre-code baseline callout not found in report"
        cat "$REPORT_FILE"
        exit 1
    fi
else
    echo "✗ Test 3 FAILED: Health report not generated"
    exit 1
fi

# Test 4: Greenfield composite score is low (not inflated)
echo "Test 4: Greenfield composite score is low..."
TEST4_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEST3_DIR' '$TEST4_DIR' '$TEMP_DIR'" EXIT

cd "$TEST4_DIR" && git init -q

PROJECT_DIR="$TEST4_DIR"
HEALTH_BASELINE_FILE=".claude/HEALTH_BASELINE.json"
reassess_project_health "$TEST4_DIR" >/dev/null 2>&1 || true

BASELINE_FILE="$TEST4_DIR/$HEALTH_BASELINE_FILE"

if [[ -f "$BASELINE_FILE" ]]; then
    # Extract composite score
    COMPOSITE=$(grep -oE '"composite"\s*:\s*[0-9]+' "$BASELINE_FILE" | grep -oE '[0-9]+' | head -1)

    # Greenfield projects should score very low (roughly 0-20)
    # A score above 35 would indicate the false inflation bug
    if [[ -n "$COMPOSITE" ]] && [[ "$COMPOSITE" -lt 35 ]]; then
        echo "✓ Test 4 PASSED: Greenfield composite score is low ($COMPOSITE/100)"
    else
        echo "✗ Test 4 FAILED: Greenfield composite score is inflated: $COMPOSITE"
        exit 1
    fi
else
    echo "✗ Test 4 FAILED: Health baseline file not generated"
    exit 1
fi

# Test 5: Project with README but no code still gets Pre-code baseline callout
echo "Test 5: README-only project gets Pre-code baseline callout..."
TEST5_DIR=$(mktemp -d)
trap "rm -rf '$TEST1_DIR' '$TEST2_DIR' '$TEST3_DIR' '$TEST4_DIR' '$TEST5_DIR' '$TEMP_DIR'" EXIT

cd "$TEST5_DIR" && git init -q

# Create a README but no code
echo "# My Project" > "$TEST5_DIR/README.md"
git add README.md 2>/dev/null || true

PROJECT_DIR="$TEST5_DIR"
HEALTH_REPORT_FILE="HEALTH_REPORT.md"
reassess_project_health "$TEST5_DIR" >/dev/null 2>&1 || true

REPORT_FILE="$TEST5_DIR/$HEALTH_REPORT_FILE"

if [[ -f "$REPORT_FILE" ]]; then
    if grep -q "Pre-code baseline" "$REPORT_FILE"; then
        echo "✓ Test 5 PASSED: README-only project shows Pre-code baseline callout"
    else
        echo "✗ Test 5 FAILED: Pre-code baseline callout not found for README-only project"
        exit 1
    fi
else
    echo "✗ Test 5 FAILED: Health report not generated"
    exit 1
fi

echo ""
echo "All tests passed!"
exit 0
