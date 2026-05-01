#!/usr/bin/env bash
# tests/test_output_format_json.sh — JSON-construction + static-analysis tests
# for lib/output_format.sh.
#
# Covers:
#   - _out_append_action_item: JSON array construction and appending
#   - _out_json_escape: backslash, quote, newline, tab, carriage-return
#   - bash -n + shellcheck on lib/output_format.sh
#
# The display-helper tests live in tests/test_output_format.sh; both files
# share fixture setup via tests/output_format_fixtures.sh.
set -euo pipefail

# shellcheck source=output_format_fixtures.sh
source "$(dirname "${BASH_SOURCE[0]}")/output_format_fixtures.sh"

echo "=== test_output_format_json.sh ==="

# ════════════════════════════════════════
# _out_append_action_item — JSON construction
# ════════════════════════════════════════

_OUT_CTX[action_items]=""

_out_append_action_item "First action" "normal"
result="${_OUT_CTX[action_items]}"
assert_contains "_out_append_action_item 1st: starts with [" "[" "${result:0:1}"
assert_contains "_out_append_action_item 1st: ends with ]" "]" "${result: -1}"
assert_contains "_out_append_action_item 1st: msg field" '"msg":"First action"' "$result"
assert_contains "_out_append_action_item 1st: severity field" '"severity":"normal"' "$result"

_out_append_action_item "Second action" "warning"
result="${_OUT_CTX[action_items]}"
assert_contains "_out_append_action_item 2nd: first item retained" '"msg":"First action"' "$result"
assert_contains "_out_append_action_item 2nd: second item added" '"msg":"Second action"' "$result"
assert_contains "_out_append_action_item 2nd: second severity" '"severity":"warning"' "$result"

_OUT_CTX[action_items]=""
_out_append_action_item 'Fix "critical" issue' "critical"
result="${_OUT_CTX[action_items]}"
assert_contains "_out_append_action_item: quotes escaped in msg" '\"critical\"' "$result"

# ════════════════════════════════════════
# _out_json_escape — special character escaping
# ════════════════════════════════════════

result=$(_out_json_escape 'say "hello"')
assert_eq '_out_json_escape: double quotes' 'say \"hello\"' "$result"

result=$(_out_json_escape 'path\to\file')
assert_eq '_out_json_escape: backslashes' 'path\\to\\file' "$result"

result=$(_out_json_escape $'line1\nline2')
assert_eq '_out_json_escape: newline' 'line1\nline2' "$result"

result=$(_out_json_escape $'col1\tcol2')
assert_eq '_out_json_escape: tab' 'col1\tcol2' "$result"

result=$(_out_json_escape $'line\r')
assert_eq '_out_json_escape: carriage return' 'line\r' "$result"

result=$(_out_json_escape "plain text")
assert_eq '_out_json_escape: plain text unchanged' "plain text" "$result"

# ════════════════════════════════════════
# Syntax and static analysis
# ════════════════════════════════════════

bash -n "${TEKHTON_HOME}/lib/output_format.sh" && rc=0 || rc=$?
assert_eq "bash -n lib/output_format.sh" "0" "$rc"

if command -v shellcheck &>/dev/null; then
    shellcheck "${TEKHTON_HOME}/lib/output_format.sh" && rc=0 || rc=$?
    assert_eq "shellcheck lib/output_format.sh" "0" "$rc"
else
    echo "  SKIP: shellcheck not available"
fi

summary_and_exit
