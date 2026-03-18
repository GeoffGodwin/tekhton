#!/usr/bin/env bash
# Test: Milestone archival functions — archive_completed_milestone, idempotency,
#       decimal milestones, _get_initiative_name, _extract_milestone_block,
#       _milestone_in_archive, archive_all_completed_milestones
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PROJECT_DIR="$TMPDIR_BASE"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Config stubs
PIPELINE_STATE_FILE="${TMPDIR_BASE}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR_BASE}/.claude/logs"
mkdir -p "${TMPDIR_BASE}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR_BASE}/.claude/MILESTONE_STATE.md"
MILESTONE_ARCHIVE_FILE="${TMPDIR_BASE}/MILESTONE_ARCHIVE.md"
export MILESTONE_ARCHIVE_FILE

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"

cd "$TMPDIR_BASE"

PASS=0
FAIL=0

# assert DESC RESULT — RESULT="0" is PASS, anything else is FAIL
assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: create a CLAUDE.md with a multi-line [DONE] milestone and an active one
make_claude_md() {
    local path="$1"
    cat > "$path" << 'EOF'
# Project Rules

## Current Initiative: Test Pipeline

#### [DONE] Milestone 1: Token Accounting
Add measurement infrastructure.

Files to modify:
- `lib/context.sh`

Acceptance criteria:
- `measure_context_size` returns counts

Watch For:
- Edge cases

Seeds Forward:
- Milestone 2 depends on this

#### Milestone 2: Context Compiler
Add task-scoped context assembly.

Acceptance criteria:
- `extract_relevant_sections` works

EOF
}

# Helper: create a CLAUDE.md with a decimal [DONE] milestone (0.5)
make_decimal_claude_md() {
    local path="$1"
    cat > "$path" << 'EOF'
# Project Rules

## Completed Initiative: Adaptive Pipeline 2.0

#### [DONE] Milestone 0.5: Agent Output Monitoring
Harden FIFO-based agent monitoring.

Files to modify:
- `lib/agent.sh`

Acceptance criteria:
- Agent running with JSON mode is not killed

Watch For:
- Windows differences

Seeds Forward:
- Milestone 1 depends on this

#### Milestone 1: Token Accounting
Add measurement infrastructure.

EOF
}

# =============================================================================
# Tests: _extract_milestone_block
# =============================================================================

echo "--- _extract_milestone_block ---"

CLAUDE_MD="${TMPDIR_BASE}/CLAUDE.md"
make_claude_md "$CLAUDE_MD"

# Test 1: extracts multi-line block for a [DONE] milestone
block=$(_extract_milestone_block "1" "$CLAUDE_MD")
assert "_extract_milestone_block returns content for [DONE] milestone 1" \
    "$(echo "$block" | grep -q "Token Accounting" && echo 0 || echo 1)"
assert "_extract_milestone_block includes body content" \
    "$(echo "$block" | grep -q "Files to modify" && echo 0 || echo 1)"
assert "_extract_milestone_block does not include next milestone content" \
    "$(echo "$block" | grep -q "Context Compiler" && echo 1 || echo 0)"

# Test 2: returns 1 for a single-line summary (already archived)
# No blank line between summary and next heading — blank lines count as body lines
SINGLE_LINE_MD="${TMPDIR_BASE}/single_line.md"
cat > "$SINGLE_LINE_MD" << 'EOF'
# Project Rules

#### [DONE] Milestone 3: Old Milestone
#### Milestone 4: Current Work
EOF
assert "_extract_milestone_block returns 1 for single-line summary (already archived)" \
    "$(_extract_milestone_block "3" "$SINGLE_LINE_MD" 2>/dev/null && echo 1 || echo 0)"

# Test 3: returns 1 when milestone not found
assert "_extract_milestone_block returns 1 for nonexistent milestone number" \
    "$(_extract_milestone_block "99" "$CLAUDE_MD" 2>/dev/null && echo 1 || echo 0)"

# Test 4: returns 1 when file does not exist
assert "_extract_milestone_block returns 1 for missing file" \
    "$(_extract_milestone_block "1" "${TMPDIR_BASE}/no_such_file.md" 2>/dev/null && echo 1 || echo 0)"

