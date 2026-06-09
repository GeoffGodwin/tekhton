## Planned Tests
- [x] `internal/provider/codex/codex_extra_test.go` — happy-path New(), RunAgent process-level error, RunAgent non-zero exit, provider-internal key filtering

## Test Run Results
Passed: 22  Failed: 1

## Bugs Found
- BUG: [internal/provider/codex/codex.go:68] condition `runErr != nil && exitCode == 0` is unreachable — runCodex returns exitCode=-1 (never 0) for process-level errors, so RunAgent silently returns a Result{OutcomeUnknown, ExitCode:-1} instead of an error when the binary is missing or fails to launch

## Files Modified
- [x] `internal/provider/codex/codex_extra_test.go`

## Timing
- Test executions: 3
- Approximate total test execution time: 2s
- Test files written: 1
