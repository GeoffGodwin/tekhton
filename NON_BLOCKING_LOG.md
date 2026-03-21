# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-21 | "Resolve all observations in DRIFT_LOG.md. For each unresolved item, apply the fix, then mark it resolved. Continue until no unresolved observations remain."] `rescan_helpers.sh:119` — `printed = 1` is set in the awk script but never read. Dead variable; harmless but could be removed.
- [ ] [2026-03-21 | "Resolve all observations in DRIFT_LOG.md. For each unresolved item, apply the fix, then mark it resolved. Continue until no unresolved observations remain."] `rescan_helpers.sh:117` — `echo "$content"` pipes into awk. `printf '%s ' "$content"` would be more robust for content with leading dashes, but content is markdown so this is unlikely to cause issues in practice.

## Resolved
