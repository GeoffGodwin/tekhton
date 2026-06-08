## Planned Tests
- [x] `tests/test_is_path_allowed_manifest.sh` — verify `_is_path_allowed` allows MANIFEST.cfg (bookkeeping glob) and rejects unrelated paths
- [x] `internal/finalize/orchestrator_test.go` — add `writeFinalizeActiveSentinel` direct tests: Timestamp payload, "active" fallback, nil/empty-ProjectDir guards

## Test Run Results
Passed: 11  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_is_path_allowed_manifest.sh`
- [x] `internal/finalize/orchestrator_test.go`

## Timing
- Test executions: 6
- Approximate total test execution time: 45s
- Test files written: 2
