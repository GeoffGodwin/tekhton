#!/usr/bin/env bash
# =============================================================================
# test_clear_resolved_nonblocking_notes.sh — Resolved section cleanup tests
#
# Tests clear_resolved_nonblocking_notes() behavior:
# - Returns 0 when file doesn't exist
# - Outputs resolved items before clearing (for metrics capture)
# - Preserves the ## Resolved heading
# - Clears all items below the heading
# - Works with empty resolved sections
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Minimal pipeline globals ------------------------------------------------
PROJECT_DIR="$TMPDIR"
TEKHTON_DIR=".tekhton"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"
NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
TEKHTON_SESSION_DIR="$TMPDIR"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_core_normalize.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        cat "$file" | head -20 | sed 's/^/  /'
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' should NOT be in $file"
        FAIL=1
    fi
}

NB_FILE="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
cd "$TMPDIR"

# =============================================================================
# Test 1: Absent file returns 0 and no output
# =============================================================================

rm -f "$NB_FILE"
output=$(clear_resolved_nonblocking_notes)
assert_eq "1.1 absent file returns cleanly" "" "$output"

# =============================================================================
# Test 2: Empty ## Resolved section
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — missing null check

## Resolved
EOF

output=$(clear_resolved_nonblocking_notes)
assert_eq "2.1 empty resolved section returns nothing" "" "$output"

# Verify file is unchanged
assert_file_contains "2.2 heading preserved" "$NB_FILE" "^## Resolved"
assert_file_contains "2.3 open section preserved" "$NB_FILE" "^## Open"

# =============================================================================
# Test 3: Single resolved item is output and cleared
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — missing null check

## Resolved
- [x] `lib/bar.sh:20` — fixed typo
EOF

output=$(clear_resolved_nonblocking_notes)
echo "$output" | grep -q "fixed typo" || {
    echo "FAIL: 3.1 output should contain the resolved item"
    FAIL=1
}

# Verify the item is gone from the file
assert_file_not_contains "3.2 item cleared from file" "$NB_FILE" "fixed typo"

# Verify heading is still there
assert_file_contains "3.3 heading preserved" "$NB_FILE" "^## Resolved"

# =============================================================================
# Test 4: Multiple resolved items are all output and cleared
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — missing null check

## Resolved
- [x] `lib/bar.sh:20` — fixed typo
- [x] `lib/baz.sh:30` — added docstring
- [x] `lib/qux.sh:40` — refactored logic
EOF

output=$(clear_resolved_nonblocking_notes)

# Count lines of output (should be 3)
line_count=$(echo "$output" | grep -c "^- " || true)
assert_eq "4.1 three items output" "3" "$line_count"

# Verify all items are output
echo "$output" | grep -q "fixed typo" || {
    echo "FAIL: 4.2 output missing first item"
    FAIL=1
}
echo "$output" | grep -q "added docstring" || {
    echo "FAIL: 4.3 output missing second item"
    FAIL=1
}
echo "$output" | grep -q "refactored logic" || {
    echo "FAIL: 4.4 output missing third item"
    FAIL=1
}

# Verify all items are cleared
assert_file_not_contains "4.5 items cleared" "$NB_FILE" "fixed typo"
assert_file_not_contains "4.6 items cleared" "$NB_FILE" "added docstring"
assert_file_not_contains "4.7 items cleared" "$NB_FILE" "refactored logic"

# =============================================================================
# Test 5: ## Resolved heading is preserved
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — missing null check

## Resolved
- [x] `lib/bar.sh:20` — fixed typo
- [x] `lib/baz.sh:30` — added docstring
EOF

clear_resolved_nonblocking_notes > /dev/null

# Verify the ## Resolved heading is still there
if ! grep -q "^## Resolved" "$NB_FILE" 2>/dev/null; then
    echo "FAIL: 5.1 ## Resolved heading should be preserved"
    FAIL=1
fi

# Verify nothing else is under it
if grep -A 10 "^## Resolved" "$NB_FILE" | grep -q "^- "; then
    echo "FAIL: 5.2 items should be cleared, not heading"
    FAIL=1
fi

# =============================================================================
# Test 6: ## Open section is untouched
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — open item 1
- [ ] `lib/bar.sh:20` — open item 2

## Resolved
- [x] `lib/baz.sh:30` — resolved item
EOF

clear_resolved_nonblocking_notes > /dev/null

# Verify open items are untouched
assert_file_contains "6.1 open item 1 preserved" "$NB_FILE" "open item 1"
assert_file_contains "6.2 open item 2 preserved" "$NB_FILE" "open item 2"

# Verify resolved item is gone
assert_file_not_contains "6.3 resolved item cleared" "$NB_FILE" "resolved item"

# =============================================================================
# Test 7: Blank lines are preserved or cleaned up appropriately
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — open item

## Resolved
- [x] `lib/bar.sh:20` — resolved item 1
- [x] `lib/baz.sh:30` — resolved item 2
EOF

clear_resolved_nonblocking_notes > /dev/null

# File should be valid markdown with proper sections
if ! grep -q "^## " "$NB_FILE"; then
    echo "FAIL: 7.1 file should have markdown sections"
    FAIL=1
fi

# =============================================================================
# Test 8: Items with backticks and special characters are output correctly
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] Open item

## Resolved
- [x] `lib/foo.sh:10` — fix for `_special_var` handling
- [x] `tests/test_*.sh` — add coverage
EOF

output=$(clear_resolved_nonblocking_notes)

# Output should contain the backticks
echo "$output" | grep -q "_special_var" || {
    echo "FAIL: 8.1 special characters should be in output"
    FAIL=1
}

echo "$output" | grep -q "test_\*\.sh" || {
    echo "FAIL: 8.2 glob patterns should be in output"
    FAIL=1
}

# =============================================================================
# Test 9: Blank-line count stability after clearing resolved items (M73)
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — open item


## Resolved
- [x] `lib/bar.sh:20` — resolved item 1

- [x] `lib/baz.sh:30` — resolved item 2

EOF

clear_resolved_nonblocking_notes > /dev/null

# After clearing + normalization, no runs of >= 2 blank lines should remain
double_blank=$(awk '/^[[:space:]]*$/{b++; if(b>=2){found=1}} /[^[:space:]]/{b=0} END{print found+0}' "$NB_FILE")
if [ "$double_blank" -eq 0 ]; then
    echo "PASS: 9.1 no double-blank runs after clearing resolved"
else
    echo "FAIL: 9.1 found consecutive blank lines after clear_resolved_nonblocking_notes"
    cat "$NB_FILE" | sed 's/^/  /'
    FAIL=1
fi

# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
