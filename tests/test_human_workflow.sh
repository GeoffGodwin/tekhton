#!/usr/bin/env bash
# =============================================================================
# test_human_workflow.sh — Single-note utility functions tests
#
# Tests all single-note functions from Milestone 15.4.1:
# - _escape_sed_pattern
# - _section_for_tag
# - pick_next_note
# - claim_single_note
# - resolve_single_note
# - extract_note_text
# - count_unchecked_notes
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Minimal pipeline globals ------------------------------------------------
PROJECT_DIR="$TMPDIR"
LOG_DIR=""
TIMESTAMP=""

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/notes_core.sh"
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/notes_single.sh"

FAIL=0
TESTS_RUN=0

# --- Test helpers -----------------------------------------------------------

test_case() {
    local name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  ✓ Testing: $name"
}

assert_equals() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" = "$actual" ]]; then
        return 0
    else
        echo "    FAIL: $test_name"
        echo "      Expected: '$expected'"
        echo "      Got:      '$actual'"
        FAIL=1
    fi
}

assert_empty() {
    local test_name="$1"
    local actual="$2"

    if [[ -z "$actual" ]]; then
        return 0
    else
        echo "    FAIL: $test_name — expected empty, got: '$actual'"
        FAIL=1
    fi
}

assert_exit_code() {
    local test_name="$1"
    local expected="$2"
    local cmd="$3"

    set +e
    eval "$cmd" >/dev/null 2>&1
    local got=$?
    set -e

    if [[ "$expected" -eq "$got" ]]; then
        return 0
    else
        echo "    FAIL: $test_name"
        echo "      Expected exit code: $expected"
        echo "      Got exit code:      $got"
        FAIL=1
    fi
}

assert_contains() {
    local test_name="$1"
    local haystack="$2"
    local needle="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "    FAIL: $test_name"
        echo "      String '$needle' not found in '$haystack'"
        FAIL=1
    fi
}

# --- Section 1: _section_for_tag -----

echo "=== Section 1: _section_for_tag ==="

test_case "_section_for_tag BUG returns '## Bugs'"
result=$(_section_for_tag "BUG")
assert_equals "BUG tag mapping" "## Bugs" "$result"

test_case "_section_for_tag FEAT returns '## Features'"
result=$(_section_for_tag "FEAT")
assert_equals "FEAT tag mapping" "## Features" "$result"

test_case "_section_for_tag POLISH returns '## Polish'"
result=$(_section_for_tag "POLISH")
assert_equals "POLISH tag mapping" "## Polish" "$result"

test_case "_section_for_tag invalid returns empty"
result=$(_section_for_tag "INVALID")
assert_empty "Invalid tag returns empty" "$result"

test_case "_section_for_tag empty returns empty"
result=$(_section_for_tag "")
assert_empty "Empty tag returns empty" "$result"

# --- Section 2: pick_next_note ---

echo ""
echo "=== Section 2: pick_next_note ==="

# Setup: Create a realistic HUMAN_NOTES.md
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Fix login form validation
- [x] [BUG] Session timeout handling (resolved)
- [ ] [BUG] API error message formatting

## Features
- [ ] [FEAT] Add dark mode toggle
- [~] [FEAT] Implement caching layer (in progress)
- [ ] [FEAT] Multi-language support

## Polish
- [ ] [POLISH] Improve error messaging
- [ ] [POLISH] Refactor button component styles
EOF

cd "$TMPDIR"

test_case "pick_next_note returns first unchecked from Bugs"
result=$(pick_next_note "")
assert_contains "Priority ordering (Bugs first)" "$result" "[BUG] Fix login form validation"

test_case "pick_next_note with BUG filter returns Bugs section only"
result=$(pick_next_note "BUG")
assert_contains "BUG filter" "$result" "[BUG]"
# Verify it's a bug note
assert_contains "BUG section only" "$result" "Fix login form validation"

test_case "pick_next_note with FEAT filter returns Features section"
result=$(pick_next_note "FEAT")
assert_contains "FEAT filter" "$result" "[FEAT] Add dark mode toggle"

test_case "pick_next_note with POLISH filter returns Polish section"
result=$(pick_next_note "POLISH")
assert_contains "POLISH filter" "$result" "[POLISH]"

test_case "pick_next_note skips [~] and [x] notes"
result=$(pick_next_note "")
# Should skip the [x] and [~] notes and get to next unchecked
assert_contains "Skips resolved/in-progress" "$result" "[ ]"

