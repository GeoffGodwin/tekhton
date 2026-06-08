## Planned Tests
- [x] `cmd/tekhton/run_test.go` — TestReadGitHead_ParsesHashAndSubject: directly tests readGitHead hash length (40) and full multi-word subject capture via SplitN
- [x] `cmd/tekhton/run_test.go` — TestReadGitHead_ReturnsErrorNotGitRepo: verifies readGitHead propagates error on a plain temp dir (not a git repo)
- [x] `cmd/tekhton/run_test.go` — TestEmitAutoAdvanceCommitBanner_HeadReadFails: covers the third banner branch ("HEAD read failed") when projectDir is not a git repo
- [x] `cmd/tekhton/run_test.go` — TestClearAutoAdvanceIterationState_PartialSentinels: verifies robustness when only some sentinel files are present — present ones removed, missing one causes no error

## Test Run Results
Passed: 494 shell + all Go packages  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `cmd/tekhton/run_test.go`

## Timing
- Test executions: 3
- Approximate total test execution time: 7s
- Test files written: 1

---

## Test Audit Report

### Audit Summary
Tests audited: 1 file (`cmd/tekhton/run_test.go`), 15 test functions
Verdict: PASS

### Findings

#### ISOLATION: TestBuildRunner_EnvBuilderWired leaks temp dir
- File: cmd/tekhton/run_test.go:187
- Issue: `buildRunner` calls `buildEnvBuilder`, which calls `os.MkdirTemp("", "tekhton_session_")` (run.go:456). That temp dir is never removed — the returned `cleanup` func only stops the TUI sidecar. Each test run leaves a `tekhton_session_*` directory under `/tmp`. Does not affect test isolation or correctness, but accumulates stale directories across test runs.
- Severity: LOW
- Action: Add `defer os.RemoveAll(sessionDir)` in `buildEnvBuilder`, or register the removal in the `cleanup` closure returned by `buildRunner`. No test-side change needed.

#### No other findings
- **Assertion Honesty**: All assertions are derived from real function calls. Banner substrings (`"✓ m38.5 committed as"`, `"finalize skipped commit"`) are literal fragments of `fmt.Fprintf` calls in `emitAutoAdvanceCommitBanner` (run.go:743–750). Hash-length assertion (==40) matches the `%H` git format specifier contract.
- **Edge Case Coverage**: Partial-sentinels, missing `.tekhton/` dir, empty `projectDir`, non-git-repo, HEAD-read-failure, milestone-prefix-mismatch, and skip-banner paths are all covered alongside the happy paths.
- **Implementation Exercise**: Every test calls the real function under test. No function is over-mocked or bypassed.
- **Test Weakening**: No pre-existing test assertions were broadened or removed. Only new tests were added.
- **Naming**: All 15 functions follow the `TestFuncName_ScenarioAndOutcome` pattern, encoding both the input condition and expected result.
- **Scope Alignment**: All referenced symbols exist in `cmd/tekhton/run.go`. `proto.RunRequestV1.Validate()` confirmed to contain the `autoAdvance && mode != RunModeMilestone` guard that `TestBuildRunRequestAutoAdvanceWithoutMilestone` exercises (internal/proto, lines 160–162).
- **Test Isolation**: All tests use `t.TempDir()`. No test reads live pipeline logs, run artifacts, or project state files.
