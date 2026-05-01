#!/usr/bin/env bash
# tests/test_output_format.sh — Display-helper tests for lib/output_format.sh.
#
# Covers the formatting helpers (color, repeat, term-width, banner, section,
# kv, hr, progress, action_item display). The JSON-construction and json-escape
# tests live in tests/test_output_format_json.sh; both files share the same
# fixture setup via tests/output_format_fixtures.sh.
set -euo pipefail

# shellcheck source=output_format_fixtures.sh
source "$(dirname "${BASH_SOURCE[0]}")/output_format_fixtures.sh"

echo "=== test_output_format.sh ==="

# ════════════════════════════════════════
# _out_color
# ════════════════════════════════════════

# 1. Returns empty when NO_COLOR is set (evaluated at call time).
result=$(NO_COLOR=1 _out_color "${BOLD}")
assert_eq "_out_color: empty when NO_COLOR=1" "" "$result"

# 2. Returns the ANSI code as actual ESC bytes when NO_COLOR is not set.
# _out_color uses printf '%b' so single-quoted color literals from common.sh
# (e.g. BOLD='\033[1m') are emitted as real ESC sequences, not the literal
# 4-character backslash-octal form.
unset NO_COLOR
result=$(_out_color "${BOLD}")
expected=$(printf '%b' "${BOLD}")
assert_eq "_out_color: emits interpreted ESC bytes when NO_COLOR unset" "$expected" "$result"
if contains_ansi "$result"; then
    pass "_out_color: result contains real ESC byte (0x1b)"
else
    fail "_out_color: result missing real ESC byte (got literal '${result}')"
fi
assert_not_contains "_out_color: result has no literal \\\\033" '\033' "$result"

# 3. Returns empty string for empty input (no crash).
result=$(_out_color "")
assert_eq "_out_color: empty input → empty output" "" "$result"

# ════════════════════════════════════════
# _out_repeat
# ════════════════════════════════════════

result=$(_out_repeat "─" 5)
assert_eq "_out_repeat: 5 dashes" "─────" "$result"
result=$(_out_repeat "─" 0)
assert_eq "_out_repeat: N=0 → empty" "" "$result"
result=$(_out_repeat "X" 1)
assert_eq "_out_repeat: N=1 → single char" "X" "$result"

# ════════════════════════════════════════
# _out_term_width
# ════════════════════════════════════════

result=$(COLUMNS=60 _out_term_width)
assert_eq "_out_term_width: COLUMNS=60 → 60" "60" "$result"
result=$(COLUMNS=200 _out_term_width)
assert_eq "_out_term_width: COLUMNS=200 → clamp to 80" "80" "$result"
result=$(COLUMNS=5 _out_term_width)
assert_eq "_out_term_width: COLUMNS=5 → default 60" "60" "$result"
result=$(COLUMNS="" _out_term_width)
if [[ "$result" -ge 20 && "$result" -le 80 ]]; then
    pass "_out_term_width: empty COLUMNS → valid range 20..80 (got ${result})"
else
    fail "_out_term_width: empty COLUMNS → '${result}' not in 20..80"
fi

# ════════════════════════════════════════
# out_banner (NO_COLOR mode)
# ════════════════════════════════════════

export NO_COLOR=1
output=$(out_banner "My Pipeline Banner")
stripped=$(strip_ansi "$output")
assert_contains "out_banner: title present in output" "My Pipeline Banner" "$stripped"
if ! contains_ansi "$output"; then
    pass "out_banner: no ANSI sequences when NO_COLOR=1"
else
    fail "out_banner: ANSI sequences found despite NO_COLOR=1"
fi

output=$(out_banner "Banner Title" "Version" "3.0.0" "Task" "build feature")
stripped=$(strip_ansi "$output")
assert_contains "out_banner: key label appears" "Version:" "$stripped"
assert_contains "out_banner: key value appears" "3.0.0" "$stripped"
assert_contains "out_banner: second key label appears" "Task:" "$stripped"

# ════════════════════════════════════════
# out_section (NO_COLOR mode)
# ════════════════════════════════════════

output=$(out_section "Build Results")
stripped=$(strip_ansi "$output")
assert_contains "out_section: title present in output" "Build Results" "$stripped"
if ! contains_ansi "$output"; then
    pass "out_section: no ANSI sequences when NO_COLOR=1"
else
    fail "out_section: ANSI sequences found despite NO_COLOR=1"
fi

# ════════════════════════════════════════
# out_kv (NO_COLOR mode)
# ════════════════════════════════════════

