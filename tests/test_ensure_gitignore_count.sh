#!/usr/bin/env bash
# Test: M135 gitignore comment count update
# Verifies the comment is updated from 18 to 20 entries
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_comment_says_20() {
    # Verify the comment mentions 20 entries, not 18
    grep -q "20.*Tekhton\|All 20" "${TEKHTON_HOME}/tests/test_ensure_gitignore_entries.sh"
}

test_no_stale_18_comment() {
    # Verify the old "18 Tekhton runtime patterns" comment is gone
    ! grep -q "All 18\|18.*Tekhton" "${TEKHTON_HOME}/tests/test_ensure_gitignore_entries.sh"
}

test_expected_entries_has_20() {
    # Verify the EXPECTED_ENTRIES array has 20 entries
    local count
    count=$(sed -n '/EXPECTED_ENTRIES=(/, /)/p' "${TEKHTON_HOME}/tests/test_ensure_gitignore_entries.sh" | grep -c '"' || true)
    [[ "$count" -eq 20 ]]
}

# Run tests
result=0

if test_comment_says_20; then
    echo "PASS: Comment updated to reflect 20 entries"
else
    echo "FAIL: Comment not updated to 20"
    result=1
fi

if test_no_stale_18_comment; then
    echo "PASS: Old 18-entry comment removed"
else
    echo "FAIL: Old comment still present"
    result=1
fi

if test_expected_entries_has_20; then
    echo "PASS: EXPECTED_ENTRIES array has 20 entries"
else
    echo "FAIL: EXPECTED_ENTRIES doesn't have 20 entries"
    result=1
fi

exit $result
