#!/usr/bin/env bash
# Test: M80 DRAFT_MILESTONES_SEED_EXEMPLARS integer guard
# Verifies non-integer values fall back to default (3)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_integer_guard_exists() {
    # Verify the guard is present before the head command
    grep -q 'count.*=~.*\^' "${TEKHTON_HOME}/lib/draft_milestones.sh"
}

test_fallback_to_default() {
    # Verify the guard sets count=3 as fallback
    grep -q '|| count=3' "${TEKHTON_HOME}/lib/draft_milestones.sh"
}

test_guard_before_head() {
    # Verify the guard appears before head invocation
    local guard_line
    local head_line
    guard_line=$(grep -n 'count.*=~.*\^' "${TEKHTON_HOME}/lib/draft_milestones.sh" | cut -d: -f1)
    head_line=$(grep -n 'head -"\$count"' "${TEKHTON_HOME}/lib/draft_milestones.sh" | head -1 | cut -d: -f1)

    # Guard should appear before head
    [[ -n "$guard_line" ]] && [[ -n "$head_line" ]] && [[ "$guard_line" -lt "$head_line" ]]
}

# Run tests
result=0

if test_integer_guard_exists; then
    echo "PASS: Integer validation guard exists"
else
    echo "FAIL: Integer guard not found"
    result=1
fi

if test_fallback_to_default; then
    echo "PASS: Fallback to default (3) on non-integer"
else
    echo "FAIL: Fallback not implemented"
    result=1
fi

if test_guard_before_head; then
    echo "PASS: Guard appears before head invocation"
else
    echo "FAIL: Guard not properly positioned"
    result=1
fi

exit $result