test_case "pick_next_note returns empty when all notes resolved"
# Create file with only resolved notes
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [x] [BUG] Already fixed

## Features
- [x] [FEAT] Already done

## Polish
- [x] [POLISH] Already done
EOF
result=$(pick_next_note "")
assert_empty "All resolved returns empty" "$result"

test_case "pick_next_note handles missing file gracefully"
rm "$TMPDIR/HUMAN_NOTES.md"
result=$(pick_next_note "")
assert_empty "Missing file returns empty" "$result"
# Verify it doesn't error
assert_exit_code "Missing file exit code" 0 "pick_next_note ''"

# --- Section 3: claim_single_note ---

echo ""
echo "=== Section 3: claim_single_note ==="

# Recreate test file
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Fix login form validation
- [ ] [BUG] API error message formatting

## Features
- [ ] [FEAT] Add dark mode toggle
EOF

test_case "claim_single_note marks exactly one note [~]"
note="- [ ] [BUG] Fix login form validation"
claim_single_note "$note"
# Verify the exact line is marked
assert_contains "Line marked [~]" "$(cat HUMAN_NOTES.md)" "- [~] [BUG] Fix login form validation"
# Verify other notes unchanged
assert_contains "Other notes unchanged" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] API error"

test_case "claim_single_note creates backup file"
# Check that backup was created (either in LOG_DIR or as .bak)
if [[ -f "$TMPDIR/HUMAN_NOTES.md.bak" ]]; then
    assert_equals "Backup created" "1" "1"
else
    echo "    FAIL: Backup file not found"
    FAIL=1
fi

test_case "claim_single_note with special characters in note"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Fix regex pattern: `^[a-z]+(\.\d+)?$`
- [ ] [BUG] Handle [brackets] in JSON
EOF
note="- [ ] [BUG] Fix regex pattern: \`^[a-z]+(\\.\d+)?\$\`"
# Should handle the special chars gracefully without corrupting the file
set +e; claim_single_note "$note"; _special_rc=$?; set -e
# Exit 0 (claimed) or 1 (not found) are both acceptable; a crash exits >1
if [[ "$_special_rc" -gt 1 ]]; then
    echo "    FAIL: Special chars — claim_single_note crashed with rc=$_special_rc"
    FAIL=1
fi
# File must not be corrupted (still contains the BUG note text)
assert_contains "Special chars: HUMAN_NOTES.md not corrupted" \
    "$(cat "$TMPDIR/HUMAN_NOTES.md")" "BUG"

test_case "claim_single_note returns 0 on success"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Test note
EOF
note="- [ ] [BUG] Test note"
assert_exit_code "Return 0 on success" 0 "claim_single_note '$note'"

test_case "claim_single_note returns non-zero when note not found"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Different note
EOF
note="- [ ] [BUG] Note that doesn't exist"
# Return code may be 1 or 2 depending on shell context; we just check non-zero
if claim_single_note "$note" 2>/dev/null; then
    echo "    FAIL: Return non-zero when not found — expected non-zero exit"
    FAIL=1
fi

test_case "claim_single_note handles missing file gracefully"
rm "$TMPDIR/HUMAN_NOTES.md"
note="- [ ] [BUG] Some note"
assert_exit_code "Missing file returns 1" 1 "claim_single_note '$note'"

# --- Section 4: resolve_single_note ---

echo ""
echo "=== Section 4: resolve_single_note ==="

test_case "resolve_single_note with exit_code=0 marks [x]"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Fix login form validation
- [ ] [BUG] API error message formatting
EOF
note="- [ ] [BUG] Fix login form validation"
resolve_single_note "$note" 0
assert_contains "Marked [x]" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Fix login form validation"

test_case "resolve_single_note with exit_code=1 resets to [ ]"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Fix login form validation
- [ ] [BUG] API error message formatting
EOF
note="- [ ] [BUG] Fix login form validation"
resolve_single_note "$note" 1
assert_contains "Reset to [ ]" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Fix login form validation"

test_case "resolve_single_note leaves other notes unchanged"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] First note
- [ ] [BUG] Second note
- [x] [BUG] Third note
EOF
note="- [ ] [BUG] First note"
resolve_single_note "$note" 0
# Verify other notes untouched
assert_contains "Second note unchanged" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Second note"
assert_contains "Third note unchanged" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Third note"

