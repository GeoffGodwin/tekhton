# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Added "Negative Space" to the required sections list in `draft_milestones_validate_output()` so the validation function enforces M86's new section requirement
- Updated test fixtures in `test_draft_milestones_validate.sh` to include `## Negative Space` sections in well-formed and partial milestone fixtures
- Updated test 7's expected error threshold from 4 to 5 to account for the new required section

All prompt-level changes (Impact Surface Scan, Negative Space template, behavioral acceptance criteria guidance, prompt template audit rule) were already present in `prompts/draft_milestones.prompt.md`. The linter in `lib/milestone_acceptance_lint.sh` already checks behavioral, refactor-completeness, and config self-referential criteria.

The only gap was that the validation function in `draft_milestones_write.sh` did not enforce "Negative Space" as a required section — a generated milestone could omit it and still pass validation. This is now fixed.

## Root Cause (bugs only)
N/A — enhancement milestone

## Files Modified
- `lib/draft_milestones_write.sh` — added "Negative Space" to required sections in `draft_milestones_validate_output()`
- `tests/test_draft_milestones_validate.sh` — updated test fixtures with `## Negative Space` section; raised error count threshold in test 7

## Human Notes Status
No human notes to address.

## Docs Updated
None — no public-surface changes in this task.
