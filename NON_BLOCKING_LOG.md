# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-02 | "Resolve all 2 unresolved architectural drift observations in DRIFT_LOG.md."] `lib/dashboard_parsers_runs.sh` is 315 lines, 5% over the 300-line ceiling. The split brought `dashboard_parsers.sh` from 465 to 166 lines (resolving the drift observation), but the new companion file is marginally over the soft limit. Candidate for a follow-up split at `_parse_run_summaries_from_files` when next touched.
- [ ] [2026-04-02 | "Resolve all 2 unresolved architectural drift observations in DRIFT_LOG.md."] `SECURITY_NOTES.md` retains stale line-number references (`:362`, `:448`, `:35`) that no longer correspond to the refactored layout — those functions now live in `dashboard_parsers_runs.sh`. The fixes are correctly applied; only the reference coordinates are stale.
(none)

## Resolved
