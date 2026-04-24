#!/usr/bin/env bash
# =============================================================================
# test_common_box_edge_cases.sh — Box-drawing UTF-8 vs ASCII fallback
#
# Verifies lib/common_box.sh handles:
#   - UTF-8 terminal detection and box character selection
#   - ASCII fallback when UTF-8 is not available
#   - Wide content handling (padding calculation)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Color stubs
RED="" GREEN="" YELLOW="" NC=""

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common_box.sh"

# =============================================================================
echo "=== Test 1: UTF-8 terminal detection ==="
# =============================================================================

# Test positive: UTF-8 in LANG
(
    export LANG="en_US.UTF-8"
    export LC_ALL=""
    if _is_utf8_terminal; then
        pass "UTF-8 detected with LANG=en_US.UTF-8"
    else
        fail "_is_utf8_terminal should detect UTF-8 in LANG"
    fi
)

# Test positive: UTF-8 in LC_ALL
(
    export LANG=""
    export LC_ALL="en_US.utf-8"
    if _is_utf8_terminal; then
        pass "UTF-8 detected with LC_ALL=en_US.utf-8"
    else
        fail "_is_utf8_terminal should detect UTF-8 in LC_ALL"
    fi
)

# Test negative: No UTF-8
(
    export LANG="C"
    export LC_ALL=""
    if ! _is_utf8_terminal; then
        pass "Non-UTF-8 locale correctly rejected"
    else
        fail "_is_utf8_terminal should return false for non-UTF-8"
    fi
)

# =============================================================================
echo "=== Test 2: Box character setup (ASCII fallback) ==="
# =============================================================================

# When not UTF-8, should use ASCII characters
(
    export LANG="C"
    export LC_ALL=""

    _setup_box_chars 60

    if [[ "$_BOX_TL" == "+" && "$_BOX_TR" == "+" && \
          "$_BOX_BL" == "+" && "$_BOX_BR" == "+" && \
          "$_BOX_H" == "-" && "$_BOX_V" == "|" ]]; then
        pass "ASCII fallback uses +, -, | characters"
    else
        fail "ASCII fallback incorrect: TL=$_BOX_TL TR=$_BOX_TR BL=$_BOX_BL BR=$_BOX_BR H=$_BOX_H V=$_BOX_V"
    fi
)

# When UTF-8 is available, should use box-drawing characters
(
    export LANG="en_US.UTF-8"
    export LC_ALL=""

    _setup_box_chars 60

    if [[ "$_BOX_TL" == "╔" && "$_BOX_TR" == "╗" && \
          "$_BOX_BL" == "╚" && "$_BOX_BR" == "╝" && \
          "$_BOX_H" == "═" && "$_BOX_V" == "║" ]]; then
        pass "UTF-8 setup uses box-drawing characters"
    else
        fail "UTF-8 box chars incorrect: TL=$_BOX_TL TR=$_BOX_TR BL=$_BOX_BL BR=$_BOX_BR H=$_BOX_H V=$_BOX_V"
    fi
)

# =============================================================================
echo "=== Test 3: Horizontal line building ==="
# =============================================================================

# Build a 10-character line with '-'
result=$(_build_box_hline 10 "-")
expected="----------"
if [[ "$result" == "$expected" ]]; then
    pass "_build_box_hline creates correct length line"
else
    fail "_build_box_hline produced '$result', expected '$expected' (length ${#result} vs ${#expected})"
fi

# Build with UTF-8 character
result=$(_build_box_hline 5 "═")
if [[ ${#result} -eq 5 ]]; then
    pass "_build_box_hline handles UTF-8 characters"
else
    fail "_build_box_hline UTF-8 line has wrong length: ${#result} vs 5"
fi

# Empty width
result=$(_build_box_hline 0 "-")
if [[ -z "$result" ]]; then
    pass "_build_box_hline returns empty for width 0"
else
    fail "_build_box_hline should return empty for width 0, got '$result'"
fi

# =============================================================================
echo "=== Test 4: Box line printing with padding ==="
# =============================================================================

# Test content padding
output=$(_print_box_line "|" 40 "Hello")
# With printf: "| " + content (padded to 38 chars) + " |"
# Length should be 40
if [[ ${#output} -ge 40 ]]; then
    pass "_print_box_line pads content correctly"
else
    fail "_print_box_line output too short: ${#output} vs 40"
fi

# Empty content should produce a separator line of spaces
# Note: _print_box_line adds a newline, so length includes that
output=$(_print_box_line "|" 40 "")
# Remove newline for length check
output_no_nl="${output%$'\n'}"
if [[ ${#output_no_nl} -eq 42 ]]; then
    pass "_print_box_line empty content produces space-filled separator"
else
    fail "_print_box_line empty content separator incorrect (got length ${#output_no_nl}, expected 42)"
fi

# =============================================================================
echo "=== Test 5: Box frame with varying widths ==="
# =============================================================================

# Small box
output=$(_print_box_frame --width 20 "Short" 2>&1)
if echo "$output" | grep -q "╔\|+"; then
    pass "_print_box_frame with width 20 produces output"
else
    fail "_print_box_frame width 20 produced no box"
fi

# Large box
output=$(_print_box_frame --width 100 "Long line" 2>&1)
if echo "$output" | grep -q "╔\|+"; then
    pass "_print_box_frame with width 100 produces output"
else
    fail "_print_box_frame width 100 produced no box"
fi

# =============================================================================
echo "=== Test 6: Box frame with multiple lines ==="
# =============================================================================

output=$(_print_box_frame "Line 1" "" "Line 2" "Line 3" 2>&1)
line_count=$(echo "$output" | wc -l)
if [[ "$line_count" -gt 5 ]]; then
    pass "_print_box_frame with multiple lines produces output"
else
    fail "_print_box_frame multiline output too short: $line_count lines"
fi

# =============================================================================
echo "=== Test 7: report_error structure ==="
# =============================================================================

# report_error with default width (60)
output=$(report_error "BUILD_ERROR" "compilation" "false" "Unable to compile src/main.go" "Fix syntax errors" 2>&1) || true
if echo "$output" | grep -q "BUILD_ERROR"; then
    pass "report_error includes error category"
else
    fail "report_error output missing category"
fi

if echo "$output" | grep -q "Unable to compile"; then
    pass "report_error includes error message"
else
    fail "report_error output missing message"
fi

# =============================================================================
echo "=== Test 8: Wide content edge case ==="
# =============================================================================

# Test with content that has special characters
wide_content="Test: 日本語 mixed content"
output=$(_print_box_line "|" 50 "$wide_content") || true
if [[ -n "$output" ]]; then
    pass "_print_box_line handles wide/special characters"
else
    fail "_print_box_line failed with wide content"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  ${PASS} passed, ${FAIL} failed"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
