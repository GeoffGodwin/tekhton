# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-07 | "M65"] `stages/tester.sh` is 323 lines — 23 over the 300-line soft ceiling. Carried from prior cycles; the M65 extraction reduced it from ~406 to 323. Further extraction would close the gap. Log for next cleanup pass.
- [ ] [2026-04-07 | "M65"] `stages/tester_fix.sh` is sourced twice: once inside `tester.sh` (line 322-323) and once in `tekhton.sh` (line 815). Double-sourcing is idempotent and harmless, but the sourcing convention across the tester sub-stage family is inconsistent. Log for a cleanup pass.
- [ ] [2026-04-07 | "M65"] `stages/tester.sh` is 323 lines — 23 over the 300-line ceiling. The M65 extraction reduced it from ~406 to 323 but did not reach the target. Further extraction (e.g. the post-tester validation block ~lines 205–294) would close the gap. Log for next cleanup pass.
- [ ] [2026-04-07 | "M65"] `stages/tester_fix.sh` is now double-sourced: once inside `tester.sh:322` and once in `tekhton.sh` (the new line). This matches the pre-existing double-source pattern for `tester_tdd.sh` but is architecturally inconsistent — `tester_timing.sh` is sourced only from `tester.sh`, `tester_continuation.sh` only from `tekhton.sh`. No correctness impact, but the pattern warrants a cleanup pass to decide on the canonical sourcing strategy.
- [ ] [2026-04-07 | "M64"] `stages/tester_fix.sh` is sourced twice: once at the end of `tester.sh` (line 398) and once explicitly in `tekhton.sh` (line 815). Double-sourcing is harmless (functions are redefined to the same definition) but the `tekhton.sh` entry is redundant and could be removed.

## Resolved
