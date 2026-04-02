# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-01 | "M51"] `docs/guides/tdd-mode.md` — Configuration section lists `TDD_PREFLIGHT_FILE` and `CODER_TDD_TURN_MULTIPLIER` but omits `TESTER_WRITE_FAILING_MAX_TURNS` (present in `config_defaults.sh:291`). Not wrong, just incomplete for a user trying to tune the preflight tester's turn budget.
(none)

## Resolved
