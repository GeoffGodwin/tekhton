## Planned Tests
- [x] `tests/test_commit_subject_fallback.sh` — verify 5-assertion m44 regression test passes (Goal 1 sort-by-lines, Goal 2 milestone-title subject, Goal 3 TASK smoke, AC grep, project_version.cfg exclusion guard)
- [x] fix TMPDIR shadowing in `tests/test_commit_subject_fallback.sh` per Reviewer non-blocking note, re-verify passes

## Test Run Results
Passed: 2  Failed: 0

All 5 assertions in `test_commit_subject_fallback.sh` passed both before and after the TMPDIR rename.
Regression tests `test_state_writer_resume_fields.sh` and `test_finalize_commit_block_reason.sh` pass.
`shellcheck tests/test_commit_subject_fallback.sh lib/hooks.sh lib/orchestrate_save.sh` clean.
Full `go test ./...` suite: all packages pass.

## Bugs Found
None

## Files Modified
- [x] `tests/test_commit_subject_fallback.sh`