# =============================================================================
# Tests: _get_initiative_name
# =============================================================================

echo "--- _get_initiative_name ---"

make_claude_md "$CLAUDE_MD"

# Test 5: finds "Current Initiative" name for milestone 1
initiative=$(_get_initiative_name "$CLAUDE_MD" "1")
assert "_get_initiative_name finds 'Current Initiative' name for milestone 1" \
    "$([ "$initiative" = "Test Pipeline" ] && echo 0 || echo 1)"

# Test 6: finds "Completed Initiative" name for decimal milestone 0.5
DECIMAL_MD="${TMPDIR_BASE}/decimal.md"
make_decimal_claude_md "$DECIMAL_MD"
initiative=$(_get_initiative_name "$DECIMAL_MD" "0.5")
assert "_get_initiative_name finds 'Completed Initiative' name for milestone 0.5" \
    "$([ "$initiative" = "Adaptive Pipeline 2.0" ] && echo 0 || echo 1)"

# Test 7: fallback when no initiative heading present
NO_INIT_MD="${TMPDIR_BASE}/no_init.md"
cat > "$NO_INIT_MD" << 'EOF'
# Project

#### [DONE] Milestone 5: Orphan
Some content here.
Additional line.

#### Milestone 6: Next
EOF
initiative=$(_get_initiative_name "$NO_INIT_MD" "5")
assert "_get_initiative_name falls back to 'Unknown Initiative'" \
    "$([ "$initiative" = "Unknown Initiative" ] && echo 0 || echo 1)"

# =============================================================================
# Tests: _milestone_in_archive
# =============================================================================

echo "--- _milestone_in_archive ---"

ARCHIVE="${TMPDIR_BASE}/test_archive.md"
rm -f "$ARCHIVE"

# Test 8: returns 1 when archive file does not exist
assert "_milestone_in_archive returns 1 when archive file missing" \
    "$(_milestone_in_archive "1" "$ARCHIVE" 2>/dev/null && echo 1 || echo 0)"

# Test 9: returns 1 when milestone not present in archive
cat > "$ARCHIVE" << 'EOF'
# Milestone Archive

## Archived: 2026-01-01 — Some Initiative

#### [DONE] Milestone 2: Other Milestone
Content here.
Extra line.
EOF
assert "_milestone_in_archive returns 1 when milestone not present" \
    "$(_milestone_in_archive "1" "$ARCHIVE" 2>/dev/null && echo 1 || echo 0)"

# Test 10: returns 0 when milestone IS present in archive
assert "_milestone_in_archive returns 0 when milestone is present" \
    "$(_milestone_in_archive "2" "$ARCHIVE" 2>/dev/null && echo 0 || echo 1)"

# =============================================================================
# Tests: archive_completed_milestone — happy path
# =============================================================================

echo "--- archive_completed_milestone (happy path) ---"

make_claude_md "$CLAUDE_MD"
MAIN_ARCHIVE="${TMPDIR_BASE}/main_archive.md"
rm -f "$MAIN_ARCHIVE"
MILESTONE_ARCHIVE_FILE="$MAIN_ARCHIVE"

original_lines=$(wc -l < "$CLAUDE_MD")

# Test 11: successfully archives a [DONE] milestone
archive_completed_milestone "1" "$CLAUDE_MD"
assert "archive_completed_milestone returns 0 for [DONE] milestone 1" $?

# Test 12: archive file is created
assert "archive_completed_milestone creates archive file" \
    "$([ -f "$MAIN_ARCHIVE" ] && echo 0 || echo 1)"

# Test 13: archive contains milestone title
assert "archive_completed_milestone writes milestone title to archive" \
    "$(grep -q "Token Accounting" "$MAIN_ARCHIVE" && echo 0 || echo 1)"

# Test 14: archive contains body content
assert "archive_completed_milestone writes body content to archive" \
    "$(grep -q "Files to modify" "$MAIN_ARCHIVE" && echo 0 || echo 1)"

