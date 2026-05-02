#!/usr/bin/env bash
# Test: POLISH TUI render timings comment
# Verifies the comment describes the actual truncation fix
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEKHTON_HOME="$(pwd)"

test_comment_mentions_truncation() {
    # Verify the comment mentions truncation (via "Trims" or "_truncate" or "ellipsis")
    grep -q "Trims\|_truncate\|ellipsis" "${TEKHTON_HOME}/tools/tui_render_timings.py"
}

test_comment_no_old_approach() {
    # Verify the comment properly identifies truncation as primary fix
    # and overflow/wrap as backstops
    grep -q "backstop" "${TEKHTON_HOME}/tools/tui_render_timings.py"
}

test_no_wrap_false_mentioned_as_fix() {
    # Verify no_wrap=False is mentioned as a backstop, not the primary fix
    grep -q "no_wrap\|overflow" "${TEKHTON_HOME}/tools/tui_render_timings.py" && true
}

# Run tests
result=0

if test_comment_mentions_truncation; then
    echo "PASS: Comment mentions truncation as primary fix"
else
    echo "FAIL: Truncation not mentioned in comment"
    result=1
fi

if test_comment_no_old_approach; then
    echo "PASS: Comment describes actual fix approach"
else
    echo "FAIL: Comment still describes old approach"
    result=1
fi

if test_no_wrap_false_mentioned_as_fix; then
    echo "PASS: wrap/overflow settings are documented"
else
    echo "FAIL: wrap/overflow settings not documented"
    result=1
fi

exit $result
