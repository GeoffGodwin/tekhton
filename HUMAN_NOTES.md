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

- [x] [BUG] Reviewer turn limits never increase despite repeated overshoots. Two compounding issues: (1) `lib/metrics_calibration.sh` skips overshoot records from calibration because the `actual >= adjusted * 0.85` guard fires unconditionally when `actual > adjusted` (ratio > 100% always ≥ 85%), so every overshoot is silently excluded — the exact records that should teach calibration to raise limits; fix is to add `actual <= adjusted &&` to the guard so only true cap-hits are skipped. (2) Even within a single run, `ADJUSTED_REVIEWER_TURNS` is computed once before the review loop in `stages/review.sh` and never updated between cycles, so all cycles run with identical limits even after an overshoot; the loop needs to re-evaluate and bump the limit after each overshot cycle.

## Polish
