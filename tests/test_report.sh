#!/usr/bin/env bash
# =============================================================================
# test_report.sh — Tests for lib/report.sh print_run_report()
#
# Tests:
# - Smoke test: runs without error when no files exist
# - Header always present in output
# - failure/stuck/timeout outcomes trigger --diagnose hint
# - success outcome does NOT trigger --diagnose hint
# - HUMAN_ACTION_REQUIRED.md unchecked items counted
# - Reviewer verdict rendered when REVIEWER_REPORT.md present
# - Tester section rendered when TESTER_REPORT.md present
# - Missing summary file handled gracefully
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Pipeline globals --------------------------------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/.claude/logs"
PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"

export PROJECT_DIR LOG_DIR PIPELINE_STATE_FILE TEKHTON_HOME

mkdir -p "$LOG_DIR/archive"
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
INTAKE_REPORT_FILE="${TEKHTON_DIR}/INTAKE_REPORT.md"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
SECURITY_REPORT_FILE="${TEKHTON_DIR}/SECURITY_REPORT.md"
REVIEWER_REPORT_FILE="${TEKHTON_DIR}/REVIEWER_REPORT.md"
TESTER_REPORT_FILE="${TEKHTON_DIR}/TESTER_REPORT.md"

# --- Source dependencies -----------------------------------------------------
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/report.sh"

# --- Test helpers ------------------------------------------------------------
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected to find '$needle' in output"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        echo "  FAIL: $desc — did not expect to find '$needle' in output"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_exit0() {
    local desc="$1"
    if eval "$2" > /dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — command exited non-zero"
        FAIL=$((FAIL + 1))
    fi
}

_reset_report_fixture() {
    rm -f "$TMPDIR/.claude/logs/RUN_SUMMARY.json"
    rm -f "$TMPDIR/${TEKHTON_DIR}/INTAKE_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/REVIEWER_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/TESTER_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/CODER_SUMMARY.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/SECURITY_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
}

_create_run_summary() {
    local outcome="$1"
    local milestone="${2:-none}"
    mkdir -p "$TMPDIR/.claude/logs"
    cat > "$TMPDIR/.claude/logs/RUN_SUMMARY.json" << EOF
{
  "milestone": "${milestone}",
  "outcome": "${outcome}",
  "attempts": 1,
  "total_agent_calls": 5,
  "wall_clock_seconds": 300,
  "files_changed": [],
  "timestamp": "2026-03-23T10:45:00Z"
}
EOF
}

# =============================================================================
# Test Suite 1: Smoke test — runs without error when no files exist
# =============================================================================
echo "=== Test Suite 1: Smoke test (no files) ==="

_reset_report_fixture
assert_exit0 "1.1 print_run_report exits 0 with no files" "print_run_report"

output=$(print_run_report 2>/dev/null)
assert_contains "1.2 header separator present in output" "════" "$output"
assert_contains "1.3 'Last run:' label present" "Last run:" "$output"

# =============================================================================
# Test Suite 2: Outcome coloring and --diagnose hint
# =============================================================================
echo "=== Test Suite 2: Outcome-based --diagnose hint ==="

_reset_report_fixture
_create_run_summary "failure"
output=$(print_run_report 2>/dev/null)
assert_contains "2.1 failure outcome shows --diagnose hint" "tekhton --diagnose" "$output"
assert_contains "2.2 failure outcome label present" "failure" "$output"

_reset_report_fixture
_create_run_summary "stuck"
output=$(print_run_report 2>/dev/null)
assert_contains "2.3 stuck outcome shows --diagnose hint" "tekhton --diagnose" "$output"

_reset_report_fixture
_create_run_summary "timeout"
output=$(print_run_report 2>/dev/null)
assert_contains "2.4 timeout outcome shows --diagnose hint" "tekhton --diagnose" "$output"

_reset_report_fixture
_create_run_summary "success"
output=$(print_run_report 2>/dev/null)
assert_not_contains "2.5 success outcome does NOT show --diagnose hint" "tekhton --diagnose" "$output"
assert_contains "2.6 success outcome label present" "success" "$output"

# =============================================================================
# Test Suite 3: Milestone display
# =============================================================================
echo "=== Test Suite 3: Milestone display ==="

_reset_report_fixture
_create_run_summary "success" "17"
output=$(print_run_report 2>/dev/null)
assert_contains "3.1 milestone number shown when present" "17" "$output"
assert_contains "3.2 Milestone label shown" "Milestone:" "$output"

