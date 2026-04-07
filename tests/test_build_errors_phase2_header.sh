#!/usr/bin/env bash
set -euo pipefail

# Test: BUILD_ERRORS.md header when Phase 2 (compile) fails after Phase 1 (analyze) passes
# Detects whether the fix in gates.sh for Phase 2 header consistency is working.
# The fix checks if BUILD_ERRORS.md exists before writing the header, but has a flaw:
# the file check is INSIDE the append redirect block. Bash opens the file before
# the block executes, so the condition always finds the file exists.

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(mktemp -d)"
trap 'rm -rf "$PROJECT_DIR"' EXIT

# Source required libraries
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/error_patterns.sh"
source "${TEKHTON_HOME}/lib/error_patterns_remediation.sh"

# Setup: Mock config and commands
export ANALYZE_CMD="echo 'OK'"
export ANALYZE_ERROR_PATTERN="ERROR_PATTERN_THAT_WILL_NOT_MATCH"
export BUILD_CHECK_CMD="echo 'compilation error: undefined reference'"
export BUILD_ERROR_PATTERN="compilation error"
export BUILD_GATE_TIMEOUT=60
export BUILD_GATE_ANALYZE_TIMEOUT=10
export BUILD_GATE_COMPILE_TIMEOUT=10

# Mock classify_build_errors_all to simulate compile errors
classify_build_errors_all() {
    echo "code|code||Unclassified build error"
}
export -f classify_build_errors_all

cd "$PROJECT_DIR"

# Source gates.sh after setup
source "${TEKHTON_HOME}/lib/gates.sh"
source "${TEKHTON_HOME}/lib/gates_phases.sh"
source "${TEKHTON_HOME}/lib/gates_ui.sh"

# Test: Run build gate with Phase 1 passing and Phase 2 failing
if run_build_gate "test-phase2" 2>/dev/null; then
    echo "FAIL: Expected build gate to fail but it passed"
    exit 1
fi

# Verify BUILD_ERRORS.md exists
if [[ ! -f BUILD_ERRORS.md ]]; then
    echo "FAIL: BUILD_ERRORS.md was not created"
    exit 1
fi

# Check for canonical header — this is where the bug manifests
if ! grep -q "^# Build Errors" BUILD_ERRORS.md; then
    # Bug confirmed: the header is NOT written because the file check
    # happens AFTER bash opens the file for appending (>>)
    echo "FAIL: Canonical '# Build Errors' header not written (implementation bug in gates.sh line 170)"
    exit 1
fi

# The following checks should pass if the header is correctly written
if ! grep -q "^## Stage" BUILD_ERRORS.md; then
    echo "FAIL: '## Stage' section not found"
    exit 1
fi

echo "PASS"
exit 0
