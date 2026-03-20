# Scout Report — Milestone 15.2: Milestone Marking, Archival Cleanup, and [DONE] Migration

## Relevant Files

- **lib/milestone_ops.sh** — Exists (285 lines). Contains `clear_milestone_state()` and accept-checking functions. Will need to add `mark_milestone_done()` function to programmatically mark milestones as [DONE] in CLAUDE.md.

- **lib/milestone_archival.sh** — Exists (296 lines). Contains `archive_completed_milestone()` which currently extracts a milestone block and replaces it with a one-liner summary `#### [DONE] Milestone N: Title`. Needs modification to fully REMOVE the [DONE] one-liner from CLAUDE.md instead of leaving it behind. Also contains helper functions: `_extract_milestone_block()`, `_get_initiative_name()`, `_milestone_in_archive()`.

- **lib/milestones.sh** — Exists (300 lines). Contains the `is_milestone_done()` function (line ~130) that checks if a milestone heading has a [DONE] marker. This is a dependency used by `archive_completed_milestone()` to verify the milestone is marked [DONE] before archiving. Also contains `parse_milestones()` which already handles both `#### Milestone N:` and `#### [DONE] Milestone N:` patterns.

- **CLAUDE.md** — Exists (main reference document). Currently contains ~26 `#### [DONE] Milestone N: Title` one-liner entries scattered across two initiative sections: "Planning Phase Quality Overhaul" and "Adaptive Pipeline 2.0". These are already archived in MILESTONE_ARCHIVE.md and need to be removed in the one-time migration step. Also contains the milestone plan structure that `mark_milestone_done()` will modify.

- **MILESTONE_ARCHIVE.md** — Exists (archive for completed milestones). Contains all the full milestone blocks that have been archived. Already has proper structure with timestamps and initiative names. Will not be modified directly by this milestone.

- **tekhton.sh** — Exists (1203 lines). Contains two calls to `archive_completed_milestone()` at lines 1173 and 1191 in the commit section (inside the `y|Y` case handlers). No changes needed to tekhton.sh for the core functionality, though Milestone 15.3 will consolidate this into a `finalize_run()` function.

## Key Symbols

- **is_milestone_done** (lib/milestones.sh line ~130) — returns 0 if milestone has [DONE] marker, used as guard by archive_completed_milestone
- **archive_completed_milestone** (lib/milestone_archival.sh line 110) — existing function that needs modification to remove [DONE] line entirely instead of replacing block with summary
- **mark_milestone_done** (lib/milestone_ops.sh) — NEW function to add, prepends [DONE] to milestone heading idempotently
- **_extract_milestone_block** (lib/milestone_archival.sh line 20) — helper that extracts full milestone blocks, will continue to work unchanged
- **_get_initiative_name** (lib/milestone_archival.sh line 69) — helper that finds initiative context for archival timestamp, will continue to work unchanged
- **parse_milestones** (lib/milestones.sh line 19) — existing function that already handles [DONE] prefixes in milestone headings, no changes needed

## Suspected Root Cause Areas

- **archive_completed_milestone() AWK logic** (lib/milestone_archival.sh lines 157-184) — currently replaces the full milestone block with a one-liner summary line, then prints everything else. To remove the [DONE] line entirely, the AWK must skip printing the summary line and just skip the block lines without replacement.

- **CLAUDE.md [DONE] accumulation** — 26 one-liner [DONE] entries now exist as clutter. The one-time migration reads these lines with `grep ^#### \[DONE\] Milestone` and removes them using `sed` or similar line-removal logic.

- **mark_milestone_done() regex matching** — must handle milestone numbers with dots (e.g., 13.2.1.1) safely, using the same dot-escaping pattern as `is_milestone_done()` (line 137: `num_pattern="${num//./\\.}"`) so the regex does not interpret dots as wildcards.

## Complexity Estimate

Files to modify: 3
Estimated lines of change: 120
Interconnected systems: medium
Recommended coder turns: 35
Recommended reviewer turns: 8
Recommended tester turns: 20

### Estimation Rationale

**Files:** 3 library files (`milestone_ops.sh`, `milestone_archival.sh`, `milestones.sh` — read-only check) plus one-time manual migration of CLAUDE.md.

**Lines of change:**
- `mark_milestone_done()` new function: ~40 lines (reads CLAUDE.md, finds milestone heading, adds [DONE] prefix, idempotent check, regex safety for dotted milestone numbers)
- `archive_completed_milestone()` AWK modification: ~20 lines (change replacement logic from `print summary` to skip entirely, clean up blank lines)
- CLAUDE.md one-time migration: ~30 lines removed (26 [DONE] one-liner lines + optional comment addition for archival note)
- Edge case handling and testing setup: ~30 lines (dotted milestone numbers, blank line collapsing, error cases)

**Interconnected systems: medium** — Three library files are involved, but each function is relatively self-contained. The main coupling is:
- `mark_milestone_done()` uses regex logic from `is_milestone_done()`
- `archive_completed_milestone()` calls `is_milestone_done()` as a guard (no change to this relationship)
- Both read/write CLAUDE.md structure, so the regex patterns must stay in sync

**Recommended turns:**
- Coder: 35 — Function implementation is straightforward but requires careful regex handling for dotted milestone numbers, AWK modification for archive logic, and careful sed/awk for one-time CLAUDE.md migration. Multiple test cases for edge cases (milestone 0.5, 13.2.1.1, already [DONE], not found).
- Reviewer: 8 — Check idempotency of `mark_milestone_done()`, verify AWK change correctly skips [DONE] lines without leaving blank line artifacts, spot-check the one-time migration removed all 26 [DONE] entries from CLAUDE.md without damaging surrounding content.
- Tester: 20 — Test `mark_milestone_done(15)` marks a non-done milestone, test it's idempotent on re-run, test `mark_milestone_done()` with dotted numbers (15.1, 15.1.2, 15.2.1.1), test error case (non-existent milestone), test `archive_completed_milestone()` removes [DONE] line and archives block to MILESTONE_ARCHIVE.md, test archival preserves heading and removes blank lines cleanly, verify CLAUDE.md has zero [DONE] lines post-migration, verify MILESTONE_ARCHIVE.md is unmodified.