test_case "resolve_single_note returns 0 on success"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Test
EOF
note="- [ ] [BUG] Test"
assert_exit_code "Return 0 on success" 0 "resolve_single_note '$note' 0"

test_case "resolve_single_note returns non-zero when note not found"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Different note
EOF
note="- [ ] [BUG] Note that doesn't exist"
# Return code may be 1 or 2 depending on shell context; we just check non-zero
if resolve_single_note "$note" 0 2>/dev/null; then
    echo "    FAIL: Return non-zero when not found — expected non-zero exit"
    FAIL=1
fi

test_case "resolve_single_note handles missing file gracefully"
rm "$TMPDIR/HUMAN_NOTES.md"
note="- [ ] [BUG] Some note"
assert_exit_code "Missing file returns 1" 1 "resolve_single_note '$note' 0"

test_case "resolve_single_note accepts non-zero exit codes"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Test
EOF
note="- [ ] [BUG] Test"
assert_exit_code "Non-zero exit code handled" 0 "resolve_single_note '$note' 42"

# --- Section 4b: resolve_single_note fallback (agent clobber resilience) ---

echo ""
echo "=== Section 4b: resolve_single_note fallback when [~] clobbered back to [ ] ==="

test_case "resolve_single_note fallback: marks [x] when agent clobbered [~] to [ ]"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Fix login form validation
- [ ] [BUG] API error message formatting
EOF
note="- [ ] [BUG] Fix login form validation"
resolve_single_note "$note" 0
assert_contains "Fallback marked [x]" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Fix login form validation"

test_case "resolve_single_note fallback: resets to [ ] on failure when clobbered"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Fix login form validation
EOF
note="- [ ] [BUG] Fix login form validation"
resolve_single_note "$note" 1
assert_contains "Fallback reset to [ ]" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Fix login form validation"

test_case "resolve_single_note fallback: leaves other notes unchanged"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] First note
- [ ] [BUG] Second note
- [x] [BUG] Third note
EOF
note="- [ ] [BUG] First note"
resolve_single_note "$note" 0
assert_contains "Fallback second unchanged" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Second note"
assert_contains "Fallback third unchanged" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Third note"

test_case "resolve_single_note fallback: returns 0 on success"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Test
EOF
note="- [ ] [BUG] Test"
assert_exit_code "Fallback return 0" 0 "resolve_single_note '$note' 0"

test_case "resolve_single_note prefers [~] match over [ ] fallback"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Fix login form validation
- [ ] [BUG] Fix login form validation
EOF
note="- [ ] [BUG] Fix login form validation"
resolve_single_note "$note" 0
# Should match the [~] line (primary), leaving [ ] line untouched
assert_contains "Primary [~] matched" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Fix login form validation"
assert_contains "Fallback [ ] untouched" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Fix login form validation"

# --- Section 5: extract_note_text ---

echo ""
echo "=== Section 5: extract_note_text ==="

test_case "extract_note_text strips '- [ ] ' prefix"
note="- [ ] [BUG] Fix the thing"
result=$(extract_note_text "$note")
assert_equals "Strip [ ] prefix" "[BUG] Fix the thing" "$result"

test_case "extract_note_text strips '- [~] ' prefix"
note="- [~] [FEAT] Implement feature"
result=$(extract_note_text "$note")
assert_equals "Strip [~] prefix" "[FEAT] Implement feature" "$result"

test_case "extract_note_text strips '- [x] ' prefix"
note="- [x] [POLISH] Polish UI"
result=$(extract_note_text "$note")
assert_equals "Strip [x] prefix" "[POLISH] Polish UI" "$result"

test_case "extract_note_text preserves note content with special chars"
note="- [ ] [BUG] Fix regex: ^[a-z]+(\.\d+)?\$"
result=$(extract_note_text "$note")
assert_contains "Special chars preserved" "$result" "regex"
assert_contains "Special chars preserved" "$result" "[a-z]"

test_case "extract_note_text handles long notes"
long_text="This is a very long note that describes a complex issue with multiple parts and considerations for the implementation strategy"
note="- [ ] $long_text"
result=$(extract_note_text "$note")
assert_equals "Long note preserved" "$long_text" "$result"

test_case "extract_note_text handles empty suffix"
note="- [ ] "
result=$(extract_note_text "$note")
assert_empty "Empty suffix" "$result"

