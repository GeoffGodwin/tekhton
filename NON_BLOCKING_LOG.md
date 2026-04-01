# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-31 | "M42"] `lib/notes_triage_flow.sh` — 328 lines (28 lines over ceiling); log for next cleanup pass
- [ ] [2026-03-31 | "M42"] `lib/notes_acceptance.sh` — 308 lines (8 lines over ceiling); log for next cleanup pass
- [ ] [2026-03-31 | "M42"] `lib/notes_acceptance.sh:279` — second while loop has `local _msg` inside; not SC2155 but inconsistent with hoisting in first loop

## Resolved
