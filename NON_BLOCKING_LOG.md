# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-05 | "M59"] `lib/specialists.sh` is now 365 lines, over the 300-line soft ceiling. The new UI specialist block (auto-enable logic, `ui)` diff relevance case, `UI_FINDINGS_BLOCK` export) is ~25 lines. Consider extracting `_specialist_diff_relevant()` or the UI block to a helper module at the next cleanup pass.

## Resolved
