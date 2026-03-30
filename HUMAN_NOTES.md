# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features

## Bugs
- [x] [BUG] Watchtower Trends page: Recent Runs section does not show the latest two --human runs, it only shows the last --milestone run. This is critical for users to verify that their latest runs are being tracked and to see their most recent performance data. It also only ever shows the most recent run, with a count of 1 instead of all of them.
- [x] [BUG] Watchtower: Auto-refresh applies to all pages instead of only Reports and Live Run, causing unnecessary reloads elsewhere
- [ ] [BUG] Watchtower Trends page: Average stage times are incorrect. Tester shows 3:38 avg despite no run under 5 min; an 11-min run decreased the average to 3:21 instead of increasing it. The average run time shows as 8m50s when in actual fact most runs are well over 20 minutes, some reaching over an hour. This is critical for users to have an accurate expectation of how long runs will take and to see the impact of their optimizations.
