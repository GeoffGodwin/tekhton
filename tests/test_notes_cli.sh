#!/usr/bin/env bash
# =============================================================================
# test_notes_cli.sh — Tests for lib/notes_cli.sh
#
# Covers:
#   get_notes_summary  — pipe-delimited contract (6 fields)
#   add_human_note     — section-insertion logic, tag validation, file creation
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --- Minimal pipeline globals ------------------------------------------------
PROJECT_DIR="$TMPDIR_TEST"
PROJECT_NAME="test-project"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_cli.sh"
source "${TEKHTON_HOME}/lib/notes_cli_write.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $name — expected '${expected}', got '${actual}'"
        FAIL=1
    fi
}

# Fixed-string grep (no regex interpretation). '--' stops option parsing so
# patterns starting with '-' are not misread as flags.
assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -qF -- "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — string '${pattern}' not found in ${file}"
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -qF -- "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — string '${pattern}' should NOT be in ${file}"
        FAIL=1
    fi
}

assert_returns_nonzero() {
    local name="$1"
    shift
    if "$@" 2>/dev/null; then
        echo "FAIL: $name — expected non-zero exit, got 0"
        FAIL=1
    fi
}

notes_file="${TMPDIR_TEST}/HUMAN_NOTES.md"
cd "$TMPDIR_TEST"

# =============================================================================
# get_notes_summary — no file
# =============================================================================

assert_eq "1.1 no file returns 0|0|0|0|0|0" "0|0|0|0|0|0" "$(get_notes_summary)"

# Verify all 6 fields parse correctly
IFS='|' read -r total bug feat polish checked unchecked <<< "$(get_notes_summary)"
assert_eq "1.2 total=0"     "0" "$total"
assert_eq "1.3 bug=0"       "0" "$bug"
assert_eq "1.4 feat=0"      "0" "$feat"
assert_eq "1.5 polish=0"    "0" "$polish"
assert_eq "1.6 checked=0"   "0" "$checked"
assert_eq "1.7 unchecked=0" "0" "$unchecked"

# =============================================================================
# get_notes_summary — mixed file (2 unchecked BUG, 1 checked BUG,
#                                  1 unchecked FEAT, 1 unchecked POLISH,
#                                  1 checked POLISH = 6 total, 4 unchecked)
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Notes — test

## Bugs
- [ ] [BUG] First bug
- [ ] [BUG] Second bug
- [x] [BUG] Fixed bug

## Features
- [ ] [FEAT] A feature

## Polish
- [ ] [POLISH] A polish item
- [x] [POLISH] Done polish
EOF

IFS='|' read -r total bug feat polish checked unchecked <<< "$(get_notes_summary)"
assert_eq "2.1 total=6"     "6" "$total"
assert_eq "2.2 bug=2"       "2" "$bug"
assert_eq "2.3 feat=1"      "1" "$feat"
assert_eq "2.4 polish=1"    "1" "$polish"
assert_eq "2.5 checked=2"   "2" "$checked"
assert_eq "2.6 unchecked=4" "4" "$unchecked"

# =============================================================================
# get_notes_summary — total = checked + unchecked arithmetic invariant
# =============================================================================

assert_eq "3.1 total == checked+unchecked" "$((checked + unchecked))" "$total"

# =============================================================================
# get_notes_summary — all checked file
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Notes

- [x] [BUG] Done 1
- [x] [FEAT] Done 2
EOF

IFS='|' read -r total bug feat polish checked unchecked <<< "$(get_notes_summary)"
assert_eq "4.1 all checked: unchecked=0" "0" "$unchecked"
assert_eq "4.2 all checked: checked=2"   "2" "$checked"
assert_eq "4.3 all checked: total=2"     "2" "$total"
assert_eq "4.4 all checked: bug=0"       "0" "$bug"
assert_eq "4.5 all checked: feat=0"      "0" "$feat"

# =============================================================================
# get_notes_summary — untagged unchecked notes counted in unchecked, not in tags
# =============================================================================

cat > "$notes_file" << 'EOF'
# Human Notes

- [ ] Untagged note
- [ ] [BUG] Tagged bug
EOF

IFS='|' read -r total bug feat polish checked unchecked <<< "$(get_notes_summary)"
assert_eq "5.1 untagged: unchecked=2" "2" "$unchecked"
assert_eq "5.2 untagged: bug=1"       "1" "$bug"
assert_eq "5.3 untagged: total=2"     "2" "$total"

# =============================================================================
# add_human_note — creates file when missing
# =============================================================================

rm -f "$notes_file"
add_human_note "My first note" 2>/dev/null
assert_file_contains "6.1 file created"  "$notes_file" "Human Notes"
assert_file_contains "6.2 note present"  "$notes_file" "- [ ] [FEAT] My first note"

