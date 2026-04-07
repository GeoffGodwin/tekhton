#!/usr/bin/env bash
# Test: Watchtower spacing improvements
# Verifies that line-height and padding improvements for readability are in place

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSS_TEMPLATE="$TEKHTON_HOME/templates/watchtower/style.css"

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; }

# Test 1: .findings-table has increased line-height
test_findings_table_line_height() {
  if grep -q '\.findings-table th, .findings-table td.*line-height:1\.35' "$CSS_TEMPLATE"; then
    pass ".findings-table has line-height:1.35"
    return 0
  else
    fail ".findings-table does not have line-height:1.35"
    return 1
  fi
}

# Test 2: .findings-table has increased padding
test_findings_table_padding() {
  if grep -q '\.findings-table th, .findings-table td.*padding:0\.4rem 0\.6rem' "$CSS_TEMPLATE"; then
    pass ".findings-table has padding:0.4rem 0.6rem"
    return 0
  else
    fail ".findings-table does not have padding:0.4rem 0.6rem"
    return 1
  fi
}

# Test 3: .breakdown-table has increased line-height
test_breakdown_table_line_height() {
  if grep -q '\.breakdown-table th, .breakdown-table td.*line-height:1\.35' "$CSS_TEMPLATE"; then
    pass ".breakdown-table has line-height:1.35"
    return 0
  else
    fail ".breakdown-table does not have line-height:1.35"
    return 1
  fi
}

# Test 4: .breakdown-table has increased padding
test_breakdown_table_padding() {
  if grep -q '\.breakdown-table th, .breakdown-table td.*padding:0\.4rem 0\.6rem' "$CSS_TEMPLATE"; then
    pass ".breakdown-table has padding:0.4rem 0.6rem"
    return 0
  else
    fail ".breakdown-table does not have padding:0.4rem 0.6rem"
    return 1
  fi
}

# Test 5: .intake-task-content has line-height:1.4
test_intake_task_content_line_height() {
  if grep -q '\.intake-task-content.*line-height:1\.4' "$CSS_TEMPLATE"; then
    pass ".intake-task-content has line-height:1.4"
    return 0
  else
    fail ".intake-task-content does not have line-height:1.4"
    return 1
  fi
}

# Test 6: .intake-task-content has increased padding
test_intake_task_content_padding() {
  if grep -q '\.intake-task-content.*padding:0\.35rem 0\.5rem' "$CSS_TEMPLATE"; then
    pass ".intake-task-content has padding:0.35rem 0.5rem"
    return 0
  else
    fail ".intake-task-content does not have padding:0.35rem 0.5rem"
    return 1
  fi
}

# Test 7: .run-list li has increased line-height
test_run_list_line_height() {
  if grep -q '\.run-list li.*line-height:1\.35' "$CSS_TEMPLATE"; then
    pass ".run-list li has line-height:1.35"
    return 0
  else
    fail ".run-list li does not have line-height:1.35"
    return 1
  fi
}

# Test 8: .run-list li has increased padding
test_run_list_padding() {
  if grep -q '\.run-list li.*padding:0\.45rem 0' "$CSS_TEMPLATE"; then
    pass ".run-list li has padding:0.45rem 0"
    return 0
  else
    fail ".run-list li does not have padding:0.45rem 0"
    return 1
  fi
}

# Test 9: .status-indicator has increased padding
test_status_indicator_padding() {
  if grep -E '\.status-indicator \{' "$CSS_TEMPLATE" -A 5 | grep -q 'padding: 0\.25rem 0\.6rem'; then
    pass ".status-indicator has padding:0.25rem 0.6rem"
    return 0
  else
    fail ".status-indicator does not have padding:0.25rem 0.6rem"
    return 1
  fi
}

# Test 10: .badge has increased padding
test_badge_padding() {
  if grep -E '\.badge \{' "$CSS_TEMPLATE" -A 5 | grep -q 'padding: 0\.2rem 0\.5rem'; then
    pass ".badge has padding:0.2rem 0.5rem"
    return 0
  else
    fail ".badge does not have padding:0.2rem 0.5rem"
    return 1
  fi
}

# Test 11: .dep-badge has increased padding
test_dep_badge_padding() {
  if grep -q '\.dep-badge.*padding:0\.15rem 0\.4rem' "$CSS_TEMPLATE"; then
    pass ".dep-badge has padding:0.15rem 0.4rem"
    return 0
  else
    fail ".dep-badge does not have padding:0.15rem 0.4rem"
    return 1
  fi
}

# Test 12: .milestone-summary has line-height:1.4
test_milestone_summary_line_height() {
  if grep -q '\.milestone-summary.*line-height:1\.4' "$CSS_TEMPLATE"; then
    pass ".milestone-summary has line-height:1.4"
    return 0
  else
    fail ".milestone-summary does not have line-height:1.4"
    return 1
  fi
}

# Run all tests
main() {
  local passed=0
  local failed=0

  if test_findings_table_line_height; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_findings_table_padding; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_breakdown_table_line_height; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_breakdown_table_padding; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_intake_task_content_line_height; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_intake_task_content_padding; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_run_list_line_height; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_run_list_padding; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_status_indicator_padding; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_badge_padding; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_dep_badge_padding; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_milestone_summary_line_height; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  echo ""
  echo "Results: $passed passed, $failed failed"

  if [[ $failed -gt 0 ]]; then
    return 1
  fi
  return 0
}

main
