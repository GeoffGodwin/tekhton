## Planned Tests
- [x] Fix `tests/test_migration.sh` — $? assertions after set -euo pipefail (tests 4.2, 5.2, 8.1, 12.1, 13.1)
- [x] Fix `tests/test_migration.sh` — weak string match in test 11.3 (assert more specific content)
- [x] Fix `tests/test_dry_run.sh` — test 13 always passes with runtime variable in label
- [x] Add confidence value assertions in `tests/test_dry_run.sh` _parse_intake_preview tests
- [x] Add test coverage for `rollback_migration()` function in `tests/test_migration.sh` (tests 14-15)
- [x] Add test coverage for `check_project_version()` function in `tests/test_migration.sh` (tests 16-17)
- [x] Add test coverage for `offer_cached_dry_run()` function in `tests/test_dry_run.sh` (tests 23-26)
- [x] Add edge case test for `_write_config_version` when `pipeline.conf` absent (test 18)
- [x] Add test for mid-chain failure behavior in `run_migrations` (test 19)

## Test Run Results
Passed: 170  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_migration.sh` — Fixed Suite 14 to properly capture exit code using set +e/set -e
- [x] `tests/test_dry_run.sh` — Fixed tests 24-26 to wrap interactive function calls in subshells with set +e