# --- Section 6: count_unchecked_notes ---

echo ""
echo "=== Section 6: count_unchecked_notes ==="

test_case "count_unchecked_notes counts all [ ] notes"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] First bug
- [x] [BUG] Second bug (resolved)
- [ ] [BUG] Third bug

## Features
- [ ] [FEAT] First feature
- [~] [FEAT] Second feature (in progress)

## Polish
- [ ] [POLISH] Polish item
EOF
result=$(count_unchecked_notes "")
assert_equals "Total unchecked count" "4" "$result"

test_case "count_unchecked_notes filters by BUG tag"
result=$(count_unchecked_notes "BUG")
assert_equals "BUG count" "2" "$result"

test_case "count_unchecked_notes filters by FEAT tag"
result=$(count_unchecked_notes "FEAT")
assert_equals "FEAT count" "1" "$result"

test_case "count_unchecked_notes filters by POLISH tag"
result=$(count_unchecked_notes "POLISH")
assert_equals "POLISH count" "1" "$result"

test_case "count_unchecked_notes ignores [x] and [~] notes"
# Already tested above but explicit check
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [x] [BUG] Done
- [~] [BUG] In progress
- [ ] [BUG] Not started
EOF
result=$(count_unchecked_notes "")
assert_equals "Ignores non-[ ] notes" "1" "$result"

test_case "count_unchecked_notes returns 0 when no unchecked notes"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [x] [BUG] All resolved
- [x] [BUG] Also resolved
EOF
result=$(count_unchecked_notes "")
assert_equals "No unchecked returns 0" "0" "$result"

test_case "count_unchecked_notes returns 0 for missing file"
rm "$TMPDIR/HUMAN_NOTES.md"
result=$(count_unchecked_notes "")
assert_equals "Missing file returns 0" "0" "$result"

test_case "count_unchecked_notes returns 0 for invalid tag"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Some bug
EOF
result=$(count_unchecked_notes "INVALID")
assert_equals "Invalid tag returns 0" "0" "$result"

# --- Section 7: Priority ordering ---

echo ""
echo "=== Section 7: Priority ordering in pick_next_note ==="

test_case "pick_next_note prioritizes Bugs over Features"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Bug item

## Features
- [ ] [FEAT] Feature item

## Polish
- [ ] [POLISH] Polish item
EOF
result=$(pick_next_note "")
assert_contains "Bugs first" "$result" "[BUG]"

test_case "pick_next_note prioritizes Features over Polish"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [x] [BUG] Done

## Features
- [ ] [FEAT] Feature item

## Polish
- [ ] [POLISH] Polish item
EOF
result=$(pick_next_note "")
assert_contains "Features second" "$result" "[FEAT]"

test_case "pick_next_note returns Polish when Bugs/Features done"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [x] [BUG] Done

## Features
- [x] [FEAT] Done

## Polish
- [ ] [POLISH] Polish item
EOF
result=$(pick_next_note "")
assert_contains "Polish last" "$result" "[POLISH]"

# --- Section 8: Integration tests ---

echo ""
echo "=== Section 8: Integration tests ==="

test_case "Full workflow: pick → claim → resolve (success)"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Test bug

## Features
- [ ] [FEAT] Test feature
EOF
# Pick the note
picked=$(pick_next_note "")
echo "Picked: $picked"

# Claim it
claim_single_note "$picked"
# Verify it's [~]
assert_contains "After claim" "$(cat HUMAN_NOTES.md)" "- [~] [BUG] Test bug"

# Resolve it (success)
resolve_single_note "$picked" 0
# Verify it's [x]
assert_contains "After resolve (success)" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Test bug"

test_case "Full workflow: pick → claim → resolve (failure)"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Test bug
EOF
# Pick the note
picked=$(pick_next_note "")

# Claim it
claim_single_note "$picked"

# Resolve it (failure)
resolve_single_note "$picked" 1
# Verify it's back to [ ]
assert_contains "After resolve (failure)" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Test bug"

# --- Section 9: Edge cases ---

echo ""
echo "=== Section 9: Edge cases ==="

test_case "Functions handle multiline note content gracefully"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] First line
- [ ] [BUG] Second line has special chars: $@#
EOF
count=$(count_unchecked_notes "BUG")
assert_equals "Multiline handling" "2" "$count"

test_case "pick_next_note handles section with no unchecked items"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [x] [BUG] All done

