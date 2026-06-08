## Planned Tests
- [ ] `cmd/tekhton/run_test.go` — TestReadGitHead_ParsesHashAndSubject: directly tests readGitHead hash length (40) and full multi-word subject capture via SplitN
- [ ] `cmd/tekhton/run_test.go` — TestReadGitHead_ReturnsErrorNotGitRepo: verifies readGitHead propagates error on a plain temp dir (not a git repo)
- [ ] `cmd/tekhton/run_test.go` — TestEmitAutoAdvanceCommitBanner_HeadReadFails: covers the third banner branch ("HEAD read failed") when projectDir is not a git repo
- [ ] `cmd/tekhton/run_test.go` — TestClearAutoAdvanceIterationState_PartialSentinels: verifies robustness when only some sentinel files are present — present ones removed, missing one causes no error

## Test Run Results
Passed: 0  Failed: 0

## Bugs Found
None

## Files Modified
- [ ] `cmd/tekhton/run_test.go`
