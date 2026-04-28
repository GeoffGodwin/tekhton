## Planned Tests
- [x] `tests/test_migrate_032_completeness.sh` — all 13 arc vars, plan-deviation values, chain, VERSION, MANIFEST.cfg

## Test Run Results
Passed: 25  Failed: 0

New test file: 25 passed, 0 failed.
Existing `tests/test_migrate_032.sh`: 18 passed, 0 failed (unchanged).
Full suite: 470 shell test files picked up by glob (up from 469 pre-task);
20 pre-existing failures unrelated to M137 (test_migration.sh rollback,
test_tui_stop_orphan_recovery.sh hang, and 18 others already failing on main).

## Bugs Found
None

## Files Modified
- [x] `tests/test_migrate_032_completeness.sh`
