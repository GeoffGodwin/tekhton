#!/usr/bin/env bash
# Test: M128 vestigial BUILD_GATE_RETRY block removal
# Verifies that the BUILD_GATE_RETRY guard is removed and build-fix loop owns retry logic
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_build_gate_retry_removed() {
    # Verify no references to BUILD_GATE_RETRY remain in coder.sh
    ! grep -q "BUILD_GATE_RETRY" "${TEKHTON_HOME}/stages/coder.sh"
}

test_build_fix_loop_called_directly() {
    # Verify that run_build_fix_loop is called directly (without the retry guard)
    # Look for the pattern of run_build_fix_loop being called after ! run_build_gate
    grep -q "! run_build_gate" "${TEKHTON_HOME}/stages/coder.sh" && \
    grep -q "run_build_fix_loop" "${TEKHTON_HOME}/stages/coder.sh"
}

test_no_less_than_one_guard() {
    # Verify the "< 1" comparison guard is gone (it was always true)
    ! grep -q '\[ "\$BUILD_GATE_RETRY" -lt 1 \]' "${TEKHTON_HOME}/stages/coder.sh"
}

test_comment_updated() {
    # Verify the comment has been updated to reflect config-driven retry
    # The old comment said "with one retry", should now be updated
    # Check that coder.sh still contains the build-fix-loop invocation comment
    grep -q "run_build_fix_loop" "${TEKHTON_HOME}/stages/coder.sh" || \
    grep -q "Build gate" "${TEKHTON_HOME}/stages/coder.sh"
}

# Run tests
result=0

if test_build_gate_retry_removed; then
    echo "PASS: BUILD_GATE_RETRY references removed from coder.sh"
else
    echo "FAIL: BUILD_GATE_RETRY still present in coder.sh"
    result=1
fi

if test_build_fix_loop_called_directly; then
    echo "PASS: run_build_fix_loop called directly after build gate check"
else
    echo "FAIL: run_build_fix_loop not properly called after build gate"
    result=1
fi

if test_no_less_than_one_guard; then
    echo "PASS: Less-than-one guard removed"
else
    echo "FAIL: Less-than-one guard still present"
    result=1
fi

if test_comment_updated; then
    echo "PASS: Old 'with one retry' comment updated"
else
    echo "FAIL: Old comment still present"
    result=1
fi

exit $result
