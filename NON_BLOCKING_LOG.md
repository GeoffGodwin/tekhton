# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-31 | "Implement M43 Test-Aware Coding"] `stages/coder.sh` uses `declare -f has_test_baseline` to guard the baseline summary block, while `lib/finalize_summary.sh` and `lib/milestone_acceptance.sh` use `command -v has_test_baseline` for the same guard. Both forms work correctly for shell functions, but the codebase is inconsistent. `declare -f` is slightly more correct (only matches functions, not executables), but this is cosmetic — no behavior difference in practice.
- [ ] [2026-03-31 | "Implement M43 Test-Aware Coding"] `tests/test_m43_test_aware.sh` duplicates the `_extract_affected_test_files` and `_build_test_baseline_summary` logic inline rather than sourcing `stages/coder.sh`. This is consistent with the existing test style in the project (tests avoid sourcing complex stage files to reduce coupling), but means a logic drift between test fixtures and production code won't be caught by the test. Acceptable tradeoff given the test does validate the actual prompt files directly in Suite 3.
- [ ] [2026-03-31 | "M43"] `tests/test_m43_test_aware.sh` duplicates the awk extraction logic and baseline-parsing logic as inline helpers (`_extract_affected_test_files`, `_build_test_baseline_summary`) rather than sourcing them from `stages/coder.sh`. If the logic in `coder.sh` changes, the tests won't catch the regression. Acceptable for now but worth migrating if the extraction logic grows.
(none)

## Resolved
