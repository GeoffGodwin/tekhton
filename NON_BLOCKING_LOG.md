# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-17 | "Implement Milestone 10: Milestone Commit Signatures And Completion Signaling"] `--milestone` without `--auto-advance` never populates `_CURRENT_MILESTONE` (the milestone number parse at line 676 is gated inside `if [ "$AUTO_ADVANCE" = true ]`). So plain `--milestone "Implement Milestone 5: X"` runs produce no commit signatures. This is likely intentional — `write_milestone_disposition()` is only called from the auto-advance flow so the disposition would always be "NONE" → partial anyway — but it means the feature is silently absent for the common single-run milestone workflow. Worth a comment in the code or a future task to also wire it up for `--milestone` mode.
- [ ] [2026-03-17 | "Implement Milestone 10: Milestone Commit Signatures And Completion Signaling"] `milestones.sh` is now 567 lines (pre-existing violation; this milestone added ~55 lines). No action required on this PR but the file is a candidate for splitting at a later cleanup sweep.
- [ ] [2026-03-17 | "Implement Milestone 10: Milestone Commit Signatures And Completion Signaling"] `tag_milestone_complete` test only covers the `MILESTONE_TAG_ON_COMPLETE=false` path because the test temp directory is not a git repo. The `=true` path is untested. Acceptable given the setup cost, but a coverage gap worth noting.

