# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/milestones.sh:590` — In `_extract_milestone_block`, the bash regex `${num}[[:space:]]*[:.\—\-]` interpolates `num` directly into the pattern. For milestone `0.5`, the `.` is a regex metacharacter (matches any character), so the pattern would technically match `0X5:` in addition to `0.5:`. Harmless in practice since no such heading exists, but should be escaped: `${num//./\\.}` to be correct.
- `lib/milestones.sh:727` — Same issue in the awk dynamic regex: `"[Mm]ilestone[[:space:]]+" num "[[:space:]]*[:.—-]"` — the `num` variable `0.5` is concatenated into the regex unescaped. Use `gsub(/\./, "\\.", num)` in awk to escape the dot before concatenation.
- `lib/config.sh:215` — `MILESTONE_ARCHIVE_FILE` is not resolved to an absolute path the way `PIPELINE_STATE_FILE` and `LOG_DIR` are (via the `[[ != /* ]]` block at the end of `load_config()`). All other state files use this pattern. Add: `[[ "$MILESTONE_ARCHIVE_FILE" != /* ]] && MILESTONE_ARCHIVE_FILE="${PROJECT_DIR}/${MILESTONE_ARCHIVE_FILE}"` to the path-resolution block.
- `lib/milestones.sh` — File is now 792 lines, well over the 300-line guideline. This was pre-existing before this run (~622 lines before), but the archival functions add another ~170 lines. Candidate for extraction into `lib/milestone_archive.sh` in a future refactor.
- No unit tests were added for the five new archival functions (`_extract_milestone_block`, `_get_initiative_name`, `_milestone_in_archive`, `archive_completed_milestone`, `archive_all_completed_milestones`). These are non-trivially complex — particularly the awk block-extraction logic. Good coverage targets for a follow-up.

## Coverage Gaps
- No tests for archival functions — idempotency, initiative name detection, and the awk-based CLAUDE.md replacement are all untested. Recommend adding `tests/test_milestone_archival.sh` covering: (1) archive a [DONE] milestone and verify CLAUDE.md shrinks, (2) run archive again (idempotency), (3) archive with decimal milestone number (0.5), (4) `_get_initiative_name` for milestones in both `Completed` and `Current` initiative sections.

## ACP Verdicts
None.

## Drift Observations
- `lib/milestones.sh` — The file now contains three distinct areas of responsibility: (1) milestone state machine, (2) auto-advance orchestration, (3) archival. The 300-line limit exists to prevent exactly this multi-concern growth. Flagging for eventual split.
- `tekhton.sh:1073` — The commit-skip path echoes `${COMMIT_MSG%%$'\n'*}` (first line of commit msg) for the manual git command. When a milestone prefix like `[MILESTONE 10 ✓]` is present, this is fine. But the `%%` strip on a multi-line string may behave differently across bash versions — worth watching if users report truncated suggestions.
