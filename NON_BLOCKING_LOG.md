# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in ${REVIEWER_REPORT_FILE}.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-13 | "M79"] `tests/test_readme_split.sh` is not wired into `tests/run_tests.sh`. The milestone spec's implementation plan explicitly says "Add to `tests/run_tests.sh` only if it's fast (< 1s) and doesn't depend on network" — both conditions are met. A one-line addition to run_tests.sh would integrate it into CI.
- [x] [2026-04-13 | "M79"] `tests/test_readme_split.sh` uses `grep -oP` (Perl-compatible regex), a GNU grep extension not available on macOS's BSD grep. The project targets Linux/WSL so this is not a blocker, but worth noting for future portability.
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
