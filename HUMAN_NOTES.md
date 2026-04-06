# Human Notes
<!-- notes-format: v2 -->
<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features

## Bugs
- [ ] [BUG] The Milestone Map is no longer showing the currently active milestone in the Active column. It remains in the READY column and then jumps to DONE when completed, without ever showing as ACTIVE.

## Polish
- [ ] [POLISH] The Run Summary print out in Tekhton should also reflect which model was used at that stage. For instance if the Coder was using sonnet-4-6 or opus-4-6, that should be printed in the summary for that stage. This is important for debugging and understanding performance differences between models.