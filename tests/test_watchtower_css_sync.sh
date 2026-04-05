#!/usr/bin/env bash
# Test: Watchtower CSS template and live dashboard sync
# Verifies that the template and live dashboard CSS files are identical

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSS_TEMPLATE="$TEKHTON_HOME/templates/watchtower/style.css"
CSS_LIVE="$TEKHTON_HOME/.claude/dashboard/style.css"

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; }

# Test 1: Both CSS files exist
test_css_files_exist() {
  if [[ -f "$CSS_TEMPLATE" && -f "$CSS_LIVE" ]]; then
    pass "Both CSS files exist"
    return 0
  else
    fail "CSS files missing (template: $([[ -f "$CSS_TEMPLATE" ]] && echo exist || echo missing), live: $([[ -f "$CSS_LIVE" ]] && echo exist || echo missing))"
    return 1
  fi
}

# Test 2: CSS files are identical
test_css_files_identical() {
  if diff -q "$CSS_TEMPLATE" "$CSS_LIVE" > /dev/null 2>&1; then
    pass "CSS files are identical"
    return 0
  else
    fail "CSS files differ"
    return 1
  fi
}

# Test 3: Template CSS has updated base font-size
test_template_has_base_font_size() {
  if grep -q '^html\s*{\s*font-size:\s*15px' "$CSS_TEMPLATE"; then
    pass "Template CSS has 15px base font-size"
    return 0
  else
    fail "Template CSS does not have 15px base font-size"
    return 1
  fi
}

# Test 4: Live CSS has updated base font-size
test_live_has_base_font_size() {
  if grep -q '^html\s*{\s*font-size:\s*15px' "$CSS_LIVE"; then
    pass "Live CSS has 15px base font-size"
    return 0
  else
    fail "Live CSS does not have 15px base font-size"
    return 1
  fi
}

# Test 5: Both CSS files have same line count
test_css_same_line_count() {
  local template_lines
  local live_lines

  template_lines=$(wc -l < "$CSS_TEMPLATE")
  live_lines=$(wc -l < "$CSS_LIVE")

  if [[ "$template_lines" -eq "$live_lines" ]]; then
    pass "Both CSS files have $template_lines lines"
    return 0
  else
    fail "Line count differs (template: $template_lines, live: $live_lines)"
    return 1
  fi
}

# Test 6: CSS files have no binary content
test_css_text_files() {
  if file "$CSS_TEMPLATE" | grep -q "text" && file "$CSS_LIVE" | grep -q "text"; then
    pass "CSS files are valid text files"
    return 0
  else
    fail "CSS files have binary content"
    return 1
  fi
}

# Run all tests
main() {
  local passed=0
  local failed=0

  if test_css_files_exist; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_css_files_identical; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_template_has_base_font_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_live_has_base_font_size; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_css_same_line_count; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi

  if test_css_text_files; then
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
