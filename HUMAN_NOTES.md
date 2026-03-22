# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features
- [ ] [FEAT] Test lifecycle management: Add a mechanism to detect stale or invalidated tests. Tests that assert against CLAUDE.md content (or other evolving artifacts) break silently when new milestones modify those files. Options: (a) tag tests with the milestone that created them and auto-skip when the milestone is archived, (b) add a `tests/MANIFEST` that maps test files to the invariants they guard, (c) run a pre-flight test triage in the build gate that classifies failures as "stale test" vs "real regression". The `test_milestone_15_2_2_2_migration.sh` failure that burned 5 pipeline attempts is the motivating case.

## Bugs
None currently.

## Polish
None currently.