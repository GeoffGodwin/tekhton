#!/usr/bin/env bash
set -euo pipefail

# Test: Verify dashboard_emitters.sh has dep_arr properly declared in local statement

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="${TEKHTON_HOME}/lib/dashboard_emitters.sh"

# Check that line 162 contains "dep_arr" in the local declaration
# The line should look like: local i dep_list dep_item dep_arr
if sed -n '162p' "$test_file" | grep -q "local.*dep_arr"; then
    : # pass
else
    echo "FAIL: dashboard_emitters.sh line 162 is missing 'dep_arr' in local declaration"
    echo "  Actual line 162: $(sed -n '162p' "$test_file")"
    exit 1
fi

# Also verify that dep_arr is used in the read command on line 166
if sed -n '166p' "$test_file" | grep -q "read -ra dep_arr"; then
    : # pass
else
    echo "FAIL: dashboard_emitters.sh line 166 does not use 'dep_arr' in read command"
    exit 1
fi

exit 0
