# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-31 | "M43"] `tests/test_m43_test_aware.sh` duplicates the awk extraction logic and baseline-parsing logic as inline helpers (`_extract_affected_test_files`, `_build_test_baseline_summary`) rather than sourcing them from `stages/coder.sh`. If the logic in `coder.sh` changes, the tests won't catch the regression. Acceptable for now but worth migrating if the extraction logic grows.
(none)

## Resolved
