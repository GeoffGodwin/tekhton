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
- [x] [BUG] test_drift_prune_realistic.sh: awk syntax error during drift log pruning. The prune_resolved_entries function triggers `awk: line 1: syntax error at or near ,` — likely a platform-specific awk compatibility issue (gawk vs mawk).
  - **Fixed:** Changed line 146 from gawk 3-arg `match($0, /Entry ([0-9]+)/, a)` to POSIX-compatible `match($0, /Entry [0-9]+/)` with `substr(RSTART, RLENGTH)` extraction
  - **Verified:** Test passes with mawk, gawk, and POSIX awk
  - **Scope:** Bug was in test only, not in lib/drift_prune.sh
  - **Result:** All 219 shell tests pass, all 76 Python tests pass
- [x] [BUG] test_nonblocking_log_fixes.sh: Test expects `.claude/dashboard/app.js` to exist but it doesn't. The "trendArrow ordering assumption not documented" check greps a missing file. Either the dashboard build step isn't generating app.js or the test path is stale.
- [x] [BUG] test_plan_browser.sh: Two failures — (1) port-finding logic doesn't skip an occupied port in this test environment, and (2) HTML escaping produces double-encoded entities (`<lt;` instead of `&lt;`). The escaping function is likely applying encoding twice.
