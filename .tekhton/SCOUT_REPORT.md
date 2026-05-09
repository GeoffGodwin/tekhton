## Relevant Files
- `internal/pipeline/runner.go` — `outcomeFor()` at line 385 returns `AttemptOutcomeFailureRetry` for verdict="fail"; this is the likely retry driver
- `internal/runner/complete.go` — `RunCompleteLoop` continues on `AttemptOutcomeFailureRetry` (line 155-158) with no structural-failure guard
- `internal/runner/runner.go` — `effectiveBounds()` and `DefaultMaxPipelineAttempts=5`; if the attempt bound is bypassed the only stop is wall-clock timeout
- `internal/stagerunner/adapter.go` — `BashAdapter.Run()` returns `(failResult, ErrSubprocess|err)` when subprocess exits non-zero and no result file; when result file IS present it returns `(res, nil)` even on non-zero exit (line 219-222)
- `internal/stagerunner/helpers.go` — `DefaultStageDefs` for intake includes per-stage helpers; `DefaultLibHelpers` sourced for every stage (130+ files, each taking ~300ms to source creates 40-50s per subprocess startup)
- `internal/supervisor/retry.go` — `retryLoop()` wraps claude CLI agent calls only; correctly returns immediately for non-transient errors (line 207); NOT used by BashAdapter
- `internal/errors/agent.go` — `ClassifyAgent()` maps exit 127 via `reCmdNotFound` → `ENVIRONMENT/missing_dep` → `Transient=false` (line 139-140); `IsTransient()` returns false for `missing_dep` (line 200-204)
- `internal/orchestrate/recovery.go` — `Classify()` falls through to `RecoverySaveExit` for unclassified failures with no BUILD_ERRORS (line 105-106); this layer is NOT invoked in the m19 runner path
- `internal/runner/single.go` — `RunSingle()` hardcodes `Attempts: 1` (line 50); explains why RUN_RESULT.json shows `"attempts": 1` even if pipeline retried internally
- `lib/stage_envelope.sh` — wraps `run_stage_<name>` via `stage_envelope_wrap`; if the wrapper always exits 0 (emitting fail envelope on error), BashAdapter.Run returns `(res, nil)` enabling the `outcomeFor("fail")` path
- `stages/intake.sh` — line 73 calls `_intake_get_milestone_content` which was undefined before the a42c30b helpers fix

## Key Symbols
- `outcomeFor` — `internal/pipeline/runner.go:385`; maps verdict string to attempt outcome; "fail" → `AttemptOutcomeFailureRetry` (default case; should be `AttemptOutcomeFailureSaveExit`)
- `shouldShortCircuit` — `internal/pipeline/runner.go:375`; returns true for "fail" and "block" verdicts; triggers `outcomeFor` path
- `fillFailure` — `internal/pipeline/runner.go:362`; correctly sets `AttemptOutcomeFailureSaveExit`, but only reached when adapter returns non-nil error
- `BashAdapter.Run` — `internal/stagerunner/adapter.go:148`; two exit paths: error path (non-nil err) → pipeline calls fillFailure; success path (nil err + result file) → verdict routed through outcomeFor
- `retryLoop` — `internal/supervisor/retry.go:139`; correctly bounded at MaxAttempts=3; only wraps claude CLI calls, not stage subprocess calls
- `classifyResult` / `ClassifyAgent` — `internal/supervisor/retry.go` + `internal/errors/agent.go:94`; correctly maps exit 127 → non-transient; supervisor does not retry
- `RunCompleteLoop` — `internal/runner/complete.go:36`; continues on `AttemptOutcomeFailureRetry` (line 155) with no structural-failure guard; only bounded by maxAttempts, timeoutSecs, maxCalls
- `effectiveBounds` — `internal/runner/runner.go:131`; `DefaultMaxPipelineAttempts=5`; if pipeline.conf sets MaxPipelineAttempts to 0 the attempt bound is disabled and only timeoutSecs stops the loop
- `Loop.Classify` — `internal/orchestrate/recovery.go:29`; falls through to `RecoverySaveExit` for unclassified failures — correct — but this code path is NOT reached from the m19 runner

## Suspected Root Cause Areas

- **Primary**: `outcomeFor("fail")` in `internal/pipeline/runner.go:393` returns `AttemptOutcomeFailureRetry` for ALL non-coder "fail" verdicts. When `stage_envelope.sh` catches exit 127 via an ERR trap and writes a fail envelope while the subprocess exits with code 0, `BashAdapter.Run` returns `(res, nil)` — the non-nil-error path that calls `fillFailure` is skipped. The "fail" verdict routes through `shouldShortCircuit` → `outcomeFor("fail")` → `AttemptOutcomeFailureRetry`. `RunCompleteLoop` then continues indefinitely (only the wall-clock timeout stops it). With 130+ lib files sourced per subprocess startup (~40-50s per attempt) a 7200-second timeout produces ~147 iterations.

- **Secondary**: `RunCompleteLoop` has no structural-failure guard — it cannot distinguish "review rework, please retry" from "intake subprocess crashed, structural failure". Both arrive as `AttemptOutcomeFailureRetry` when verdict="fail" from any non-coder stage. The fix is to make `outcomeFor("fail")` → `AttemptOutcomeFailureSaveExit` and reserve `AttemptOutcomeFailureRetry` for verdict="rework" only (which is already the explicit case in `runReviewLoop`).

- **The supervisor/retry path is NOT involved**: `supervisor.retryLoop` wraps claude CLI calls only; `BashAdapter` uses `os/exec` directly with no retry envelope. Exit 127 classification is correct (`ENVIRONMENT/missing_dep`, non-transient); `MAX_TRANSIENT_RETRIES=3` is properly enforced.

- **`orchestrate/recovery.go` is NOT involved in the m19 path**: `Loop.Classify` is called by `orchestrate.Loop.RunAttempt` (the m12 `tekhton orchestrate run-attempt` command), not by the m19 `runner.RunCompleteLoop`. The m19 runner uses `pipeRes.Outcome` directly. Even if m12 were involved, `Classify` would return `RecoverySaveExit` for a structural failure with no BUILD_ERRORS (line 105-106) — correct behavior.

- **`"attempts": 1` in RUN_RESULT.json**: Consistent with `RunSingle()` (no `--complete` flag), which hardcodes `Attempts: 1` regardless of pipeline internals. The 147 entries in intake.log would then come from within the single `pipeline.RunAttempt()` call — but that has no retry loop for intake. Alternative: the 147 retries happen in `RunCompleteLoop` and `RUN_RESULT.json` was examined from a DIFFERENT run; the failing run's result file would show 147.

## Affected Test Files
- `internal/runner/complete_test.go` — tests RunCompleteLoop; needs the regression test for exit-127 structural failures
- `internal/runner/extra_test.go` — additional runner tests; staging ground for the fake-stage stub
- `internal/pipeline/runner_test.go` — tests RunAttempt; needs a test for outcomeFor("fail") with a structural-fail adapter
- `tests/test_pipeline_runner.sh` — bash-level integration test for pipeline runner; naming convention match

## Complexity Estimate
Files to modify: 5
Estimated lines of change: 80
Interconnected systems: medium
Recommended coder turns: 30
Recommended reviewer turns: 8
Recommended tester turns: 25
