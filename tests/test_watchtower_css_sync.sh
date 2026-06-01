#!/usr/bin/env bash
# Test: Watchtower CSS template and live dashboard sync
# Verifies that the template and live dashboard CSS files are identical

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSS_TEMPLATE="$TEKHTON_HOME/templates/watchtower/style.css"
CSS_LIVE="$TEKHTON_HOME/.claude/dashboard/style.css"

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; }
skip() { echo "↷ $1"; }

# The live dashboard directory (.claude/dashboard/) is gitignored and only
# exists after a tekhton run populates it via _copy_static_files (lib/dashboard.sh).
# Live-comparison checks are skipped in fresh checkouts where it isn't present.
LIVE_AVAILABLE=0
if [[ -f "$CSS_LIVE" ]]; then
  LIVE_AVAILABLE=1
fi

# Test 1: Template CSS exists (live is optional — auto-copied at runtime)
test_css_files_exist() {
  if [[ -f "$CSS_TEMPLATE" ]]; then
    pass "Template CSS exists"
    return 0
  else
    fail "Template CSS missing: $CSS_TEMPLATE"
    return 1
  fi
}

# Test 2: CSS files are identical (skipped when live not generated yet)
test_css_files_identical() {
  if [[ "$LIVE_AVAILABLE" -eq 0 ]]; then
    skip "CSS sync check (live dashboard not generated)"
    return 0
  fi
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

# Test 4: Live CSS has updated base font-size (skipped when live not generated yet)
test_live_has_base_font_size() {
  if [[ "$LIVE_AVAILABLE" -eq 0 ]]; then
    skip "Live CSS font-size check (live dashboard not generated)"
    return 0
  fi
  if grep -q '^html\s*{\s*font-size:\s*15px' "$CSS_LIVE"; then
    pass "Live CSS has 15px base font-size"
    return 0
  else
    fail "Live CSS does not have 15px base font-size"
    return 1
  fi
}

# Test 5: Both CSS files have same line count (skipped when live not generated yet)
test_css_same_line_count() {
  if [[ "$LIVE_AVAILABLE" -eq 0 ]]; then
    skip "Line count comparison (live dashboard not generated)"
    return 0
  fi
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
  local template_ok=0
  local live_ok=1
  file "$CSS_TEMPLATE" | grep -q "text" && template_ok=1
  if [[ "$LIVE_AVAILABLE" -eq 1 ]]; then
    live_ok=0
    file "$CSS_LIVE" | grep -q "text" && live_ok=1
  fi

  if [[ "$template_ok" -eq 1 && "$live_ok" -eq 1 ]]; then
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
