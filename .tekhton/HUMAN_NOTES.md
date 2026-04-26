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
- [ ] [BUG] `HUMAN_ACTION_REQUIRED.md` is being written to the project root instead of `.tekhton/HUMAN_ACTION_REQUIRED.md`. Observed on the SDI repo (`structural-divergence-indexer`) on 2026-04-26: a fresh pipeline run produced `./HUMAN_ACTION_REQUIRED.md` at the repo root, while `.tekhton/HUMAN_ACTION_REQUIRED.md` (the canonical location since the SDI-side M08 rename — and consistent with every other Tekhton artifact like `CODER_SUMMARY.md`, `REVIEWER_REPORT.md`, `NON_BLOCKING_LOG.md` which all live under `.tekhton/`) held only stale items from a prior run. Suspected cause: a hardcoded or default-relative path for this one artifact that wasn't updated when the rest of the artifacts were relocated under `.tekhton/`. Search the pipeline scripts/templates for `HUMAN_ACTION_REQUIRED` and confirm the write target is built off the same base path used by the other report artifacts. Fix should also handle migration: if a root-level `HUMAN_ACTION_REQUIRED.md` exists at run start, merge its items into `.tekhton/HUMAN_ACTION_REQUIRED.md` and delete the root file (rather than overwriting either silently).

## Polish
