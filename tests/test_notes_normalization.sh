#!/usr/bin/env bash
# =============================================================================
# test_notes_normalization.sh — Regression tests for blank-line normalization
#
# M73: Tests _normalize_markdown_blank_runs() idempotency, interior-blank
# collapse after item removal, and fenced code block safety.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Minimal pipeline globals ------------------------------------------------
PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"
TEKHTON_DIR=".tekhton"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"
HUMAN_NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
NOTES_FILTER=""
LOG_DIR="$TMPDIR"
TIMESTAMP="test"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_core_normalize.sh"
source "${TEKHTON_HOME}/lib/notes.sh"

FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

count_blank_lines() {
    grep -c '^[[:space:]]*$' "$1" || true
}

# =============================================================================
# Test 1: Idempotent on a clean file
#
# Start with HUMAN_NOTES.md containing no [x] items and normal spacing.
# Call clear_completed_human_notes 5 times in a row. Assert the SHA-256 of
# the file is identical after each call.
# =============================================================================

NOTES_FILE="${PROJECT_DIR}/${HUMAN_NOTES_FILE}"

cat > "$NOTES_FILE" << 'EOF'
# Human Notes

## Bugs

- [ ] [BUG] Fix login timeout <!-- note:n001 -->

## Features

- [ ] [FEAT] Add dark mode <!-- note:n002 -->
- [ ] [FEAT] Add export CSV <!-- note:n003 -->

## Polish

- [ ] [POLISH] Align header spacing <!-- note:n004 -->
EOF

baseline_sha=$(sha256sum "$NOTES_FILE" | cut -d' ' -f1)
for i in 1 2 3 4 5; do
    clear_completed_human_notes 2>/dev/null
    sha=$(sha256sum "$NOTES_FILE" | cut -d' ' -f1)
    if [[ "$sha" != "$baseline_sha" ]]; then
        fail "1.1 idempotency broken on iteration $i"
        break
    fi
done
if [[ "$sha" == "$baseline_sha" ]]; then
    pass "1.1 idempotent on clean file — SHA unchanged after 5 calls"
fi

# =============================================================================
# Test 2: Interior-blank collapse after removal
#
# Start with a file that has:
#   - [ ] A, blank, - [x] B, - [x] C, blank, - [ ] D
# After clear_completed_human_notes, assert:
#   - [ ] A and - [ ] D remain
#   - No [x] lines remain
#   - Exactly one blank line between A and D
# =============================================================================

cat > "$NOTES_FILE" << 'EOF'
## Notes

- [ ] Item A <!-- note:n010 -->

- [x] Item B <!-- note:n011 -->
- [x] Item C <!-- note:n012 -->

- [ ] Item D <!-- note:n013 -->
EOF

clear_completed_human_notes 2>/dev/null

if ! grep -q 'Item A' "$NOTES_FILE"; then
    fail "2.1 Item A should remain"
else
    pass "2.1 Item A preserved"
fi

if ! grep -q 'Item D' "$NOTES_FILE"; then
    fail "2.2 Item D should remain"
else
    pass "2.2 Item D preserved"
fi

if grep -q '\[x\]' "$NOTES_FILE"; then
    fail "2.3 No [x] lines should remain"
else
    pass "2.3 All [x] items removed"
fi

# Count blank lines between A and D. After normalization there should be
# exactly one blank line between the two surviving items.
between=$(sed -n '/Item A/,/Item D/p' "$NOTES_FILE" | grep -c '^[[:space:]]*$' || true)
if [[ "$between" -eq 1 ]]; then
    pass "2.4 Exactly one blank line between surviving items"
else
    fail "2.4 Expected 1 blank line between A and D, got $between"
fi

# =============================================================================
# Test 3: Description block removal with trailing blank
#
# Start with:
#   - [x] B
#     > Description line
#
#   - [ ] C
# After clear_completed_human_notes, assert B and description are gone and
# only one blank line (at most) sits between the section header and C.
# =============================================================================

cat > "$NOTES_FILE" << 'EOF'
## Notes

- [x] Item B <!-- note:n020 -->
  > Description of B

- [ ] Item C <!-- note:n021 -->
EOF

clear_completed_human_notes 2>/dev/null

if grep -q 'Item B' "$NOTES_FILE"; then
    fail "3.1 Item B should be removed"
else
    pass "3.1 Item B removed"
fi

if grep -q 'Description of B' "$NOTES_FILE"; then
    fail "3.2 Description should be removed"
else
    pass "3.2 Description removed"
fi

if ! grep -q 'Item C' "$NOTES_FILE"; then
    fail "3.3 Item C should remain"
else
    pass "3.3 Item C preserved"
fi

# Verify no excessive blank lines remain
total_blanks=$(count_blank_lines "$NOTES_FILE")
if [[ "$total_blanks" -le 1 ]]; then
    pass "3.4 At most one blank line in result ($total_blanks)"
else
    fail "3.4 Expected at most 1 blank line, got $total_blanks"
fi

# =============================================================================
# Test 4: _normalize_markdown_blank_runs preserves fenced code blocks
# =============================================================================

TEST_FILE="${TMPDIR}/fenced_test.md"
cat > "$TEST_FILE" << 'HEREDOC'
## Example

Some text.


```bash
echo "hello"

echo "world"
```


More text.
HEREDOC

_normalize_markdown_blank_runs "$TEST_FILE"

# Blank lines inside the fence must be preserved
fence_blanks=$(sed -n '/^```bash/,/^```$/p' "$TEST_FILE" | grep -c '^[[:space:]]*$' || true)
if [[ "$fence_blanks" -eq 1 ]]; then
    pass "4.1 Blank line inside fenced code block preserved"
else
    fail "4.1 Expected 1 blank inside fence, got $fence_blanks"
fi

# The two blank lines before/after the fence should be collapsed to one each
outside_blanks=$(grep -c '^[[:space:]]*$' "$TEST_FILE" || true)
# Before "Some text.": 1, before fence: 1, inside fence: 1, after fence: 1 = 4 total
if [[ "$outside_blanks" -le 4 ]]; then
    pass "4.2 Exterior blank-line runs collapsed ($outside_blanks total)"
else
    fail "4.2 Expected at most 4 blank lines total, got $outside_blanks"
fi

# =============================================================================
# Test 5: _normalize_markdown_blank_runs idempotency
# =============================================================================

IDEM_FILE="${TMPDIR}/idem_test.md"
cat > "$IDEM_FILE" << 'EOF'


## Section A

- item 1



- item 2


## Section B

Content.


EOF

_normalize_markdown_blank_runs "$IDEM_FILE"
sha1=$(sha256sum "$IDEM_FILE" | cut -d' ' -f1)

_normalize_markdown_blank_runs "$IDEM_FILE"
sha2=$(sha256sum "$IDEM_FILE" | cut -d' ' -f1)

if [[ "$sha1" == "$sha2" ]]; then
    pass "5.1 _normalize_markdown_blank_runs is idempotent"
else
    fail "5.1 Second normalization changed the file"
fi

# Verify leading blanks were stripped
first_line=$(head -1 "$IDEM_FILE")
if [[ "$first_line" == "## Section A" ]]; then
    pass "5.2 Leading blank lines stripped"
else
    fail "5.2 Leading blanks not stripped — first line: '$first_line'"
fi

# Verify trailing blank lines stripped (file ends with single newline)
last_line=$(tail -1 "$IDEM_FILE")
if [[ -n "$last_line" ]]; then
    pass "5.3 Trailing blank lines stripped"
else
    fail "5.3 File has trailing blank lines"
fi

# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
