# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features
- [ ] [FEAT] The "Intake Report" section of the Reports page only shows the Verfict and Confidence currently - it should also show the original notes for context, and ideally a link to the full notes in the Milestone Map 

## Bugs
- [ ] [BUG] Watchtower Trends page: Recent Runs section does not show the latest two --human runs, it only shows the last --milestone run. This is critical for users to verify that their latest runs are being tracked and to see their most recent performance data.
- [ ] [BUG] Watchtower Trends page: Per-stage breakdown shows unclear arbitrary percentage in Last Run column, Budget Util is redundant, Avg Turns and Last Run are always identical, and Build stage row never populates
- [ ] [BUG] Watchtower Reports page: Test Audit section never displays any information
- [ ] [BUG] Watchtower Actions screen: Auto-refresh wipes all form fields every few seconds, making the screen unusable during a pipeline run. Actions screen has no live run data and should not refresh at all
- [ ] [BUG] Watchtower Actions screen: Cannot add new Parallel Groups, only existing ones are selectable. New projects have only one (or zero) options available
- [ ] [BUG] Watchtower: Live Run page uses minimal screen real estate and should be a persistent banner at the top of every page instead of its own page
- [ ] [BUG] Watchtower: Auto-refresh applies to all pages instead of only Reports and Live Run, causing unnecessary reloads elsewhere
- [ ] [BUG] Watchtower Trends page: Average stage times are incorrect. Tester shows 3:38 avg despite no run under 5 min; an 11-min run decreased the average to 3:21 instead of increasing it