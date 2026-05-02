#!/usr/bin/env bash
# Test: M127 catch-all arm warns on unknown routing tokens
# Verifies explicit warning for unknown future routing tokens
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_catch_all_arm_exists() {
    # Verify the case statement has an explicit catch-all (*) arm
    grep -q '\*)[[:space:]]*warn' "${TEKHTON_HOME}/stages/coder_buildfix.sh"
}

test_catch_all_warns_on_unknown() {
    # Verify the catch-all arm calls warn (not silent)
    grep -A 1 '\*)' "${TEKHTON_HOME}/stages/coder_buildfix.sh" | \
    grep -q 'warn.*unknown\|warn.*unrecognized'
}

# Run tests
result=0

if test_catch_all_arm_exists; then
    echo "PASS: Explicit catch-all arm with warning exists"
else
    echo "FAIL: Catch-all arm not found"
    result=1
fi

if test_catch_all_warns_on_unknown; then
    echo "PASS: Catch-all arm warns on unknown tokens"
else
    echo "FAIL: Catch-all arm doesn't warn on unknown tokens"
    result=1
fi

exit $result
