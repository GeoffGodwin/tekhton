# Coder Summary

## Status: COMPLETE

## What Was Implemented

The polish note requested adding the immediate working-directory name to the
TUI top status bar, transforming `fix-nb  ·  Pass 1/5` into
`fix-nb  ·  Pass 1/5  ·  /name-of-folder`.

After reading the Scout Report and verifying against the current tree, the
feature is already present in HEAD (commit `2ae58a9`). No code changes were
needed — verification only:

- `lib/tui_helpers.sh:221-224` reads `PROJECT_DIR`, takes `basename`, and
  emits it as `project_dir` in the JSON status object at line 258.
- `tools/tui_render.py:180,196-197` consumes `project_dir` from the status
  dict and appends `  ·  /<project_dir>` to the meta line, immediately after
  `Pass {attempt}/{max_attempts}` and before the optional `cli_flags`
  segment, matching the form the human note requested.
- `tools/tests/test_tui.py` has three regression tests for this behavior:
  `test_build_context_renders_project_dir_when_set`,
  `test_build_context_omits_project_dir_when_empty`, and
  `test_build_context_omits_project_dir_when_absent`. All three pass under
  `pytest tools/tests/test_tui.py -k project_dir`.

The feature was bundled into commit `2ae58a9` alongside the ANSI escape
sequence bug fix.

## Root Cause (bugs only)

N/A — this is a polish task, not a bug.

## Files Modified

None. The feature is already implemented in HEAD.

## Docs Updated

None — no public-surface changes in this task.

## Human Notes Status

- COMPLETED: [POLISH] The top status bar of Tekhton currently lists the mode (milestone, nb, drift), the pass number (1/5) and the Task. What it doesn't show is the current directory it's working in (project). Let's add the immediate directory name it's being run from next to the Pass count so that we go from the form "fix-nb  ·  Pass 1/5" to the form "fix-nb  ·  Pass 1/5  ·  /name-of-folder"

## Files Modified (auto-detected)
- `.tekhton/CODER_SUMMARY.md`
- `.tekhton/HUMAN_NOTES.md`
- `.tekhton/REVIEWER_REPORT.md`
- `.tekhton/TESTER_REPORT.md`
- `.tekhton/test_dedup.fingerprint`
