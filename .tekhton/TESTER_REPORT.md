## Planned Tests
- [x] `internal/runner/hooks_test.go` — m04 env-contract: BashHookRunner.Finalize with EnvBuilder sends MILESTONE_MODE=true and _CURRENT_MILESTONE=<id> to bash shim subprocess
- [x] `tests/test_autoadvance_milestone_prefix.sh` — m04 shim-boundary: auto-advance loop wires milestone env contract through to bash hook subprocess

## Test Run Results
Passed: 7  Failed: 0

## Bugs Found
- BUG: [internal/stages/intake/context_test.go:134] TestBuildNotesContext_FiltersByTask fails — buildNotesContext returns empty string instead of filtering notes by task relevance (pre-existing, not introduced by m04)

## Files Modified
- [x] `internal/runner/hooks_test.go`
- [x] `tests/test_autoadvance_milestone_prefix.sh`

## Timing
- Test executions: 4
- Approximate total test execution time: 42s
- Test files written: 2
