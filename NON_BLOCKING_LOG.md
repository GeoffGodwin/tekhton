# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-06 | "M63"] `stages/tester.sh:180,344` — `TEST_BASELINE_ENABLED` guard uses `:-false` fallback, but `lib/test_baseline.sh` and `config_defaults.sh` both default it to `true`. No production impact (config_defaults.sh always sets it before stages run), but the fallback is inconsistent and could silently skip baseline summary injection in isolated unit tests.
- [ ] [2026-04-06 | "M63"] `lib/test_baseline.sh` — 388 lines, over the 300-line soft ceiling. New content (~50 lines) pushed it over threshold. Consider extracting `cleanup_stale_baselines` and `get_baseline_exit_code` into a `test_baseline_cleanup.sh` sidecar in a future cleanup pass.
(none)

## Resolved
