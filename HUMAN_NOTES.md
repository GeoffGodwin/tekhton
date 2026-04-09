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




- [x] [BUG] Planning markdown generation still trusts raw model stdout too literally. In `--plan`, `run_plan_generate()` and the DESIGN synthesis paths only rescue the “tool wrote the file and stdout was just a summary” case; they do not handle mixed output where Claude emits one preamble/thinking sentence and then a valid markdown document. That is why `CLAUDE.md` can occasionally start with a line like “I have enough context...” even though the rest of the file is correct. Fix holistically: add one shared helper for planning/synthesis document generation that trims any leading non-document lines before the first expected top-level heading (`^# ` for DESIGN.md/CLAUDE.md), use it in plan interview/followup/generate and init synthesis, and strengthen `plan_generate.prompt.md` to explicitly say “No preamble, no explanation, no commentary; start directly with the title.”


## Polish