_reset_report_fixture
_create_run_summary "success" "none"
output=$(print_run_report 2>/dev/null)
assert_not_contains "3.3 milestone section hidden when none" "Milestone:" "$output"

# =============================================================================
# Test Suite 4: HUMAN_ACTION_REQUIRED.md action items
# =============================================================================
echo "=== Test Suite 4: Human action items ==="

_reset_report_fixture
_create_run_summary "success"
cat > "$TMPDIR/${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md" << 'EOF'
- [ ] Update the API documentation
- [ ] Review the database schema changes
- [x] Already done item
EOF
output=$(print_run_report 2>/dev/null)
assert_contains "4.1 action item count displayed" "Action items: 2" "$output"

# No unchecked items
_reset_report_fixture
_create_run_summary "success"
cat > "$TMPDIR/${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md" << 'EOF'
- [x] Already done
EOF
output=$(print_run_report 2>/dev/null)
assert_not_contains "4.2 no action items when all checked" "Action items:" "$output"

# =============================================================================
# Test Suite 5: Reviewer stage section
# =============================================================================
echo "=== Test Suite 5: Reviewer stage ==="

_reset_report_fixture
_create_run_summary "success"
cat > "$TMPDIR/${TEKHTON_DIR}/REVIEWER_REPORT.md" << 'EOF'
# Reviewer Report

## Verdict
APPROVED

## Notes
All good.
EOF
output=$(print_run_report 2>/dev/null)
assert_contains "5.1 reviewer section present" "Reviewer:" "$output"
assert_contains "5.2 reviewer verdict APPROVED shown" "APPROVED" "$output"

_reset_report_fixture
_create_run_summary "failure"
cat > "$TMPDIR/${TEKHTON_DIR}/REVIEWER_REPORT.md" << 'EOF'
# Reviewer Report

## Verdict
CHANGES_REQUIRED

## Notes
Fix the thing.
EOF
output=$(print_run_report 2>/dev/null)
assert_contains "5.3 CHANGES_REQUIRED verdict shown" "CHANGES_REQUIRED" "$output"

# =============================================================================
# Test Suite 6: Tester stage section
# =============================================================================
echo "=== Test Suite 6: Tester stage ==="

_reset_report_fixture
_create_run_summary "success"
# Note: Tester section uses ## Tests Written heading for count (numbered list)
# and ## Bugs Found for bug count - let's test with zero bugs
cat > "$TMPDIR/${TEKHTON_DIR}/TESTER_REPORT.md" << 'EOF'
## Planned Tests
- [x] `tests/test_foo.sh` — foo tests

## Tests Written
1. test_foo.sh

## Test Run Results
Passed: 5  Failed: 0

## Bugs Found
None
EOF
output=$(print_run_report 2>/dev/null)
assert_contains "6.1 tester section present" "Tester:" "$output"
assert_contains "6.2 tester shows passing result" "passing" "$output"

# =============================================================================
# Test Suite 7: Intake stage section
# =============================================================================
echo "=== Test Suite 7: Intake stage ==="

_reset_report_fixture
_create_run_summary "success"
cat > "$TMPDIR/${TEKHTON_DIR}/INTAKE_REPORT.md" << 'EOF'
# Intake Report

## Verdict
PASS

Confidence: 95
EOF
output=$(print_run_report 2>/dev/null)
assert_contains "7.1 intake section present" "Intake:" "$output"
assert_contains "7.2 intake verdict shown" "PASS" "$output"
assert_contains "7.3 confidence shown" "confidence 95" "$output"

# =============================================================================
# Test Suite 8: Missing summary file handled gracefully
# =============================================================================
echo "=== Test Suite 8: Graceful missing files ==="

_reset_report_fixture
# No RUN_SUMMARY.json at all
assert_exit0 "8.1 no error when RUN_SUMMARY.json missing" "print_run_report"
output=$(print_run_report 2>/dev/null)
assert_contains "8.2 header still rendered without summary" "════" "$output"
assert_contains "8.3 unknown outcome shown when no summary" "unknown" "$output"

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
# Test Suite 10: No literal \033 escapes leak into rendered output
# =============================================================================
echo "=== Test Suite 10: rendered output has no literal \\033 ==="

# Regression for the bug where _out_color returned the 7-character literal
# string '\033[0;32m' (etc.), and out_msg's printf '%s\n' then printed it
# verbatim — so the terminal showed "\033[0;32msuccess\033[0m" instead of
# colorized text. After the fix _out_color must emit interpreted ESC bytes,
# meaning grep for the literal substring "\033[" should never match.
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

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  report tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All report tests passed"
