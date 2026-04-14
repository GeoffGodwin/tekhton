# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Created `lib/milestone_acceptance_lint.sh` with three lint checks: behavioral criterion detection, refactor completeness grep, config self-referential check
- Integrated linter into `check_milestone_acceptance()` in `lib/milestone_acceptance.sh` — runs as pre-check, logs warnings to NON_BLOCKING_LOG
- Fixed code-block ordering bug in `_lint_extract_criteria()`: moved `## heading` break check after code-block guard so `## headings` inside fenced code blocks no longer prematurely terminate criteria extraction
- Removed erroneous `set -euo pipefail` from sourced library file
- Improved code-block hash test sensitivity: behavioral keyword now appears only after the code block, so the test detects the extraction bug at the lint level (not just the extract level)
- Sourced `milestone_acceptance_lint.sh` in `tekhton.sh` (line 821)
- Updated ARCHITECTURE.md and CLAUDE.md with the new file

## Root Cause (bugs only)
N/A — new feature. The code-block ordering bug was a pre-existing implementation defect where `_lint_extract_criteria` checked for `## heading` section breaks before checking code-block state, causing `## headings` inside fenced code blocks to prematurely end criteria extraction.

## Files Modified
- `lib/milestone_acceptance_lint.sh` (NEW) — acceptance criteria quality linter
- `lib/milestone_acceptance.sh` — integrated linter call before acceptance checks
- `tests/test_milestone_acceptance_lint.sh` (NEW) — comprehensive linter tests (22 assertions)
- `tests/test_milestone_acceptance_lint_codeblockhash.sh` (NEW) — code-block guard test (7 assertions)
- `tekhton.sh` — sources new library file
- `ARCHITECTURE.md` — documents new library
- `CLAUDE.md` — documents new file in repository layout

## Human Notes Status
No human notes for this task.

## Docs Updated
None — no public-surface changes in this task. The linter is internal pipeline infrastructure, not a user-facing CLI or config change.
