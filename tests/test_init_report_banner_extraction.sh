#!/usr/bin/env bash
# Test: M81 init_report_banner extraction
# Verifies the extracted init_report_banner_next.sh file exists and is sourced
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_extracted_file_exists() {
    # Verify the extracted file exists
    [[ -f "${TEKHTON_HOME}/lib/init_report_banner_next.sh" ]]
}

test_parent_file_sourced_extracted() {
    # Verify init_report_banner.sh sources the extracted file
    grep -q "source.*init_report_banner_next\|\. \".*init_report_banner_next" "${TEKHTON_HOME}/lib/init_report_banner.sh"
}

test_parent_file_reduced() {
    # Verify init_report_banner.sh is now under 300 lines (was 355)
    local lines
    lines=$(wc -l < "${TEKHTON_HOME}/lib/init_report_banner.sh")
    [[ "$lines" -lt 300 ]]
}

test_extracted_file_valid() {
    # Verify the extracted file is valid bash
    bash -n "${TEKHTON_HOME}/lib/init_report_banner_next.sh"
}

# Run tests
result=0

if test_extracted_file_exists; then
    echo "PASS: init_report_banner_next.sh exists"
else
    echo "FAIL: init_report_banner_next.sh not found"
    result=1
fi

if test_parent_file_sourced_extracted; then
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
