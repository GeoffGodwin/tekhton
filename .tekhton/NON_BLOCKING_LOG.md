# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-16 | "M90"] `tekhton.sh` line 38 top-of-file usage comment still reads `--auto-advance` (no `[N]`); both `--help` blocks were updated correctly but the source comment was missed.
- [ ] [2026-04-16 | "M89"] The three new config keys (`TEST_AUDIT_ROLLING_ENABLED`, `TEST_AUDIT_ROLLING_SAMPLE_K`, `TEST_AUDIT_HISTORY_MAX_RECORDS`) are not documented in the Template Variables table in `CLAUDE.md`. Other `TEST_AUDIT_*` keys are also absent from that table, so this continues an existing gap rather than introducing a new regression. Worth a future pass to add all `TEST_AUDIT_*` keys.

## Resolved
