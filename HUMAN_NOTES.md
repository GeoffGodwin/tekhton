# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features
None currently.

## Bugs
- [x] [BUG] Milestone archival re-archives ALL completed milestones on every run instead of skipping already-archived ones — MILESTONE_ARCHIVE.md grows by the full milestone set each invocation; needs an idempotency check (e.g., grep for milestone ID before appending)
- [ ] [BUG] Pipeline exits with "failures detected" when self-tests fail instead of auto-seeding a fix run — should immediately invoke a new tekhton run with the failed test output as the task to fix; pipeline must never end in a non-pristine state when the fix is trivial
