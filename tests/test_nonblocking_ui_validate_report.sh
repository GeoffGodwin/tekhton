#!/usr/bin/env bash
set -euo pipefail

# Test: Verify ui_validate_report.sh has no duplicate set -euo pipefail declarations

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="${TEKHTON_HOME}/lib/ui_validate_report.sh"

# Count occurrences of "set -euo pipefail" in the file
count=$(grep -c "set -euo pipefail" "$test_file" || echo "0")

if [[ "$count" -eq 1 ]]; then
    exit 0
else
    echo "FAIL: ui_validate_report.sh has $count 'set -euo pipefail' declarations, expected 1"
    exit 1
fi