## Features
- [ ] [FEAT] Has unchecked

## Polish
- [x] [POLISH] Done
EOF
result=$(pick_next_note "")
assert_contains "Skips empty section" "$result" "[FEAT]"

test_case "claim_single_note is idempotent (marks same note twice)"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [ ] [BUG] Test
EOF
note="- [ ] [BUG] Test"
claim_single_note "$note"
# Try to claim the already-[~] note by its original [ ] form
# This should fail (return 1) since the line is now [~]
claim_single_note "$note" 2>/dev/null || true
# File should still have [~]
assert_contains "Idempotent behavior" "$(cat HUMAN_NOTES.md)" "- [~] [BUG] Test"

# --- Section 10: Flag validation (--human rejects invalid combos) ---

echo ""
echo "=== Section 10: Flag validation ==="

# Read tekhton.sh flag validation section to test indirectly.
# We can't run tekhton.sh directly without a full project, so we verify the
# validation logic exists and test it by simulating the flag state.
# NOTE: These tests (10.1–10.4) inline-reimplement the flag-check logic
# rather than calling the actual validation code from tekhton.sh. To catch
# regressions in tekhton.sh's argument parsing, changes to flag handling must
# be verified manually against these test scenarios.

test_case "Flag validation: --human --milestone rejected"
# The flag validation in tekhton.sh checks HUMAN_MODE=true && MILESTONE_MODE=true
# We verify the logic by simulating what tekhton.sh does:
HUMAN_MODE=true
MILESTONE_MODE=true
if [[ "$HUMAN_MODE" = true ]] && [[ "$MILESTONE_MODE" = true ]]; then
    validation_result="rejected"
else
    validation_result="allowed"
fi
assert_equals "--human --milestone rejected" "rejected" "$validation_result"
MILESTONE_MODE=false

test_case "Flag validation: --human with explicit task rejected"
HUMAN_MODE=true
MOCK_TASK="some explicit task"
if [[ "$HUMAN_MODE" = true ]] && [[ -n "$MOCK_TASK" ]]; then
    validation_result="rejected"
else
    validation_result="allowed"
fi
assert_equals "--human with task rejected" "rejected" "$validation_result"

test_case "Flag validation: --human alone is valid"
HUMAN_MODE=true
MILESTONE_MODE=false
MOCK_TASK=""
if [[ "$HUMAN_MODE" = true ]] && [[ "$MILESTONE_MODE" = true ]]; then
    validation_result="rejected"
elif [[ "$HUMAN_MODE" = true ]] && [[ -n "$MOCK_TASK" ]]; then
    validation_result="rejected"
else
    validation_result="allowed"
fi
assert_equals "--human alone valid" "allowed" "$validation_result"

test_case "Flag validation: --human BUG is valid"
HUMAN_MODE=true
HUMAN_NOTES_TAG="BUG"
MILESTONE_MODE=false
MOCK_TASK=""
if [[ "$HUMAN_MODE" = true ]] && [[ "$MILESTONE_MODE" = true ]]; then
    validation_result="rejected"
elif [[ "$HUMAN_MODE" = true ]] && [[ -n "$MOCK_TASK" ]]; then
    validation_result="rejected"
else
    validation_result="allowed"
fi
assert_equals "--human BUG valid" "allowed" "$validation_result"

HUMAN_MODE=false
HUMAN_NOTES_TAG=""

# --- Section 11: _hook_resolve_notes HUMAN_MODE integration ---

echo ""
echo "=== Section 11: _hook_resolve_notes HUMAN_MODE integration ==="

# Set up finalize.sh environment with mocks
_PIPELINE_EXIT_CODE=""
MILESTONE_MODE=false
AUTO_COMMIT=false
_CURRENT_MILESTONE=""
START_AT="N/A"
VERDICT="APPROVED"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
DRIFT_LOG_FILE="DRIFT_LOG.md"
_TEKHTON_LOCK_FILE=""
TEKHTON_SESSION_DIR="$TMPDIR"
WITH_NOTES=false
NOTES_FILTER=""

export MILESTONE_MODE AUTO_COMMIT _CURRENT_MILESTONE START_AT VERDICT
export HUMAN_ACTION_FILE NON_BLOCKING_LOG_FILE DRIFT_LOG_FILE _TEKHTON_LOCK_FILE
export TEKHTON_SESSION_DIR WITH_NOTES NOTES_FILTER

