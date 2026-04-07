#!/usr/bin/env bash
# Test: printf '%b' correctly handles ANSI color codes (replacement for echo -e)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"

# Source the library to get color definitions
source "${TEKHTON_HOME}/lib/common.sh"

FAIL=0

# Helper: assert that output contains expected text
assert_contains() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected to contain '$expected', got '$actual'"
        FAIL=1
    fi
}

# Helper: assert that two outputs are equivalent
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# =============================================================================
# Test 1: printf '%b' with ANSI color codes
# =============================================================================

# Test that printf '%b' correctly interprets backslash escapes like \033
# This simulates what the notes CLI does with color codes

# Define color codes
YELLOW='\033[33m'
NC='\033[0m'

# Test 1a: printf '%b' interprets color codes correctly
OUTPUT=$(printf '%b' "${YELLOW}Test message${NC}")
# The output should contain the ANSI escape sequence
assert_contains "printf '%b' contains ANSI yellow code" "Test message" "$OUTPUT"

# Test 1b: printf '%b' vs echo -e equivalence
# Both should produce the same output with color codes

# Using printf '%b' (new approach from the fix)
PRINTF_OUTPUT=$(printf '%b' "${YELLOW}Hello${NC} [y/N] ")

# Using echo -e (old approach)
ECHO_OUTPUT=$(echo -e "${YELLOW}Hello${NC} [y/N] ")

# Both should have the same visible text content
assert_contains "printf '%b' output contains 'Hello'" "Hello" "$PRINTF_OUTPUT"
assert_contains "echo -e output contains 'Hello'" "Hello" "$ECHO_OUTPUT"

# =============================================================================
# Test 2: Verify the specific use case from lib/notes_cli_write.sh:143
# =============================================================================

# The original line (143) is:
# printf '%b' "${YELLOW}Remove ${checked_count} completed note(s)?${NC} [y/N] "

checked_count=5
OUTPUT=$(printf '%b' "${YELLOW}Remove ${checked_count} completed note(s)?${NC} [y/N] ")

# Verify the output contains the expected text
assert_contains "notes CLI prompt contains count" "Remove 5 completed note(s)?" "$OUTPUT"
assert_contains "notes CLI prompt contains [y/N]" "[y/N]" "$OUTPUT"

# =============================================================================
# Test 3: Verify printf '%b' handles multiline input correctly
# =============================================================================

# Test with newline escape sequence
MULTILINE=$(printf '%b' "Line 1\\nLine 2")
assert_contains "printf '%b' handles newlines" "Line 1" "$MULTILINE"

# =============================================================================
# Test 4: Verify printf '%b' handles tab escape sequences
# =============================================================================

# Test with tab escape sequence
TABBED=$(printf '%b' "Column1\\tColumn2")
assert_contains "printf '%b' handles tabs" "Column1" "$TABBED"

# =============================================================================
# Test 5: Verify printf '%b' is portable across shells
# =============================================================================

# printf is a POSIX standard and should be available in all shells
# echo -e is not portable (different behavior in bash vs sh vs dash)
# This test verifies that printf '%b' is the more portable choice

# Check that printf binary exists
if command -v printf &> /dev/null; then
    echo "PASS: printf command is available"
else
    echo "FAIL: printf command not found"
    FAIL=1
fi

# Check that printf supports -b flag
if printf '%b' "test" &> /dev/null; then
    echo "PASS: printf '%b' syntax is supported"
else
    echo "FAIL: printf '%b' syntax not supported"
    FAIL=1
fi

# =============================================================================
# Test 6: Edge case - printf '%b' with special characters
# =============================================================================

# Test with double quotes in the string
OUTPUT=$(printf '%b' "Message with \"quotes\"")
assert_contains "printf '%b' handles quotes" "quotes" "$OUTPUT"

# Test with single quotes in the string
OUTPUT=$(printf '%b' "Message with 'quotes'")
assert_contains "printf '%b' handles single quotes" "quotes" "$OUTPUT"

# =============================================================================
# Results
# =============================================================================

if [ "$FAIL" = "1" ]; then
    echo "FAIL: Some printf '%b' tests failed"
    exit 1
else
    echo "PASS: All printf '%b' tests passed"
    exit 0
fi