# Test 15: archive contains dated header
assert "archive_completed_milestone writes dated archive header" \
    "$(grep -qE '^## Archived: [0-9]{4}-[0-9]{2}-[0-9]{2} — ' "$MAIN_ARCHIVE" && echo 0 || echo 1)"

# Test 16: archive header includes initiative name
assert "archive_completed_milestone includes initiative name in header" \
    "$(grep -q "Test Pipeline" "$MAIN_ARCHIVE" && echo 0 || echo 1)"

# Test 17: CLAUDE.md shrinks (block replaced with summary line)
new_lines=$(wc -l < "$CLAUDE_MD")
assert "archive_completed_milestone reduces CLAUDE.md line count" \
    "$([ "$new_lines" -lt "$original_lines" ] && echo 0 || echo 1)"

# Test 18: CLAUDE.md retains the one-line summary
assert "archive_completed_milestone leaves summary line in CLAUDE.md" \
    "$(grep -q '#### \[DONE\] Milestone 1: Token Accounting' "$CLAUDE_MD" && echo 0 || echo 1)"

# Test 19: CLAUDE.md no longer contains the body
assert "archive_completed_milestone removes body content from CLAUDE.md" \
    "$(grep -q 'Files to modify:' "$CLAUDE_MD" && echo 1 || echo 0)"

# Test 20: non-targeted milestone is untouched
assert "archive_completed_milestone preserves non-done milestones" \
    "$(grep -q 'Context Compiler' "$CLAUDE_MD" && echo 0 || echo 1)"

# =============================================================================
# Tests: archive_completed_milestone — idempotency
# =============================================================================

echo "--- archive_completed_milestone (idempotency) ---"

archive_lines_after_first=$(wc -l < "$MAIN_ARCHIVE")
claude_lines_after_first=$(wc -l < "$CLAUDE_MD")

# Test 21: second call returns 1 (already archived)
assert "archive_completed_milestone returns 1 on second call (idempotent)" \
    "$(archive_completed_milestone "1" "$CLAUDE_MD" && echo 1 || echo 0)"

# Test 22: archive file does not grow on second call
archive_lines_after_second=$(wc -l < "$MAIN_ARCHIVE")
assert "archive_completed_milestone does not add duplicate archive entry" \
    "$([ "$archive_lines_after_second" = "$archive_lines_after_first" ] && echo 0 || echo 1)"

# Test 23: CLAUDE.md unchanged on second call
claude_lines_after_second=$(wc -l < "$CLAUDE_MD")
assert "archive_completed_milestone does not modify CLAUDE.md on second call" \
    "$([ "$claude_lines_after_second" = "$claude_lines_after_first" ] && echo 0 || echo 1)"

# Test 24: returns 1 for a milestone that is not marked [DONE]
assert "archive_completed_milestone returns 1 for non-done milestone" \
    "$(archive_completed_milestone "2" "$CLAUDE_MD" && echo 1 || echo 0)"

# =============================================================================
# Tests: archive_completed_milestone — decimal milestone 0.5
# =============================================================================

echo "--- archive_completed_milestone (decimal milestone 0.5) ---"

make_decimal_claude_md "$DECIMAL_MD"
DECIMAL_ARCHIVE="${TMPDIR_BASE}/decimal_archive.md"
rm -f "$DECIMAL_ARCHIVE"
MILESTONE_ARCHIVE_FILE="$DECIMAL_ARCHIVE"

decimal_original_lines=$(wc -l < "$DECIMAL_MD")

# Test 25: archives decimal milestone 0.5
archive_completed_milestone "0.5" "$DECIMAL_MD"
assert "archive_completed_milestone handles decimal milestone 0.5" $?

# Test 26: archive contains decimal milestone content
assert "archive_completed_milestone writes decimal milestone content to archive" \
    "$(grep -q "Agent Output Monitoring" "$DECIMAL_ARCHIVE" && echo 0 || echo 1)"

# Test 27: CLAUDE.md shrinks for decimal milestone
decimal_new_lines=$(wc -l < "$DECIMAL_MD")
assert "archive_completed_milestone shrinks CLAUDE.md for decimal milestone" \
    "$([ "$decimal_new_lines" -lt "$decimal_original_lines" ] && echo 0 || echo 1)"

