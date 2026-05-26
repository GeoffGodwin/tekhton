## Summary
This change adds a single Go test function (`TestBuildRunner_EnvBuilderWired`) to `cmd/tekhton/run_test.go`. The test verifies that the m26 env-contract smoke test is wired correctly — asserting non-nil `EnvBuilder` fields on the `Runner` and `BashHookRunner` after `buildRunner` returns. No production code was modified. All filesystem paths use `t.TempDir()` (OS-managed, isolated), no credentials or secrets appear anywhere in the diff, and no shell commands, network calls, or user-controlled input are introduced.

## Findings
None

## Verdict
CLEAN
