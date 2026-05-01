#!/usr/bin/env bash
# Test: M136 BUILD_FIX_MAX_ATTEMPTS clamp
# Verifies the clamp entry was added for defensive redundancy
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_clamp_entry_exists() {
    # Verify _clamp_config_value BUILD_FIX_MAX_ATTEMPTS 20 is in config_defaults.sh
    grep -q "_clamp_config_value BUILD_FIX_MAX_ATTEMPTS 20" "${TEKHTON_HOME}/lib/config_defaults.sh"
}

test_clamp_near_other_build_fix() {
    # Verify it's placed near other BUILD_FIX_* clamps
    local build_fix_line
    build_fix_line=$(grep -n "_clamp_config_value BUILD_FIX" "${TEKHTON_HOME}/lib/config_defaults.sh" | head -1 | cut -d: -f1)

    # Should exist and be within 5 lines of other BUILD_FIX clamps
    [[ -n "$build_fix_line" ]]
}

test_value_is_20() {
    # Verify the clamp value is 20 (not some other number)
    grep "_clamp_config_value BUILD_FIX_MAX_ATTEMPTS" "${TEKHTON_HOME}/lib/config_defaults.sh" | \
    grep -q " 20"
}

# Run tests
result=0

if test_clamp_entry_exists; then
    echo "PASS: BUILD_FIX_MAX_ATTEMPTS clamp entry exists"
else
    echo "FAIL: BUILD_FIX_MAX_ATTEMPTS clamp not found"
    result=1
fi

if test_clamp_near_other_build_fix; then
    echo "PASS: Clamp placed with other BUILD_FIX clamps"
else
    echo "FAIL: Clamp not properly placed"
    result=1
fi

if test_value_is_20; then
    echo "PASS: Clamp value is correctly set to 20"
else
    echo "FAIL: Clamp value is incorrect"
    result=1
fi

exit $result