# Test 28: summary line uses decimal notation
assert "archive_completed_milestone summary line uses decimal notation correctly" \
    "$(grep -q '#### \[DONE\] Milestone 0.5: Agent Output Monitoring' "$DECIMAL_MD" && echo 0 || echo 1)"

# Test 29: idempotency for decimal milestone
assert "archive_completed_milestone is idempotent for decimal milestone 0.5" \
    "$(archive_completed_milestone "0.5" "$DECIMAL_MD" && echo 1 || echo 0)"

# =============================================================================
# Tests: archive_all_completed_milestones
# =============================================================================

echo "--- archive_all_completed_milestones ---"

ALL_MD="${TMPDIR_BASE}/all_claude.md"
ALL_ARCHIVE="${TMPDIR_BASE}/all_archive.md"
rm -f "$ALL_ARCHIVE"
MILESTONE_ARCHIVE_FILE="$ALL_ARCHIVE"

cat > "$ALL_MD" << 'EOF'
# Project

## Current Initiative: Multi-Test

#### [DONE] Milestone 1: First Done
First milestone body.
Extra content line one.
Extra content line two.

#### [DONE] Milestone 2: Second Done
Second milestone body.
More content here.
Another line.

#### Milestone 3: Still Active
Active milestone content.

EOF

all_original_lines=$(wc -l < "$ALL_MD")

archive_all_completed_milestones "$ALL_MD"

# Test 30: archive contains Milestone 1 content
assert "archive_all_completed_milestones archives Milestone 1" \
    "$(grep -q "First Done" "$ALL_ARCHIVE" && echo 0 || echo 1)"

# Test 31: archive contains Milestone 2 content
assert "archive_all_completed_milestones archives Milestone 2" \
    "$(grep -q "Second Done" "$ALL_ARCHIVE" && echo 0 || echo 1)"

# Test 32: CLAUDE.md line count decreases after archival
all_new_lines=$(wc -l < "$ALL_MD")
assert "archive_all_completed_milestones reduces CLAUDE.md line count" \
    "$([ "$all_new_lines" -lt "$all_original_lines" ] && echo 0 || echo 1)"

# Test 33: active milestone 3 is untouched in CLAUDE.md
assert "archive_all_completed_milestones leaves active milestones intact" \
    "$(grep -q "Still Active" "$ALL_MD" && echo 0 || echo 1)"

# Test 34: idempotency — second call adds nothing more to archive
all_archive_lines_first=$(wc -l < "$ALL_ARCHIVE")
archive_all_completed_milestones "$ALL_MD"
all_archive_lines_second=$(wc -l < "$ALL_ARCHIVE")
assert "archive_all_completed_milestones is idempotent on second call" \
    "$([ "$all_archive_lines_second" = "$all_archive_lines_first" ] && echo 0 || echo 1)"

# Test 35: no-op when CLAUDE.md has no [DONE] milestones
NO_DONE_MD="${TMPDIR_BASE}/no_done.md"
cat > "$NO_DONE_MD" << 'EOF'
# Project

#### Milestone 1: Active Only
Active content here.

EOF
NO_DONE_ARCHIVE="${TMPDIR_BASE}/no_done_archive.md"
MILESTONE_ARCHIVE_FILE="$NO_DONE_ARCHIVE"
archive_all_completed_milestones "$NO_DONE_MD"
assert "archive_all_completed_milestones does not create archive when no done milestones" \
    "$([ ! -f "$NO_DONE_ARCHIVE" ] && echo 0 || echo 1)"

# Test 36: no-op and returns 0 when CLAUDE.md does not exist
MILESTONE_ARCHIVE_FILE="${TMPDIR_BASE}/ghost_archive.md"
archive_all_completed_milestones "${TMPDIR_BASE}/nonexistent.md"
assert "archive_all_completed_milestones returns 0 for missing CLAUDE.md" $?

# =============================================================================
# Summary
# =============================================================================

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
