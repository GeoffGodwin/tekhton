#!/usr/bin/env bash
# =============================================================================
# test_report_color.sh — colorize-helper + literal-escape regression tests
# for lib/report.sh.
#
# Suite 9 covers _report_colorize verdict→color mapping. Suite 10 is the
# regression for the bug where _out_color returned the 7-character literal
# string '\033[0;32m' (etc.) instead of an interpreted ESC sequence; rendered
# output must never contain literal '\033[' or '\e[' substrings.
#
# Output-content tests live in tests/test_report.sh. Both files share fixtures
# via tests/report_fixtures.sh.
# =============================================================================
set -euo pipefail

# shellcheck source=report_fixtures.sh
source "$(dirname "${BASH_SOURCE[0]}")/report_fixtures.sh"

# =============================================================================
# Test Suite 9: _report_colorize helper
# =============================================================================
echo "=== Test Suite 9: _report_colorize ==="

# _report_colorize delegates to _out_color, which uses printf '%b' so the
# returned color code is an interpreted ESC sequence — not the literal
# backslash-octal form stored in the GREEN/RED/YELLOW/NC variables.
GREEN_E=$(printf '%b' "${GREEN}")
RED_E=$(printf '%b' "${RED}")
YELLOW_E=$(printf '%b' "${YELLOW}")
NC_E=$(printf '%b' "${NC}")

result=$(_report_colorize "PASS")
assert_eq "9.1 PASS maps to GREEN" "$GREEN_E" "$result"

result=$(_report_colorize "APPROVED")
assert_eq "9.2 APPROVED maps to GREEN" "$GREEN_E" "$result"

result=$(_report_colorize "FAIL")
assert_eq "9.3 FAIL maps to RED" "$RED_E" "$result"

result=$(_report_colorize "REJECTED")
assert_eq "9.4 REJECTED maps to RED" "$RED_E" "$result"

result=$(_report_colorize "CHANGES_REQUIRED")
assert_eq "9.5 CHANGES_REQUIRED maps to YELLOW" "$YELLOW_E" "$result"

result=$(_report_colorize "UNKNOWN_STATUS")
assert_eq "9.6 unknown status maps to NC" "$NC_E" "$result"

# =============================================================================
# Test Suite 10: rendered output has no literal \033 or \e escapes
# =============================================================================
echo "=== Test Suite 10: rendered output has no literal \\033 ==="

_reset_report_fixture
_create_run_summary "success" "17"
cat > "$TMPDIR/${TEKHTON_DIR}/INTAKE_REPORT.md" << 'EOF'
# Intake Report

## Verdict
PASS

Confidence: 95
EOF
cat > "$TMPDIR/${TEKHTON_DIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status
COMPLETE
EOF
cat > "$TMPDIR/${TEKHTON_DIR}/SECURITY_REPORT.md" << 'EOF'
# Security Report
EOF
cat > "$TMPDIR/${TEKHTON_DIR}/REVIEWER_REPORT.md" << 'EOF'
# Reviewer Report

## Verdict
APPROVED
EOF
cat > "$TMPDIR/${TEKHTON_DIR}/TESTER_REPORT.md" << 'EOF'
## Tests Written
1. test_foo.sh

## Bugs Found
None
EOF
output=$(print_run_report 2>/dev/null)

if printf '%s' "$output" | grep -qF '\033['; then
    echo "  FAIL: 10.1 rendered output contains literal '\\033[' substring"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: 10.1 rendered output free of literal '\\033[' substring"
    PASS=$((PASS + 1))
fi

if printf '%s' "$output" | grep -qF '\e['; then
    echo "  FAIL: 10.2 rendered output contains literal '\\e[' substring"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: 10.2 rendered output free of literal '\\e[' substring"
    PASS=$((PASS + 1))
fi

summary_and_exit
