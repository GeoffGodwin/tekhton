# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features
- [ ] [FEAT] We need a configurable usage threshold where we can set Tekhton to not start its next run if the current session usage (claude /usage) passes that threshold. That way if I set it to 90% per 5 hour window it will pause before running the next run when it hits 90% of my session usage.
- [ ] [FEAT] Currently trhe final commit message is incredible light on details. It would be nice if it included a summary of the changes made, maybe a list of files changed, and perhaps even a brief explanation of why the changes were made (if that can be inferred from the coder's notes or the commit diff). This would make it easier to understand the context of the changes when looking at the commit history later on. It should also auto-commit to the working branch it's on instead of waiting for human input. This wait causes the work to halt which could otherwise continue on to later milestones or tasks.

## Bugs
None currently.

## Polish
None currently.