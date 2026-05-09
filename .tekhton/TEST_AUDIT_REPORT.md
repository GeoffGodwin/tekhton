## Test Audit Report

### Audit Summary
Tests audited: 2 files, 4 new test functions
Verdict: PASS

### Findings

#### NAMING: Misleading MAX_TRANSIENT_RETRIES reference in failure message
- File: internal/runner/complete_test.go:210
- Issue: The assertion error message reads "want 1, much less than MAX_TRANSIENT_RETRIES+1=4". MAX_TRANSIENT_RETRIES is the supervisor-level retry budget for Claude CLI agent calls (internal/supervisor/retry.go), an entirely separate path from the stage-subprocess routing exercised by this test. The CODER_SUMMARY explicitly confirmed those are distinct layers. A future developer debugging a regression at this assertion will be sent to the wrong subsystem; the correct upper bound for this path is 1, not 4.
- Severity: LOW
- Action: Replace the message with something like "pipeline invoked %d times; structural FailureSaveExit must not iterate (want 1)" — drop the MAX_TRANSIENT_RETRIES reference entirely.

#### SCOPE: Shell orphan detector false-positives for Go built-ins
- File: internal/pipeline/runner_test.go (append, len); internal/runner/complete_test.go (len)
- Issue: The pre-verified STALE-SYM entries flag Go built-in functions (append, len) as "not found in any source definition". These are language primitives, not project-defined symbols. Both files are in-scope new tests; neither has stale references. This is a tooling gap in the shell orphan detector, not a test integrity problem.
- Severity: LOW
- Action: Update the orphan detector (lib/test_audit_symbols.sh or equivalent) to exclude Go built-ins (append, cap, close, copy, delete, len, make, new, panic, print, println, recover) when scanning .go files.

### Findings — None in these categories

INTEGRITY: None. All assertions in the four new tests derive from real implementation behavior.
`TestOutcomeForVerdictMapping` calls the unexported `outcomeFor()` directly (legal in same-package tests) and asserts the exact outputs of the switch statement at runner.go:393-398 — every expected value matches a case branch in the implementation.
`TestRunnerStageFailRoutesToSaveExit` drives a full `RunAttempt` call through the default stage-handler branch (runner.go:197-212), which calls `shouldShortCircuit("fail") == true`, then `outcomeFor("fail") == FailureSaveExit`. The outcome, verdict, blocking_stage, and adapter call count are all computed by the implementation.
`TestRunCompleteLoopExit127BoundedByMaxAttempts` and `TestRunCompleteLoopRepeatedSaveExitDoesNotIterate` assert the save_exit branch in complete.go:160-165 which sets `Disposition=failure`, `Recovery="save_exit"`, `ErrorClass=pipeRes.BlockingStage`, then breaks — `loopErr` stays nil so the returned error is nil, matching the test's `if err != nil` check. `fp.calls==1` is enforced by the break before the next loop iteration. No assertion is hard-coded or tautological.

WEAKENING: None. No existing test was modified; all four functions are net-new additions.

COVERAGE: None flagged. The four new tests collectively cover: the exact reported bug scenario (FailureSaveExit from a fake pipeline with MaxPipelineAttempts=100, asserting only one invocation); a paranoid variant (100 identical FailureSaveExit results queued, proving only one is consumed); the `outcomeFor` contract for all six verdict values including the unrecognized-verdict tail; and the downstream-stage-not-invoked invariant when an early stage fails structurally.

EXERCISE: None. Fakes are appropriately thin — `fakeAdapter` returns canned `StageResultV1` values and lets `RunAttempt`/`outcomeFor` do the real routing work; `fakePipeline` is a counter and result queue with no logic of its own. No real behavior is mocked away.

ISOLATION: None. All four new tests pass `t.TempDir()` as `ResultDir` or use `validReq(t)` which also creates isolated temp dirs. No test reads mutable project files, pipeline logs, or live run artifacts.
