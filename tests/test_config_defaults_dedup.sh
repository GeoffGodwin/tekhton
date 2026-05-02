#!/usr/bin/env bash
# Test: M128 BUILD_FIX_REPORT_FILE deduplication
# Verifies artifact_defaults.sh is the single source, config_defaults.sh doesn't duplicate
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_artifact_defaults_has_build_fix_report_file() {
    # Verify artifact_defaults.sh has the BUILD_FIX_REPORT_FILE default
    grep -q "BUILD_FIX_REPORT_FILE" "${TEKHTON_HOME}/lib/artifact_defaults.sh"
}

test_config_defaults_no_duplicate() {
    # Verify config_defaults.sh does NOT define BUILD_FIX_REPORT_FILE
    # (or if it does, it points to artifact_defaults.sh)
    local has_dup
    has_dup=$(grep "BUILD_FIX_REPORT_FILE" "${TEKHTON_HOME}/lib/config_defaults.sh" || true)

    # Should either not exist, or be a comment pointing to artifact_defaults.sh
    if [[ -n "$has_dup" ]]; then
        # If it exists, it should be a comment, not an assignment
        grep -q "BUILD_FIX_REPORT_FILE" "${TEKHTON_HOME}/lib/config_defaults.sh" && \
        grep "BUILD_FIX_REPORT_FILE" "${TEKHTON_HOME}/lib/config_defaults.sh" | grep -q "#"
    else
        # Not present is the expected state
        return 0
    fi
}

test_no_assignment_in_config_defaults() {
    # Verify no := or = assignment of BUILD_FIX_REPORT_FILE in config_defaults.sh
    ! grep -E "BUILD_FIX_REPORT_FILE\s*[:=]" "${TEKHTON_HOME}/lib/config_defaults.sh"
}

# Run tests
result=0

if test_artifact_defaults_has_build_fix_report_file; then
    echo "PASS: artifact_defaults.sh contains BUILD_FIX_REPORT_FILE definition"
else
    echo "FAIL: BUILD_FIX_REPORT_FILE not in artifact_defaults.sh"
    result=1
fi

if test_config_defaults_no_duplicate; then
    echo "PASS: BUILD_FIX_REPORT_FILE not duplicated in config_defaults.sh"
else
    echo "FAIL: BUILD_FIX_REPORT_FILE duplicated in config_defaults.sh"
    result=1
fi

if test_no_assignment_in_config_defaults; then
    echo "PASS: No assignment of BUILD_FIX_REPORT_FILE in config_defaults.sh"
else
    echo "FAIL: BUILD_FIX_REPORT_FILE assigned in config_defaults.sh"
    result=1
fi

exit $result
