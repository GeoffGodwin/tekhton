# Human Notes — tekhton

<!-- notes-format: v2 -->
<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.
Tag with [BUG], [FEAT], or [POLISH] to use --notes-filter.

## Bugs
<!-- - [ ] [BUG] Example: describe a bug -->
- [ ] [BUG] tester loses track of orphan test files after partial runs <!-- note:n01 created:2026-01-10 priority:high source:cli -->
  > Repro: kill the agent mid-tester pass; the next run treats the orphan files as new.
- [~] [BUG] resume marker dropped when finalize crashes <!-- note:n02 created:2026-01-12 priority:medium source:cli -->
- [x] [BUG] dashboard css broken in safari <!-- note:n03 created:2026-01-05 priority:low source:cli -->

## Features
- [ ] [FEAT] --triage --dry-run subflow <!-- note:n04 created:2026-01-15 priority:medium source:cli -->
- [ ] [FEAT] support custom note tags from pipeline.conf <!-- note:n05 created:2026-01-15 priority:medium source:cli -->
  > Currently DEFAULT_NOTE_TAGS hard-codes BUG/FEAT/POLISH; extend the parser to honor extra tags read from config.

## Polish
- [ ] [POLISH] reword the intake summary header <!-- note:n06 created:2026-01-18 priority:low source:cli -->