# =============================================================================
# add_human_note — default tag is FEAT
# =============================================================================

rm -f "$notes_file"
add_human_note "Default tag note" 2>/dev/null
assert_file_contains "7.1 default tag is FEAT" "$notes_file" "- [ ] [FEAT] Default tag note"

# =============================================================================
# add_human_note — inserts BUG note into ## Bugs section
# =============================================================================

rm -f "$notes_file"
add_human_note "A bug note" "BUG" 2>/dev/null
assert_file_contains "8.1 BUG note present" "$notes_file" "- [ ] [BUG] A bug note"

# Verify it appears after ## Bugs and before ## Features
bugs_line=$(grep -n "^## Bugs" "$notes_file" | head -1 | cut -d: -f1)
note_line=$(grep -n "A bug note" "$notes_file" | head -1 | cut -d: -f1)
feat_line=$(grep -n "^## Features" "$notes_file" | head -1 | cut -d: -f1)
if [[ -n "$bugs_line" ]] && [[ -n "$note_line" ]] && [[ -n "$feat_line" ]]; then
    if [[ "$note_line" -gt "$bugs_line" ]] && [[ "$note_line" -lt "$feat_line" ]]; then
        : # correct
    else
        echo "FAIL: 8.2 BUG note not between ## Bugs and ## Features (lines: bugs=${bugs_line}, note=${note_line}, feat=${feat_line})"
        FAIL=1
    fi
else
    echo "FAIL: 8.2 could not find expected section lines in file"
    FAIL=1
fi

# =============================================================================
# add_human_note — inserts POLISH note into ## Polish section
# =============================================================================

rm -f "$notes_file"
add_human_note "A polish note" "POLISH" 2>/dev/null
assert_file_contains "9.1 POLISH note present" "$notes_file" "- [ ] [POLISH] A polish note"

polish_line=$(grep -n "^## Polish" "$notes_file" | head -1 | cut -d: -f1)
note_line=$(grep -n "A polish note" "$notes_file" | head -1 | cut -d: -f1)
if [[ -n "$polish_line" ]] && [[ -n "$note_line" ]]; then
    if [[ "$note_line" -gt "$polish_line" ]]; then
        : # correct
    else
        echo "FAIL: 9.2 POLISH note not after ## Polish (lines: polish=${polish_line}, note=${note_line})"
        FAIL=1
    fi
else
    echo "FAIL: 9.2 could not find expected section lines in file"
    FAIL=1
fi

# =============================================================================
# add_human_note — multiple notes in same section appear in insertion order
# =============================================================================

rm -f "$notes_file"
add_human_note "First bug" "BUG" 2>/dev/null
add_human_note "Second bug" "BUG" 2>/dev/null

first_line=$(grep -n "First bug" "$notes_file" | head -1 | cut -d: -f1)
second_line=$(grep -n "Second bug" "$notes_file" | head -1 | cut -d: -f1)
if [[ -n "$first_line" ]] && [[ -n "$second_line" ]] && [[ "$first_line" -lt "$second_line" ]]; then
    : # correct order
else
    echo "FAIL: 10.1 multiple BUG notes not in insertion order (first=${first_line}, second=${second_line})"
    FAIL=1
fi

# =============================================================================
# add_human_note — empty text rejected, invalid tags rejected
# =============================================================================

assert_returns_nonzero "11.1 empty text rejected"   add_human_note ""
assert_returns_nonzero "11.2 invalid tag rejected"  add_human_note "Some note" "INVALID"
assert_returns_nonzero "11.3 lowercase tag rejected" add_human_note "Some note" "bug"

# File should not be created by a rejected call on empty text
rm -f "$notes_file"
add_human_note "" 2>/dev/null || true
if [[ -f "$notes_file" ]]; then
    echo "FAIL: 11.4 file should not be created on empty text"
    FAIL=1
fi

# =============================================================================
# get_notes_summary — round-trip with add_human_note
# =============================================================================

rm -f "$notes_file"
add_human_note "Bug one" "BUG" 2>/dev/null
add_human_note "Bug two" "BUG" 2>/dev/null
add_human_note "Feature one" "FEAT" 2>/dev/null
add_human_note "Polish one" "POLISH" 2>/dev/null

IFS='|' read -r total bug feat polish checked unchecked <<< "$(get_notes_summary)"
assert_eq "12.1 round-trip: total=4"     "4" "$total"
assert_eq "12.2 round-trip: bug=2"       "2" "$bug"
assert_eq "12.3 round-trip: feat=1"      "1" "$feat"
assert_eq "12.4 round-trip: polish=1"    "1" "$polish"
assert_eq "12.5 round-trip: checked=0"   "0" "$checked"
assert_eq "12.6 round-trip: unchecked=4" "4" "$unchecked"

# =============================================================================
# Done
# =============================================================================

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "All notes_cli tests passed."
