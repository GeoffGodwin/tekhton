#!/usr/bin/env bash
# Test: Watchtower WCAG font size improvements
# Verifies that the CSS meets WCAG 2.1 AA requirements for text readability

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSS_TEMPLATE="$TEKHTON_HOME/templates/watchtower/style.css"

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; }

# Test 1: Base font-size should be 15px (not 14px)
test_base_font_size() {
  if grep -E '^html\s*\{[^}]*font-size\s*:\s*15px' "$CSS_TEMPLATE" > /dev/null; then
    pass "Base font-size is 15px"
    return 0
  else
    fail "Base font-size is not 15px"
    return 1
  fi
}

# Test 2: No font-size less than 0.7rem
test_no_subseven_rem_fonts() {
  if grep 'font-size:\s*0\.[0-5][0-9]\+rem' "$CSS_TEMPLATE" > /dev/null 2>&1; then
    fail "Found instances of sub-0.7rem font-size"
    return 1
  else
    pass "No font-size less than 0.7rem found"
    return 0
  fi
}

# Test 3: .run-team-tag should be 0.75rem
test_run_team_tag_size() {
  if grep '\.run-team-tag.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".run-team-tag is 0.75rem"
    return 0
  else
    fail ".run-team-tag is not 0.75rem"
    return 1
  fi
}

# Test 4: .scout-sub-badge should be 0.75rem
test_scout_sub_badge_size() {
  if grep '\.scout-sub-badge.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".scout-sub-badge is 0.75rem"
    return 0
  else
    fail ".scout-sub-badge is not 0.75rem"
    return 1
  fi
}

# Test 5: .ms-dep-label should be 0.7rem
test_ms_dep_label_size() {
  if grep '\.ms-dep-label.*font-size:\s*0\.7rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".ms-dep-label is 0.7rem"
    return 0
  else
    fail ".ms-dep-label is not 0.7rem"
    return 1
  fi
}

# Test 6: .dep-chip-enabledby should be 0.75rem
test_dep_chip_enabledby_size() {
  if grep '\.dep-chip-enabledby.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".dep-chip-enabledby is 0.75rem"
    return 0
  else
    fail ".dep-chip-enabledby is not 0.75rem"
    return 1
  fi
}

# Test 7: .dep-chip-enables should be 0.75rem
test_dep_chip_enables_size() {
  if grep '\.dep-chip-enables.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".dep-chip-enables is 0.75rem"
    return 0
  else
    fail ".dep-chip-enables is not 0.75rem"
    return 1
  fi
}

# Test 8: .dep-badge should be 0.75rem
test_dep_badge_size() {
  if grep '\.dep-badge.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".dep-badge is 0.75rem"
    return 0
  else
    fail ".dep-badge is not 0.75rem"
    return 1
  fi
}

# Test 9: .findings-table th should be 0.75rem
test_findings_table_header_size() {
  if grep '\.findings-table th.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".findings-table th is 0.75rem"
    return 0
  else
    fail ".findings-table th is not 0.75rem"
    return 1
  fi
}

# Test 10: .breakdown-table th should be 0.8rem
test_breakdown_table_header_size() {
  if grep '\.breakdown-table th.*font-size:\s*0\.8rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".breakdown-table th is 0.8rem"
    return 0
  else
    fail ".breakdown-table th is not 0.8rem"
    return 1
  fi
}

# Test 11: .stage-progress.compact .stage-chip should be 0.75rem
test_stage_progress_compact_size() {
  if grep '\.stage-progress\.compact .stage-chip.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".stage-progress.compact .stage-chip is 0.75rem"
    return 0
  else
    fail ".stage-progress.compact .stage-chip is not 0.75rem"
    return 1
  fi
}

# Test 12: .run-type-tag should be 0.75rem
test_run_type_tag_size() {
  if grep '\.run-type-tag.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".run-type-tag is 0.75rem"
    return 0
  else
    fail ".run-type-tag is not 0.75rem"
    return 1
  fi
}

# Test 13: .team-card .stage-detail should be 0.75rem
test_team_card_stage_detail_size() {
  if grep '\.team-card \.stage-detail.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".team-card .stage-detail is 0.75rem"
    return 0
  else
    fail ".team-card .stage-detail is not 0.75rem"
    return 1
  fi
}

# Test 14: .team-filter-btn should be 0.75rem
test_team_filter_btn_size() {
  if grep '\.team-filter-btn.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".team-filter-btn is 0.75rem"
    return 0
  else
    fail ".team-filter-btn is not 0.75rem"
    return 1
  fi
}

# Test 15: .timeline-team-tag should be 0.75rem
test_timeline_team_tag_size() {
  if grep '\.timeline-team-tag.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".timeline-team-tag is 0.75rem"
    return 0
  else
    fail ".timeline-team-tag is not 0.75rem"
    return 1
  fi
}

# Test 16: .cross-dep-groups should be 0.75rem
test_cross_dep_groups_size() {
  if grep '\.cross-dep-groups.*font-size:\s*0\.75rem' "$CSS_TEMPLATE" > /dev/null; then
    pass ".cross-dep-groups is 0.75rem"
    return 0
  else
    fail ".cross-dep-groups is not 0.75rem"
    return 1
  fi
}

# Run all tests
main() {
  local passed=0
  local failed=0

  if test_base_font_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_no_subseven_rem_fonts; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_run_team_tag_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_scout_sub_badge_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_ms_dep_label_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_dep_chip_enabledby_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_dep_chip_enables_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_dep_badge_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_findings_table_header_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_breakdown_table_header_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_stage_progress_compact_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_run_type_tag_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_team_card_stage_detail_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_team_filter_btn_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_timeline_team_tag_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_cross_dep_groups_size; then
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
