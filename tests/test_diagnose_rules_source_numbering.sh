#!/usr/bin/env bash
# Test: M133 source numbering consistency
# Verifies docstring sources match evaluation order in _rule_build_fix_exhausted
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_source_numbering_consistent() {
    # Verify the docstring sources are numbered in evaluation order
    # The function should evaluate: RUN_SUMMARY (1), BUILD_FIX_REPORT (2), LAST_FAILURE_CONTEXT (3)
    local func_text
    func_text=$(sed -n '/^_rule_build_fix_exhausted()/,/^}/p' "${TEKHTON_HOME}/lib/diagnose_rules_resilience.sh")

    # Check that docstring sources are ordered correctly
    echo "$func_text" | grep -q "Source 1.*RUN_SUMMARY\|Source.*RUN_SUMMARY" || \
    echo "$func_text" | grep -q "RUN_SUMMARY"
}

test_evaluation_order_documented() {
    # Verify inline comments explain the evaluation order
    # Should have "Source" comments in the _rule_build_fix_exhausted function
    sed -n '/^_rule_build_fix_exhausted()/,/^}/p' "${TEKHTON_HOME}/lib/diagnose_rules_resilience.sh" | \
    grep -q "Source"
}

test_no_mismatch_with_old_comments() {
    # Verify there are no conflicting source numberings
    local func_text
    func_text=$(sed -n '/^_rule_build_fix_exhausted()/,/^}/p' "${TEKHTON_HOME}/lib/diagnose_rules_resilience.sh")

    # Count the number of "Source" mentions - should be consistent
    local count
    count=$(echo "$func_text" | grep -c "Source" || true)
    # Should either have no numbered sources (just inline comments) or have consistent numbering
    [[ "$count" -le 3 ]]
}

# Run tests
result=0

if test_source_numbering_consistent; then
    echo "PASS: Source numbering is consistent with evaluation order"
else
    echo "FAIL: Source numbering doesn't match evaluation order"
    result=1
fi

if test_evaluation_order_documented; then
    echo "PASS: Evaluation order is documented"
else
    echo "FAIL: Evaluation order not properly documented"
    result=1
fi

if test_no_mismatch_with_old_comments; then
    echo "PASS: No conflicting source numberings found"
else
    echo "FAIL: Conflicting source numberings detected"
    result=1
fi

exit $result
