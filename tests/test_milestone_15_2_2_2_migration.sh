#!/usr/bin/env bash
# test_milestone_15_2_2_2_migration.sh
# Verifies the one-time CLAUDE.md migration acceptance criteria for Milestone 15.2.2.2
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_MD="$TEKHTON_HOME/CLAUDE.md"
ARCHIVE_MD="$TEKHTON_HOME/MILESTONE_ARCHIVE.md"

pass_count=0
fail_count=0

assert() {
  local desc="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    echo "  PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: $desc"
    fail_count=$((fail_count + 1))
  fi
}

echo "=== Milestone 15.2.2.2 Migration: CLAUDE.md Acceptance Criteria ==="

# --- Criterion 1: Zero [DONE] one-liner lines ---
done_count=$(grep -c "^#### \[DONE\]" "$CLAUDE_MD" 2>/dev/null || true)
assert "Zero '#### [DONE]' one-liner lines in CLAUDE.md (found: $done_count)" \
  "$([ "$done_count" -eq 0 ] && echo 0 || echo 1)"

# --- Criterion 2: Archive pointer comment present in each ### Milestone Plan section ---
# There are two ### Milestone Plan sections in the active milestone area (lines 270, 296)
# Each should be followed (within a few lines) by the archive pointer comment.
pointer_comment="<!-- See MILESTONE_ARCHIVE.md for completed milestones -->"
pointer_count=$(grep -c "$pointer_comment" "$CLAUDE_MD" 2>/dev/null || true)
assert "Archive pointer comment present at least once (found: $pointer_count)" \
  "$([ "$pointer_count" -ge 1 ] && echo 0 || echo 1)"

# Verify pointer appears after "### Milestone Plan" in the two initiative sections
# Check that it appears within the first 5 lines after each ### Milestone Plan heading
section_lines=$(grep -n "^### Milestone Plan" "$CLAUDE_MD" | head -2 | awk -F: '{print $1}')
pointer_after_section=0
for section_line in $section_lines; do
  # Check next 5 lines for the pointer
  found=$(awk -v start="$section_line" -v pattern="$pointer_comment" \
    'NR > start && NR <= start+5 && index($0, pattern) {found=1} END {print found+0}' \
    "$CLAUDE_MD")
  if [ "$found" = "1" ]; then
    pointer_after_section=$((pointer_after_section + 1))
  fi
done
assert "Archive pointer follows both ### Milestone Plan headings (found: $pointer_after_section/2)" \
  "$([ "$pointer_after_section" -ge 2 ] && echo 0 || echo 1)"

# --- Criterion 3: Orphaned agent output text removed ---
orphan1_count=$(grep -c "This milestone has two cleanly independent pieces" "$CLAUDE_MD" 2>/dev/null || true)
assert "Orphaned text 'This milestone has two cleanly independent pieces' absent (found: $orphan1_count)" \
  "$([ "$orphan1_count" -eq 0 ] && echo 0 || echo 1)"

orphan2_count=$(grep -c "Now I have the full picture" "$CLAUDE_MD" 2>/dev/null || true)
assert "Orphaned text 'Now I have the full picture' absent (found: $orphan2_count)" \
  "$([ "$orphan2_count" -eq 0 ] && echo 0 || echo 1)"

# Horizontal rule orphan (bare --- line) should not appear in CLAUDE.md
horiz_count=$(grep -c "^---$" "$CLAUDE_MD" 2>/dev/null || true)
assert "No bare horizontal rule '---' lines in CLAUDE.md (found: $horiz_count)" \
  "$([ "$horiz_count" -eq 0 ] && echo 0 || echo 1)"

# --- Criterion 4: Active (non-archived) milestone headings exist ---
# Dynamically discover milestones from CLAUDE.md rather than hardcoding numbers.
# Any #### Milestone N: heading that isn't [DONE] counts as active.
active_count=$(grep -c '^#### Milestone [0-9]' "$CLAUDE_MD" 2>/dev/null || true)
assert "At least one active milestone heading in CLAUDE.md (found: $active_count)" \
  "$([ "$active_count" -ge 1 ] && echo 0 || echo 1)"

# Verify no active heading is a [DONE] one-liner (covered by criterion 1, but belt-and-suspenders)
done_active=$(grep -c '^#### \[DONE\] Milestone' "$CLAUDE_MD" 2>/dev/null || true)
assert "No [DONE] headings remain among active milestones (found: $done_active)" \
  "$([ "$done_active" -eq 0 ] && echo 0 || echo 1)"

# --- Criterion 5: No triple-or-more consecutive blank lines ---
max_blanks=$(awk 'BEGIN{n=0; max=0} /^$/{n++; if(n>max) max=n} /^.+$/{n=0} END{print max}' "$CLAUDE_MD")
assert "No triple-or-more consecutive blank lines (max consecutive: $max_blanks)" \
  "$([ "$max_blanks" -lt 3 ] && echo 0 || echo 1)"

# --- Criterion 6: MILESTONE_ARCHIVE.md unchanged (has content) ---
if [ -f "$ARCHIVE_MD" ]; then
  archive_lines=$(wc -l < "$ARCHIVE_MD")
  assert "MILESTONE_ARCHIVE.md exists and has content (lines: $archive_lines)" \
    "$([ "$archive_lines" -gt 0 ] && echo 0 || echo 1)"
else
  echo "  FAIL: MILESTONE_ARCHIVE.md does not exist"
  fail_count=$((fail_count + 1))
fi

# Summary
echo ""
echo "=== Results ==="
echo "Passed: $pass_count  Failed: $fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
