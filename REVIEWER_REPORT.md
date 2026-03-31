# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/notes_triage.sh` appears in git status as a working-tree modification but is not listed in CODER_SUMMARY.md's "Files Modified" section. The diff shows a single-line shellcheck fix (`echo` → `printf '%s '` for the scale-indicator grep). Likely pre-existing uncommitted work from M42 development, not introduced by this task — but it should be documented or committed separately to keep the working tree clean.
- Tests 8.1, 8.2, and 8.4 in `test_finalize_run.sh` now trivially pass: they assert that `resolve_human_notes` mock is NOT called, but `resolve_human_notes` is never called anywhere in the new code. The assertions are no longer testing a real guard — they pass vacuously. This is harmless but reduces signal. Consider updating 8.1/8.2 to verify the failure/no-file early-return path, and removing 8.4 (the "no [~] items" case needs no mock check now that the function is never invoked).
- Test case comment at line 763 in `test_human_workflow.sh` says "_hook_resolve_notes in non-HUMAN_MODE calls bulk resolution" — this is misleading. The test no longer verifies that `resolve_human_notes` is called (because it isn't). It verifies the outcome (`[x]` in file), which is correct. The comment should be updated to reflect the orphan safety net mechanism.

## Coverage Gaps
- No test in `test_finalize_run.sh` covers the failure path of the orphan safety net (`[~]` → `[ ]` on exit_code=1). That path is covered by `test_human_mode_resolve_notes_edge.sh` Phase 2, but a symmetrical test alongside 8.3 (e.g., "8.3b orphaned [~] reset to [ ] on failure") would complete Suite 8's coverage and make the invariant explicit in the primary finalize test file.

## Drift Observations
- `tests/test_finalize_run.sh:415–418` — The comment "On failure: resolve_human_notes should NOT be called" describes a constraint that is no longer meaningful (the function is simply absent from the code path). This comment was valid documentation pre-M42 but is now misleading. Minor cleanup opportunity.
