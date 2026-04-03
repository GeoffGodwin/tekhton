# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-03 | "M52"] `lib/gates.sh` remains at 477 lines (pre-existing; already logged in prior cycle). No action required this cycle.
- [ ] [2026-04-02 | "M53"] `lib/error_patterns.sh` is 337 lines, exceeds the 300-line soft ceiling. The registry heredoc accounts for the bulk; consider splitting the registry data from the classification engine if it grows further.
- [ ] [2026-04-02 | "M53"] `lib/errors.sh` is 304 lines, marginally over the ceiling — acceptable but worth noting for future cleanup.

## Resolved