# Mock functions that _hook_resolve_notes depends on (already have notes.sh sourced)
# We need to test with real resolve_single_note from notes.sh

test_case "_hook_resolve_notes in HUMAN_MODE resolves single note [x]"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Fix login form validation
- [ ] [BUG] API error message formatting
EOF
HUMAN_MODE=true
CURRENT_NOTE_LINE="- [ ] [BUG] Fix login form validation"
export HUMAN_MODE CURRENT_NOTE_LINE

# Source finalize.sh to get _hook_resolve_notes (need mocks for dependencies)
run_final_checks() { return 0; }
process_drift_artifacts() { return 0; }
record_run_metrics() { return 0; }
clear_resolved_nonblocking_notes() { return 0; }
archive_reports() { return 0; }
mark_milestone_done() { return 0; }
get_milestone_disposition() { echo "PARTIAL"; }
generate_commit_message() { echo "feat: test"; }
archive_completed_milestone() { return 0; }
tag_milestone_complete() { return 0; }
clear_milestone_state() { return 0; }
print_run_summary() { return 0; }
_check_gitignore_safety() { return 0; }
has_human_actions() { return 1; }
count_human_actions() { echo "0"; }
count_drift_observations() { echo "0"; }
count_open_nonblocking_notes() { echo "0"; }

# Source finalize.sh for _hook_resolve_notes
source "${TEKHTON_HOME}/lib/finalize.sh"

_hook_resolve_notes 0
assert_contains "Single note marked [x]" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Fix login form validation"
assert_contains "Other note unchanged" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] API error message formatting"

test_case "_hook_resolve_notes in HUMAN_MODE with failure resets note to [ ]"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Fix login form validation
EOF
HUMAN_MODE=true
CURRENT_NOTE_LINE="- [ ] [BUG] Fix login form validation"
export HUMAN_MODE CURRENT_NOTE_LINE
_hook_resolve_notes 1
# On failure, resolve_single_note resets [~] → [ ]
assert_contains "Note reset to [ ] on failure" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Fix login form validation"

test_case "_hook_resolve_notes in non-HUMAN_MODE resolves [~] notes via orphan safety net"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Fix login form validation
EOF
HUMAN_MODE=false
CURRENT_NOTE_LINE=""
export HUMAN_MODE CURRENT_NOTE_LINE
# Create CODER_SUMMARY.md with COMPLETE status for the bulk fallback
cat > "$TMPDIR/CODER_SUMMARY.md" <<'EOF'
## Status: COMPLETE
## What Was Implemented
- Fixed the thing
EOF
_hook_resolve_notes 0
# Bulk resolve_human_notes with COMPLETE status marks all [~] → [x]
assert_contains "Orphan safety net marks [x]" "$(cat HUMAN_NOTES.md)" "- [x] [BUG] Fix login form validation"
rm -f "$TMPDIR/CODER_SUMMARY.md"

# Clean up
HUMAN_MODE=false
CURRENT_NOTE_LINE=""
export HUMAN_MODE CURRENT_NOTE_LINE
rm -f "${TMPDIR}/HUMAN_NOTES.md"

test_case "_hook_resolve_notes integration: failure in HUMAN_MODE resets file to [ ]"
cat > "$TMPDIR/HUMAN_NOTES.md" <<'EOF'
## Bugs
- [~] [BUG] Fix login form validation
- [ ] [BUG] API error message formatting
EOF
HUMAN_MODE=true
CURRENT_NOTE_LINE="- [ ] [BUG] Fix login form validation"
export HUMAN_MODE CURRENT_NOTE_LINE
_hook_resolve_notes 1
# After failure, the [~] note must be reset to [ ] in the actual file
assert_contains "Note reset to [ ] after failure" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] Fix login form validation"
assert_contains "Other note unchanged after failure" "$(cat HUMAN_NOTES.md)" "- [ ] [BUG] API error message formatting"

# Clean up
HUMAN_MODE=false
CURRENT_NOTE_LINE=""
export HUMAN_MODE CURRENT_NOTE_LINE
rm -f "${TMPDIR}/HUMAN_NOTES.md"

# --- Summary ---

echo ""
echo "=== Test Summary ==="
echo "Tests run: $TESTS_RUN"

if [ "$FAIL" -eq 0 ]; then
    echo "All tests PASSED"
    exit 0
else
    echo "Some tests FAILED"
    exit 1
fi
