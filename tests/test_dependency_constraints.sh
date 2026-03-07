#!/usr/bin/env bash
# Test: Dependency constraint validation in build gate — P5
#       YAML command extraction, build gate pass/fail, error reporting
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
cd "$TMPDIR"

# --- Minimal pipeline environment ---
source "${TEKHTON_HOME}/lib/common.sh"

# Overrides: ANALYZE_CMD always passes, no compile check
ANALYZE_CMD="echo ok"
ANALYZE_ERROR_PATTERN="NEVER_MATCH_THIS_STRING"
BUILD_CHECK_CMD=""
BUILD_ERROR_PATTERN="ERROR"
DEPENDENCY_CONSTRAINTS_FILE=""

source "${TEKHTON_HOME}/lib/gates.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        FAIL=1
    fi
}

assert_file_not_exists() {
    local name="$1" file="$2"
    if [ -f "$file" ]; then
        echo "FAIL: $name — file '$file' should not exist"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: Build gate passes when no constraints configured
# =============================================================================
DEPENDENCY_CONSTRAINTS_FILE=""
run_build_gate "test-no-constraints" > /dev/null 2>&1
assert_eq "no constraints — passes" "0" "$?"

# =============================================================================
# Test 2: Build gate passes when constraint file does not exist
# =============================================================================
DEPENDENCY_CONSTRAINTS_FILE="nonexistent_constraints.yaml"
run_build_gate "test-missing-file" > /dev/null 2>&1
assert_eq "missing file — passes" "0" "$?"

# =============================================================================
# Test 3: Build gate passes when validation_command succeeds (exit 0)
# =============================================================================
cat > "${TMPDIR}/constraints.yaml" << 'EOF'
validation_command: "echo all good && exit 0"

layers:
  - name: "engine"
    must_not_depend_on:
      - "features"
EOF
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/constraints.yaml"
run_build_gate "test-passing-constraints" > /dev/null 2>&1
assert_eq "passing constraints — passes" "0" "$?"
assert_file_not_exists "passing — no BUILD_ERRORS.md" "BUILD_ERRORS.md"

# =============================================================================
# Test 4: Build gate fails when validation_command fails (exit 1)
# =============================================================================
cat > "${TMPDIR}/failing_constraints.yaml" << 'EOF'
validation_command: "echo 'VIOLATION: engine/rules imports features' && exit 1"

layers:
  - name: "engine/rules"
    must_not_depend_on:
      - "features"
EOF
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/failing_constraints.yaml"
local_exit=0
run_build_gate "test-failing-constraints" > /dev/null 2>&1 || local_exit=$?
assert_eq "failing constraints — fails" "1" "$local_exit"
assert_file_contains "failing — BUILD_ERRORS.md has violations" \
    "BUILD_ERRORS.md" "Dependency Constraint Violations"
assert_file_contains "failing — BUILD_ERRORS.md has violation text" \
    "BUILD_ERRORS.md" "engine/rules imports features"
rm -f BUILD_ERRORS.md

# =============================================================================
# Test 5: Build gate passes when validation_command is empty/omitted
# =============================================================================
cat > "${TMPDIR}/no_cmd_constraints.yaml" << 'EOF'
# No validation_command line — constraints are advisory only
layers:
  - name: "engine"
    must_not_depend_on:
      - "features"
EOF
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/no_cmd_constraints.yaml"
run_build_gate "test-no-cmd" > /dev/null 2>&1
assert_eq "no validation_command — passes" "0" "$?"

# =============================================================================
# Test 6: Build gate passes when validation_command is empty string
# =============================================================================
cat > "${TMPDIR}/empty_cmd_constraints.yaml" << 'EOF'
validation_command: ""

layers:
  - name: "engine"
    must_not_depend_on:
      - "features"
EOF
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/empty_cmd_constraints.yaml"
run_build_gate "test-empty-cmd" > /dev/null 2>&1
assert_eq "empty validation_command — passes" "0" "$?"

# =============================================================================
# Test 7: YAML parsing extracts command with surrounding quotes
# =============================================================================
cat > "${TMPDIR}/quoted_constraints.yaml" << 'EOF'
validation_command: "echo 'quoted command works' && exit 0"

layers: []
EOF
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/quoted_constraints.yaml"
run_build_gate "test-quoted-cmd" > /dev/null 2>&1
assert_eq "quoted command — passes" "0" "$?"

# =============================================================================
# Test 8: YAML parsing extracts command with single quotes
# =============================================================================
cat > "${TMPDIR}/single_quoted_constraints.yaml" << 'EOF'
validation_command: 'echo single-quoted && exit 0'

layers: []
EOF
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/single_quoted_constraints.yaml"
run_build_gate "test-single-quoted-cmd" > /dev/null 2>&1
assert_eq "single-quoted command — passes" "0" "$?"

# =============================================================================
# Test 9: Constraint violation output captured in BUILD_ERRORS.md
# =============================================================================
cat > "${TMPDIR}/violation_script.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "line1: violation A"
echo "line2: violation B"
exit 1
SCRIPT
chmod +x "${TMPDIR}/violation_script.sh"
cat > "${TMPDIR}/detail_constraints.yaml" << EOF
validation_command: "${TMPDIR}/violation_script.sh"

layers: []
EOF
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/detail_constraints.yaml"
run_build_gate "test-detail-capture" > /dev/null 2>&1 || true
assert_file_contains "detail — line1 captured" "BUILD_ERRORS.md" "violation A"
assert_file_contains "detail — line2 captured" "BUILD_ERRORS.md" "violation B"
rm -f BUILD_ERRORS.md

# =============================================================================
# Test 10: Architect prompt includes constraints when file exists
# =============================================================================
source "${TEKHTON_HOME}/lib/prompts.sh"

# Set up all required template variables
PROJECT_NAME="TestProject"
TASK="test task"
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
ARCHITECTURE_FILE="ARCHITECTURE.md"
PROJECT_RULES_FILE="CLAUDE.md"
ARCHITECTURE_CONTENT="## Layers"
ARCHITECTURE_LOG_CONTENT="## ADL"
DRIFT_LOG_CONTENT="## Drift observations"
DRIFT_OBSERVATION_COUNT="3"
DEPENDENCY_CONSTRAINTS_CONTENT="layers:\n  - name: engine\n    must_not_depend_on: features"

rendered=$(render_prompt "architect")
if echo "$rendered" | grep -q "Dependency Constraints"; then
    assert_eq "architect prompt includes constraints" "0" "0"
else
    echo "FAIL: architect prompt missing Dependency Constraints section"
    FAIL=1
fi

# =============================================================================
# Test 11: Architect prompt excludes constraints when empty
# =============================================================================
DEPENDENCY_CONSTRAINTS_CONTENT=""
rendered=$(render_prompt "architect")
if echo "$rendered" | grep -q "Dependency Constraints"; then
    echo "FAIL: architect prompt should NOT include Dependency Constraints when empty"
    FAIL=1
fi

# =============================================================================
# Test 12: Sample Dart script passes on clean directory
# =============================================================================
mkdir -p "${TMPDIR}/lib/engine/rules"
cat > "${TMPDIR}/lib/engine/rules/move_validator.dart" << 'DART'
import 'package:lonn/engine/state/game_state.dart';
import 'package:lonn/core/config/config_models.dart';
DART
if bash "${TEKHTON_HOME}/examples/check_imports_dart.sh" > /dev/null 2>&1; then
    assert_eq "dart sample — clean imports pass" "0" "0"
else
    echo "FAIL: dart sample script failed on clean imports"
    FAIL=1
fi

# =============================================================================
# Test 13: Sample Dart script catches violations
# =============================================================================
cat > "${TMPDIR}/lib/engine/rules/bad_import.dart" << 'DART'
import 'package:lonn/features/game/providers/game_provider.dart';
DART
dart_exit=0
bash "${TEKHTON_HOME}/examples/check_imports_dart.sh" > /dev/null 2>&1 || dart_exit=$?
assert_eq "dart sample — violation detected" "1" "$dart_exit"
rm "${TMPDIR}/lib/engine/rules/bad_import.dart"

# =============================================================================
# Report results
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "All dependency constraint tests passed (13/13)"
    exit 0
else
    echo "Some dependency constraint tests FAILED"
    exit 1
fi
