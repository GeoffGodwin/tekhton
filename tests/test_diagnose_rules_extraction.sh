#!/usr/bin/env bash
# Test: M133 preflight rule extraction
# Verifies the extracted preflight rule file exists and is sourced correctly
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_preflight_rule_file_exists() {
    # Verify the extracted file exists
    [[ -f "${TEKHTON_HOME}/lib/diagnose_rules_resilience_preflight.sh" ]]
}

test_preflight_rule_sourced() {
    # Verify diagnose_rules_resilience.sh sources the extracted file
    grep -q "source.*diagnose_rules_resilience_preflight" "${TEKHTON_HOME}/lib/diagnose_rules_resilience.sh" || \
    grep -q '\. "${TEKHTON_HOME}/lib/diagnose_rules_resilience_preflight' "${TEKHTON_HOME}/lib/diagnose_rules_resilience.sh"
}

test_parent_file_reduced() {
    # Verify diagnose_rules_resilience.sh is now under 300 lines
    local lines
    lines=$(wc -l < "${TEKHTON_HOME}/lib/diagnose_rules_resilience.sh")
    [[ "$lines" -lt 300 ]]
}

test_extracted_file_valid() {
    # Verify the extracted file is valid bash
    bash -n "${TEKHTON_HOME}/lib/diagnose_rules_resilience_preflight.sh"
}

# Run tests
result=0

if test_preflight_rule_file_exists; then
    echo "PASS: diagnose_rules_resilience_preflight.sh exists"
else
    echo "FAIL: diagnose_rules_resilience_preflight.sh not found"
    result=1
fi

if test_preflight_rule_sourced; then
    echo "PASS: Extracted file is sourced by parent"
else
    echo "FAIL: Extracted file not sourced"
    result=1
fi

if test_parent_file_reduced; then
    echo "PASS: Parent file under 300-line ceiling"
else
    echo "FAIL: Parent file still too large"
    result=1
fi

if test_extracted_file_valid; then
    echo "PASS: Extracted file is valid bash"
else
    echo "FAIL: Extracted file has syntax errors"
    result=1
fi

exit $result