output=$(out_kv "Status" "running")
stripped=$(strip_ansi "$output")
assert_contains "out_kv normal: label present" "Status:" "$stripped"
assert_contains "out_kv normal: value present" "running" "$stripped"
assert_not_contains "out_kv normal: no [CRITICAL] suffix" "[CRITICAL]" "$stripped"

output=$(out_kv "Alert" "something happened" "warn")
stripped=$(strip_ansi "$output")
assert_contains "out_kv warn: label present" "Alert:" "$stripped"
assert_contains "out_kv warn: value present" "something happened" "$stripped"
assert_not_contains "out_kv warn: no [CRITICAL] suffix" "[CRITICAL]" "$stripped"

output=$(out_kv "Failure" "pipeline broken" "error")
stripped=$(strip_ansi "$output")
assert_contains "out_kv error: label present" "Failure:" "$stripped"
assert_contains "out_kv error: value present" "pipeline broken" "$stripped"
assert_contains "out_kv error: [CRITICAL] suffix" "[CRITICAL]" "$stripped"

# ════════════════════════════════════════
# out_hr (NO_COLOR mode)
# ════════════════════════════════════════

output=$(out_hr)
stripped=$(strip_ansi "$output")
if [[ -n "${stripped// /}" ]]; then
    pass "out_hr: non-empty output without label"
else
    fail "out_hr: empty output without label"
fi

output=$(out_hr "Section Label")
stripped=$(strip_ansi "$output")
assert_contains "out_hr with label: label present" "Section Label" "$stripped"

# ════════════════════════════════════════
# out_progress — fill calculation
# ════════════════════════════════════════

output=$(out_progress "Loading" 0 10 20)
stripped=$(strip_ansi "$output")
assert_contains "out_progress 0/10: label present" "Loading" "$stripped"
assert_contains "out_progress 0/10: count 0/10" "0/10" "$stripped"
assert_not_contains "out_progress 0/10: zero filled chars" "█" "$stripped"
assert_contains "out_progress 0/10: 20 empty chars" "░░░░░░░░░░░░░░░░░░░░" "$stripped"

output=$(out_progress "Loading" 5 10 20)
stripped=$(strip_ansi "$output")
assert_contains "out_progress 5/10: 10 filled chars" "██████████" "$stripped"
assert_contains "out_progress 5/10: 10 empty chars" "░░░░░░░░░░" "$stripped"
assert_contains "out_progress 5/10: count 5/10" "5/10" "$stripped"
assert_not_contains "out_progress 5/10: not 11 filled" "███████████" "$stripped"

output=$(out_progress "Done" 10 10 20)
stripped=$(strip_ansi "$output")
assert_contains "out_progress 10/10: 20 filled chars" "████████████████████" "$stripped"
assert_not_contains "out_progress 10/10: no empty chars" "░" "$stripped"
assert_contains "out_progress 10/10: count 10/10" "10/10" "$stripped"

set +e
output=$(out_progress "Idle" 0 0 20)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    pass "out_progress max=0: does not crash"
else
    fail "out_progress max=0: crashed with rc=${rc}"
fi
stripped=$(strip_ansi "$output")
assert_contains "out_progress max=0: shows 0/0" "0/0" "$stripped"

output=$(out_progress "Over" 15 10 20)
stripped=$(strip_ansi "$output")
assert_not_contains "out_progress cur>max: no empty chars" "░" "$stripped"
assert_contains "out_progress cur>max: count 15/10" "15/10" "$stripped"

# ════════════════════════════════════════
# out_action_item (NO_COLOR mode)
# ════════════════════════════════════════

output=$(out_action_item "Check your config" "normal")
stripped=$(strip_ansi "$output")
assert_contains "out_action_item normal: ℹ prefix" "ℹ" "$stripped"
assert_contains "out_action_item normal: message present" "Check your config" "$stripped"
assert_not_contains "out_action_item normal: no [CRITICAL]" "[CRITICAL]" "$stripped"

output=$(out_action_item "Review dependencies" "warning")
stripped=$(strip_ansi "$output")
assert_contains "out_action_item warning: ⚠ prefix" "⚠" "$stripped"
assert_contains "out_action_item warning: message present" "Review dependencies" "$stripped"
assert_not_contains "out_action_item warning: no [CRITICAL]" "[CRITICAL]" "$stripped"

output=$(out_action_item "Build failed" "critical")
stripped=$(strip_ansi "$output")
assert_contains "out_action_item critical: ✗ prefix" "✗" "$stripped"
assert_contains "out_action_item critical: message present" "Build failed" "$stripped"
assert_contains "out_action_item critical: [CRITICAL] suffix" "[CRITICAL]" "$stripped"

summary_and_exit
