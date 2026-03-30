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
  - **Fixed:** Changed line 146 from gawk 3-arg `match($0, /Entry ([0-9]+)/, a)` to POSIX-compatible `match($0, /Entry [0-9]+/)` with `substr(RSTART, RLENGTH)` extraction
  - **Verified:** Test passes with mawk, gawk, and POSIX awk
  - **Scope:** Bug was in test only, not in lib/drift_prune.sh
  - **Result:** All 219 shell tests pass, all 76 Python tests pass
