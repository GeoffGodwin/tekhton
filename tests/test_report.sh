#!/usr/bin/env bash
# =============================================================================
# test_report.sh — Tests for lib/report.sh print_run_report() output content.
#
# Suites 1-8 cover smoke / outcome / milestone / human-action / per-stage
# rendering. The colorize-helper + literal-escape regression suites live in
# tests/test_report_color.sh. Both files share fixtures via
# tests/report_fixtures.sh.
# =============================================================================
set -euo pipefail

# shellcheck source=report_fixtures.sh
source "$(dirname "${BASH_SOURCE[0]}")/report_fixtures.sh"

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
# Test Suite 2: Outcome-based --diagnose hint
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
# Test Suite 4: Human action items
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
assert_exit0 "8.1 no error when RUN_SUMMARY.json missing" "print_run_report"
output=$(print_run_report 2>/dev/null)
assert_contains "8.2 header still rendered without summary" "════" "$output"
assert_contains "8.3 unknown outcome shown when no summary" "unknown" "$output"

summary_and_exit
