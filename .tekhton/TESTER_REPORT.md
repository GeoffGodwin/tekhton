## Planned Tests
- [x] `internal/runner/env_test.go` — taskSlug unit tests, AsKV SessionDir/AutoAdvanceLimit, HumanMode and MilestoneMode flag derivation
- [x] `internal/proto/stage_env_test.go` — StageEnvV1.SessionDir round-trip coverage
- [x] `tests/run_tests.sh` — resolve merge conflicts so bash suite executes
- [x] `tests/test_v4_env_contract.sh` — verify env contract bash test passes (deferred e2e noted)

Note: `tests/test_v4_pipeline_e2e.sh` (full fixture pipeline-completion test) is deferred to m28+ per reviewer approval — requires `--dry-run` to actually short-circuit agent invocation, which `cmd/tekhton/run.go:83-89` accepts but does not dispatch.

## Test Run Results
Passed: 22 Go packages (all green) + 3 bash (env contract)  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/runner/env_test.go`
- [x] `internal/proto/stage_env_test.go`
- [x] `tests/run_tests.sh`
