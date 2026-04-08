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
- [x] [BUG] When the `tekhton --plan` command gets to the DESIGN.md generation it takes the time to generate the info, generates a bunch of logs, and then when it goes to make the DESIGN.md it just creates a file that says "It looks like write permissions haven't been granted yet. Could you approve the file write permission so I can create the `DESIGN.md` file? The document is complete and ready — it synthesizes all your interview answers into a professional design document covering all 17 sections from the template." instead of writing out the actual design document. It then goes on to the completeness check and states that all sections are missing and require more detail, then goes right back to the start and asks all the questions all over again.


## Polish
