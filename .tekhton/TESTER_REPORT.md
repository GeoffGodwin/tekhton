## Planned Tests
- [x] `cmd/tekhton/run_test.go` — TestRunCommandHasProviderFlags: verify --provider, --provider-chain, --require-tier flags are defined on `tekhton run`
- [x] `cmd/tekhton/run_test.go` — TestProviderFlagEnvOverride: verify --provider and --provider-chain flags set PROVIDER env before per-stage resolution
- [x] `internal/runner/provider_select_test.go` — verify coder-created tests pass (ResolveProvider happy paths, stage override, chain, require-tier wiring)

## Test Run Results
Passed: 26  Failed: 0

Pre-existing unrelated failure: TestBuildNotesContext_FiltersByTask in internal/stages/intake (pre-dates m15, noted in prior tester report).

## Bugs Found
None

## Files Modified
- [x] `cmd/tekhton/run_test.go`
- [x] `internal/runner/provider_select_test.go`

## Timing
- Test executions: 4
- Approximate total test execution time: 55s
- Test files written: 1
