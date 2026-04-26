# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-26 | "m126"] `ARCHITECTURE.md` now describes `lib/gates_ui_helpers.sh` (the new file) but still has no catalog entry for `lib/gates_ui.sh` itself. The M126 addition partially fills the gap but leaves the main file undocumented; `lib/gates_phases.sh` has an entry, so `gates_ui.sh` is the odd one out. Low-priority gap to close in a future cleanup pass.
- [x] [2026-04-26 | "m126"] `CLAUDE.md` repository layout section does not include `lib/gates_ui_helpers.sh`. The same gap exists for `lib/gates_ui.sh` and `lib/gates_phases.sh`, so this is pre-existing and M126 didn't widen it, but a batch update would be worth doing once the V4 milestone reset happens (per CLAUDE.md).
- [ ] [2026-04-25 | "[POLISH] In the TUI when wrap-up gets to running final static analyzer the text is so long it pushes all of the timings off the side of the screen in the Stage Timings column. We should either make it ellipsis sooner or make it wrap lines for long lines like that."] `tools/tui_render_timings.py:64` — column config comment still describes overflow/wrap as the mechanism that "keeps the time/turns columns from being pushed off-screen"; that was the old (non-working) approach. Truncation is now the primary fix; the `no_wrap=False` wrap setting is the backstop. Comment should be updated to reflect the actual fix.

## Resolved
