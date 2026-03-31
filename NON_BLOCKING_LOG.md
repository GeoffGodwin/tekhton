# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-30 | "M41"] `lib/notes_triage.sh` is 589 lines — nearly 2x the 300-line soft ceiling. The file is logically partitioned (heuristics, agent escalation, promotion flow, pipeline integration, report) and could be split into `notes_triage_core.sh` + `notes_triage_flow.sh`.
- [ ] [2026-03-30 | "M41"] `lib/notes_triage.sh:170` — `$(date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)` falls back to the identical command. The fallback is a no-op; if the intent is a timezone-safe fallback, the two calls should differ.
- [ ] [2026-03-30 | "M41"] `lib/notes_triage.sh:226-229` — Template variables (`TRIAGE_NOTE_TEXT`, `TRIAGE_NOTE_TAG`, etc.) are exported into the environment and never unset after agent escalation. Consistent with the pipeline's existing pattern, but worth noting for future cleanup.

## Resolved
