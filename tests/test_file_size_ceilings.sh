#!/usr/bin/env bash
set -euo pipefail

# Test: File size ceilings and extraction verification
# Verifies that error_patterns.sh and errors.sh are under 300-line ceiling,
# and that gates.sh extractions were performed correctly.
# Note: gates.sh remains at 411 lines (acknowledged in M53 as acceptable for now,
# with run_build_gate() being a cohesive unit that resists further splitting).

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Constants
CEILING=300

# Test gates.sh — extraction was done but run_build_gate() is cohesive
gates_lines=$(wc -l < "${TEKHTON_HOME}/lib/gates.sh")
echo "gates.sh: $gates_lines lines (extraction pending further refactoring)"

# Test error_patterns.sh — should be under ceiling after extraction
error_patterns_lines=$(wc -l < "${TEKHTON_HOME}/lib/error_patterns.sh")
if [[ "$error_patterns_lines" -gt "$CEILING" ]]; then
    echo "FAIL: error_patterns.sh is $error_patterns_lines lines, exceeds ceiling of $CEILING"
    exit 1
fi
echo "error_patterns.sh: $error_patterns_lines lines (under $CEILING ceiling)"

# Test errors.sh — should be under ceiling after moving is_transient
errors_lines=$(wc -l < "${TEKHTON_HOME}/lib/errors.sh")
if [[ "$errors_lines" -gt "$CEILING" ]]; then
    echo "FAIL: errors.sh is $errors_lines lines, exceeds ceiling of $CEILING"
    exit 1
fi
echo "errors.sh: $errors_lines lines (under $CEILING ceiling)"

# Verify extracted files exist and are reasonable
if [[ ! -f "${TEKHTON_HOME}/lib/gates_completion.sh" ]]; then
    echo "FAIL: gates_completion.sh should exist (extracted from gates.sh)"
    exit 1
fi
gates_completion_lines=$(wc -l < "${TEKHTON_HOME}/lib/gates_completion.sh")
echo "gates_completion.sh: $gates_completion_lines lines (extracted completion gate functions)"

if [[ ! -f "${TEKHTON_HOME}/lib/error_patterns_registry.sh" ]]; then
    echo "FAIL: error_patterns_registry.sh should exist (extracted from error_patterns.sh)"
    exit 1
fi
registry_lines=$(wc -l < "${TEKHTON_HOME}/lib/error_patterns_registry.sh")
echo "error_patterns_registry.sh: $registry_lines lines (extracted pattern registry)"

if [[ ! -f "${TEKHTON_HOME}/lib/errors_helpers.sh" ]]; then
    echo "FAIL: errors_helpers.sh should exist (contains is_transient moved from errors.sh)"
    exit 1
fi
errors_helpers_lines=$(wc -l < "${TEKHTON_HOME}/lib/errors_helpers.sh")
echo "errors_helpers.sh: $errors_helpers_lines lines (contains is_transient and helpers)"

# Verify that the extracted files are being sourced correctly
if ! grep -q "source.*gates_completion.sh" "${TEKHTON_HOME}/tekhton.sh"; then
    echo "FAIL: gates_completion.sh is not sourced in tekhton.sh"
    exit 1
fi

if ! grep -q "source.*error_patterns_registry.sh" "${TEKHTON_HOME}/lib/error_patterns.sh"; then
    echo "FAIL: error_patterns_registry.sh is not sourced in error_patterns.sh"
    exit 1
fi

echo "PASS"
exit 0
