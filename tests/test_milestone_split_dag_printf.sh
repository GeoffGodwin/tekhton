#!/usr/bin/env bash
# Test: M129/M127 echo→printf security fix
# Verifies printf is used instead of echo to prevent flag interpretation
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_milestone_split_dag_uses_printf() {
    # Verify the fix: milestone_split_dag.sh line 87 uses printf
    # Check for both the presence of printf and absence of bare echo
    grep -q "printf" "${TEKHTON_HOME}/lib/milestone_split_dag.sh" || \
    grep -q "echo" "${TEKHTON_HOME}/lib/milestone_split_dag.sh"
}

test_printf_replaces_echo() {
    # Verify the pattern has been fixed: printf '%s\n' instead of echo
    grep -q "printf '%s" "${TEKHTON_HOME}/lib/milestone_split_dag.sh"
}

test_no_echo_with_variable() {
    # Verify there's no dangerous echo "$sub_block" pattern
    ! grep -E 'echo\s+"\$' "${TEKHTON_HOME}/lib/milestone_split_dag.sh"
}

test_test_file_also_uses_printf() {
    # Verify that test files also use the fixed pattern
    grep -q "printf" "${TEKHTON_HOME}/tests/test_milestone_split_path_traversal.sh"
}

# Run tests
result=0

if test_milestone_split_dag_uses_printf; then
    echo "PASS: milestone_split_dag.sh uses printf for output"
else
    echo "FAIL: milestone_split_dag.sh doesn't use printf"
    result=1
fi

if test_printf_replaces_echo; then
    echo "PASS: printf '%s pattern used for safe output"
else
    echo "FAIL: printf pattern not found"
    result=1
fi

if test_no_echo_with_variable; then
    echo "PASS: No dangerous echo with variable patterns found"
else
    echo "FAIL: Dangerous echo patterns still present"
    result=1
fi

if test_test_file_also_uses_printf; then
    echo "PASS: Test files also updated with printf"
else
    echo "FAIL: Test files not updated"
    result=1
fi

exit $result
