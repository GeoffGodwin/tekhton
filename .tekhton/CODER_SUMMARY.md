# Coder Summary

## Status: COMPLETE

## What Was Implemented

Bounded the unbounded retry loop reported in HUMAN_NOTES (`stages/intake.sh: line 73`
repeated 147 times in `intake.log` after a single deterministic exit-127 crash).

The structural fix is one routing change in `internal/pipeline/runner.go`:
`outcomeFor()` previously returned `AttemptOutcomeFailureRetry` for every verdict
that wasn't pass/skip/block — including `verdict=fail`, which is what the
`stagerunner.BashAdapter` synthesizes when a bash stage subprocess crashes
without writing its result envelope (`internal/stagerunner/adapter.go:398-407`).
That FailureRetry signal flowed up through `pipeline.RunAttempt` into
`runner.RunCompleteLoop`, whose failure-path branch at
`internal/runner/complete.go:155-158` continues looping on FailureRetry. With
the synthesized fail being treated as recoverable, `RunCompleteLoop` would burn
attempts in a tight loop until the autonomous-timeout bound finally tripped.

The fix inverts the default: only `verdict=rework` routes to FailureRetry; every
other terminal verdict (`fail`, `block`, and any unrecognized value) routes to
FailureSaveExit. A structural subprocess crash is by definition not recoverable
by re-running, so the outer loop now terminates after one attempt and surfaces
the structural error class via `BlockingStage`.

### Investigation findings (the bug listed three suspects to check)

1. **`supervisor.classifyExit` mapping exit 127 to transient.** No such
   function exists. `internal/supervisor/retry.go` is for AGENT calls (the
   Claude CLI subprocess), not stage subprocesses. The supervisor classifies
   `AgentResultV1.Outcome` strings, never raw bash exit codes. `errors.go`
   sentinels carry an explicit `Transient` bool — none of the structural
   subcategories (`null_run`, `max_turns`, `null_activity_timeout`,
   `activity_timeout`, the entire ENVIRONMENT/PIPELINE families) are marked
   transient. Exit 127 from a stage bash subprocess never enters this layer.

2. **`MAX_TRANSIENT_RETRIES` (default 3) being respected.** The cap is honored
   by `supervisor.retryLoop` for agent calls, but again — that loop is for
   Claude CLI invocations, not stage subprocesses. The 147-iteration log was
   coming from above this layer, not below.

3. **`orchestrate/recovery.go` re-entering the same handler.** `Classify`
   already correctly returns `proto.RecoverySaveExit` for the unclassified-error
   tail (recovery.go:106) and for ENVIRONMENT/PIPELINE/UPSTREAM categories.
   It is also a parallel code path: it runs under `tekhton orchestrate
   run-attempt`, not under `tekhton run`, which uses `runner.RunCompleteLoop`.
   The actual loop hosting the bug was the runner's, not the orchestrator's.

### Regression test coverage added

- `TestRunnerStageFailRoutesToSaveExit` (`internal/pipeline/runner_test.go`):
  asserts that when a non-coder stage emits `verdict=fail`, the per-attempt
  result carries `FailureSaveExit` and downstream stages do not run.
- `TestOutcomeForVerdictMapping` (`internal/pipeline/runner_test.go`):
  pins the verdict→outcome contract end-to-end so a future refactor cannot
  silently re-introduce the unbounded-retry routing.
- `TestRunCompleteLoopExit127BoundedByMaxAttempts` (`internal/runner/complete_test.go`):
  the exact scenario from HUMAN_NOTES — a fake pipeline that returns
  `FailureSaveExit` for an exit-127 simulation, with `MaxPipelineAttempts=100`
  to prove the cap is irrelevant: structural failure terminates after one
  invocation, not 100.
- `TestRunCompleteLoopRepeatedSaveExitDoesNotIterate` (`internal/runner/complete_test.go`):
  paranoid variant — even when the fake pipeline is willing to keep emitting
  FailureSaveExit, the outer loop must terminate after one attempt.

## Root Cause (bugs only)

`outcomeFor()` in `internal/pipeline/runner.go` defaulted to `FailureRetry` for
any verdict that wasn't pass/skip/block. That made `verdict=fail` (including
the synthetic envelope `BashAdapter` writes for a crashing subprocess) look
recoverable to `RunCompleteLoop`, which then iterated until the autonomous
timeout. The 147 `command not found` lines were one BashAdapter invocation per
outer-loop iteration, each resourcing the broken intake stage. The right
mapping is the inverse: only `verdict=rework` is recoverable; everything else
that isn't pass/skip terminates the outer loop with `FailureSaveExit`.

## Files Modified

- `internal/pipeline/runner.go` — rewrote `outcomeFor()` so structural failures
  route to FailureSaveExit; added a doc comment explaining why this matters.
- `internal/pipeline/runner_test.go` — added two regression tests
  (`TestRunnerStageFailRoutesToSaveExit`, `TestOutcomeForVerdictMapping`).
- `internal/runner/complete_test.go` — added two regression tests
  (`TestRunCompleteLoopExit127BoundedByMaxAttempts`,
  `TestRunCompleteLoopRepeatedSaveExitDoesNotIterate`) covering the exact
  scenario from HUMAN_NOTES.

## Docs Updated

None — no public-surface changes (no new CLI flags, exported APIs, config
keys, or schemas). The change is a behavioral correction to an internal
routing helper, fully covered by the new tests.

## Human Notes Status

- COMPLETED: [BUG] **Failed bash subprocess retried 147 times in a tight loop.**
  `.claude/logs/intake.log` shows the same `stages/intake.sh: line 73:
  _intake_get_milestone_content: command not found` line 147 times — a single
  bash subprocess that should exit 127 immediately is being retried by the
  orchestrator at machine speed with no apparent bound. (Fixed in
  `internal/pipeline/runner.go::outcomeFor`; four regression tests added across
  `internal/pipeline/runner_test.go` and `internal/runner/complete_test.go`.
  Investigation confirmed the supervisor and orchestrator paths called out in
  the note as suspects do not host the bug — see "Investigation findings"
  above for the full reasoning chain.)
- NOT_ADDRESSED: [BUG] At the end of a `--fix-nonblockers` run, the
  action-items summary prints `${NON_BLOCKING_LOG_FILE} — N accumulated
  observation(s)` using the pre-run count (out of scope — task scoped to the
  exit-127 retry-loop bug).
- NOT_ADDRESSED: [POLISH] **m01/m02 milestone-doc cleanup pass.** (out of
  scope — task scoped to the exit-127 retry-loop bug).
