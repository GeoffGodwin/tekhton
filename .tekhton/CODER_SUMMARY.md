# Coder Summary

## Status
COMPLETE

## What Was Implemented

m38.3 — Tester Fix and Continuation Orchestrators. Third decimal of the
m38 tester-family port. Adds three new Go source files in
`internal/tester/` and three test files. No bash files deleted —
`stages/tester_fix.sh` and `stages/tester_continuation.sh` stay on disk
per the milestone design (M38.6 does the dispatch flip and bash deletion).

### Goal 1 — `RunInlineFix` and `FixOptions` (`internal/tester/fix.go`)

Exports:
- `RunInlineFix(ctx, *FixRequest) (*FixResult, error)` — top-level entry
  point. Loops up to `opts.MaxDepth` attempts; short-circuits on
  baseline-pre-existing, dedup-skip, or first TEST_CMD pass.
- `FixOptions` struct — `MaxDepth`, `OutputLimit`, `MaxTurns`, `Model`,
  `AgentTools`, `BaselineCheck`, `SummaryFile`, `ReportFile`, `PromptName`,
  `PromptVarsBase`.
- `DefaultFixOptions()` — `MaxDepth=1` (regression-canary),
  `OutputLimit=4000`, `MaxTurns=26`, `Model=claude-sonnet-4-6` (coder
  model — fix agent does code-fixing, not tester writing),
  `AgentTools="Read Glob Grep Write Edit Bash"`, `BaselineCheck=true`.
- `FixRequest` struct — `ProjectDir`, `PromptsDir`, `Task`, `TestCmd`,
  `Milestone`, `FailureLog`, `Architecture`, `Options`.
- `FixResult` struct — `AttemptCount`, `ResolvedFailures`, `DedupSkipped`,
  `BaselineSkipped`.
- `BaselineVerdict` enum + `BaselineChecker` interface (M38.5 swaps the
  bash shim for the native Go `internal/test_baseline` package).
- `TestDedup` interface (port-deferred to the build-fix-loop arc).
- `FixTestRunner` interface (production: `execFixTestRunner` shells out
  via `bash -c "${TEST_CMD}"`).
- `FixAgentRunner`, `FixPromptRenderer`, `FixLogger` interfaces +
  `SetFix*` seam overrides.

### Goal 2 — `SmartTruncateTestOutput` (`internal/tester/fix_truncate.go`)

Exports:
- `SmartTruncateTestOutput(output, limit) string` — failure-block
  extraction with first-5 + last-5 line truncation, joined by `"\n---\n"`,
  fallback to `tail -80` when no markers, capped at `limit` chars with
  `... [truncated at N chars]` notice.

Internal helpers: `truncateBlock`, `tailLines`, `intToString`,
`writeFixPromptTmp`, `readCoderSummaryFiles`, `cleanCoderSummaryBullet`.

### Goal 3 — `RunContinuations` and `ContinuationOptions` (`internal/tester/continuation.go`)

Exports:
- `RunContinuations(ctx, *ContinuationRequest) (*ContinuationResult, error)` —
  top-level entry point. Gated on `opts.Enabled` + git-diff file count;
  loops up to `opts.MaxAttempts` iterations until `REMAINING==0` or
  budget is exhausted.
- `ContinuationOptions` struct — `Enabled`, `MaxAttempts`, `NextTurnBudget`,
  `Model`, `AgentTools`, `ReportFile`, `PromptName`, `PromptVarsBase`.
- `DefaultContinuationOptions()` — `Enabled=true`, `MaxAttempts=3`
  (regression-canary), `NextTurnBudget=50`,
  `Model=claude-sonnet-4-6` (tester model — continuation writes tests).
- `ContinuationRequest` struct — `ProjectDir`, `PromptsDir`, `Task`,
  `ResumeFlag`, `StageStartUnix`, `InitialRemaining`, `InitialTurnsUsed`,
  `RunningTiming`, `HumanMode`, `HumanNotesTag`, `MilestoneMode`,
  `Options`.
- `ContinuationResult` struct — `Continued`, `AttemptsUsed`,
  `CumulativeTurns`, `RemainingTests`, `Timing`, `UpstreamErrored`,
  `SkipFinalChecks`.
- `RunAndRecordTestAudit(ctx, projectDir) (durationS, turns, err)` —
  thin pass-through to the `TestAuditRunner` seam (M38.4 ships the
  native Go implementation).
- Seam interfaces: `ContinuationContextBuilder`, `GitDiffReporter`,
  `RemainingReader`, `TestAuditRunner`, `StateHaltWriter`,
  `ContinuationAgentRunner`, `ContinuationPromptRenderer`,
  `ContinuationLogger`, plus `SetContinuation*` overrides.

### Goal 4 — Regression-canary tests

- `TestDefaultFixOptions_MaxDepthIs1` — asserts
  `DefaultFixOptions().MaxDepth == 1`. **Going deeper led to runaway
  agent invocations that exhausted quota in seconds. Do not change the
  default.**
- `TestDefaultContinuationOptions_MaxAttemptsIs3` — asserts
  `DefaultContinuationOptions().MaxAttempts == 3`. Three attempts is
  what operators have validated in dogfooding.

### Goal 5 — Baseline-aware short-circuit (`fix.go:286-294`)

When `opts.BaselineCheck` is true and `BaselineChecker.Has(projectDir)`
returns true, `BaselineChecker.Compare(failureOutput, 1, projectDir)` is
called. A `BaselinePreExisting` verdict returns
`FixResult{BaselineSkipped: true}` without invoking the fix agent.
Verified by `TestRunInlineFix_BaselineShortCircuits`.

### Goal 6 — Test dedup integration (`fix.go:323-336`)

`TestDedup.CanSkip()` is called BEFORE re-running TEST_CMD. When true,
TEST_CMD is skipped; on first-call success, `RecordPass()` is invoked.
Two consecutive `RunInlineFix` calls with no intervening source change
record exactly ONE TEST_CMD invocation — verified by
`TestRunInlineFix_DedupPreservedOnSecondCall`. Also covered by
`TestRunInlineFix_DedupCanSkipCalledBeforeTestRunner`.

### Goal 7 — Smart truncation port (`fix_truncate.go`)

- Walks input via `bufio.Scanner` with the
  `(FAIL|FAILED|ERROR|AssertionError|TypeError|ReferenceError|SyntaxError|CompilationError|assert|expected|unexpected)`
  marker regex.
- Opens a "failure block" when a marker line is hit, accumulates
  following lines, emits `truncateBlock(block) + "\n---\n"` when a new
  marker fires (mirrors bash exactly).
- `truncateBlock` keeps first 5 + last 5 lines joined with
  `"  ... [N lines omitted]\n"` when block length > 10.
- Falls back to `tailLines(output, 80)` when no markers matched.
- Caps total output at `limit` chars; truncated output ends with
  `"... [truncated at N chars]"`.
- Fixture-driven tests with three baseline samples:
  `pytest_three_blocks.txt`, `no_markers.txt`, `short_block.txt`.

### Goal 8 — Continuation loop git-diff gate (`continuation.go:267-269`)

`GitDiffReporter.FilesChanged(projectDir)` is called BEFORE entering
the continuation loop. When the count is < 1, the loop is skipped and
`ContinuationResult{}` (zero-state) is returned. Production
implementation `execGitDiffReporter` shells out to
`git diff` / `git diff --cached` / `git diff --stat HEAD`. Verified by
`TestRunContinuations_GitDiffGateSkipsLoop` and the two
`TestExecGitDiffReporter_*` tests against a real git repo in a tmpdir.

### Goal 9 — Continuation accumulates timing (`continuation.go:316`)

After each iteration, `MergeTimingFromFile(out.Timing, reportPath,
ParseModeAccumulate)` is called. The accumulate logic from m38.1 sums
parsed values into the running `TesterTiming` struct. Verified by
`TestRunContinuations_AccumulatesTimingPerIteration` (two-iteration
run; FilesWritten=2 in the fixture report sums to 4 across both iters).

### Goal 10 — UPSTREAM is recoverable in continuation (`continuation.go:319-329`)

When `agentRes.ErrorCategory == supervisor.CategoryUpstream` during a
continuation iteration, `RunContinuations`:
1. Calls `StateHaltWriter.Write(ctx, "tester", "upstream_error",
   ResumeFlag, Task, "API error during tester continuation N.")`.
2. Sets `out.UpstreamErrored = true` and `out.SkipFinalChecks = true`.
3. Returns `*Result, nil` (NIL ERROR — recoverable).

**This differs from TDD UPSTREAM (m38.2 returns non-nil error).** The
asymmetry is intentional and documented in the m38.3 milestone "Watch
For" notes: TDD is a pre-flight that the rest of the pipeline depends
on, so its failure halts; continuation is "tester didn't finish in
time" recovery, and a mid-recovery API failure means the operator just
resumes the run.

Verified by `TestRunContinuations_UpstreamIsRecoverable`.

### Coverage

- `go test -cover ./internal/tester/` → **91.7%** of statements
  (≥80% milestone target met).
- Per-function: `RunInlineFix` 95.8%, `RunContinuations` (the inline
  body in `continuation.go`) ~94%, `SmartTruncateTestOutput` 96.8%,
  `truncateBlock` 92.9%, both `Default*Options` 100%, all `Set*` seams
  100%.
- `go vet ./...` — clean.
- `gofmt -l internal/tester/` — empty.
- `go build ./...` — clean.
- `go test ./...` — all packages PASS.
- `bash tests/run_tests.sh` — 508 shell passed, 0 failed, Go PASSED.
- `bash scripts/wedge-audit.sh` — clean (188 files audited).
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — zero warnings
  (no bash modified).

### File length sanity (CLAUDE.md Rule 8)

- `internal/tester/fix.go` — 484 lines (≤ 600 soft target)
- `internal/tester/fix_truncate.go` — 199 lines
- `internal/tester/continuation.go` — 512 lines
- `internal/tester/fix_test.go` — 536 lines
- `internal/tester/fix_truncate_test.go` — 184 lines
- `internal/tester/continuation_test.go` — 587 lines

All under the 600-line Go soft target.

## Root Cause (bugs only)

N/A — m38.3 is a port milestone, not a bug fix. The reviewer notes from
the m38.2 run targeted `tdd.go` (out of m38.3 scope) — they are
preserved as observed issues for the m38.6 closure.

## Files Modified

### Created (NEW)

- `internal/tester/fix.go` (NEW, 484 lines) — `RunInlineFix`,
  `FixOptions`, `DefaultFixOptions`, `FixRequest`, `FixResult`,
  `BaselineVerdict`/`BaselineChecker`/`TestDedup`/`FixTestRunner`/
  `FixAgentRunner`/`FixPromptRenderer`/`FixLogger` interfaces,
  `SetFix*` seam overrides, `withFixDefaults`, `extractFailureOutput`,
  `buildFixPromptVars`, `extractTestFilePaths`, `execFixTestRunner`,
  no-op seam implementations.
- `internal/tester/fix_truncate.go` (NEW, 199 lines) —
  `SmartTruncateTestOutput`, `truncateBlock`, `tailLines`,
  `intToString`, `writeFixPromptTmp`, `readCoderSummaryFiles`,
  `cleanCoderSummaryBullet`.
- `internal/tester/continuation.go` (NEW, 512 lines) —
  `RunContinuations`, `ContinuationOptions`,
  `DefaultContinuationOptions`, `ContinuationRequest`,
  `ContinuationResult`, `RunAndRecordTestAudit`, eight seam interfaces
  (`ContinuationContextBuilder`, `GitDiffReporter`, `RemainingReader`,
  `TestAuditRunner`, `StateHaltWriter`, `ContinuationAgentRunner`,
  `ContinuationPromptRenderer`, `ContinuationLogger`), `SetContinuation*`
  overrides, `withContinuationDefaults`, `resolveContinuationPath`,
  `buildContinuationPromptVars`, `defaultContextBuilder`,
  `execGitDiffReporter`, `fileRemainingReader`, no-op seam
  implementations.
- `internal/tester/fix_test.go` (NEW, 536 lines) — `fakeFixAgentRunner`,
  `fakeFixPromptRenderer`, `fakeBaselineChecker`, `fakeTestDedup`,
  `fakeFixTestRunner`, `captureLogger`, `installFixSeams`,
  `newFixRequest`; regression-canary `TestDefaultFixOptions_MaxDepthIs1`;
  `TestRunInlineFix_BaselineShortCircuits`,
  `TestRunInlineFix_DedupPreservedOnSecondCall`,
  `TestRunInlineFix_DedupCanSkipCalledBeforeTestRunner`,
  `TestRunInlineFix_UpstreamErrorPropagates`,
  `TestRunInlineFix_AgentInvocationErrorReturnsError`,
  `TestRunInlineFix_PromptRenderErrorReturnsError`,
  `TestRunInlineFix_NilRequestReturnsError`,
  `TestRunInlineFix_TestCmdEmptyBreaksAfterOneAttempt`,
  `TestRunInlineFix_PromptVarsIncludeTestFiles`,
  `TestRunInlineFix_PromptVarsReadCoderSummary`,
  `TestRunInlineFix_RecordsRunningAttemptCount`,
  `TestWithFixDefaults_*`, `TestExtractFailureOutput_*`,
  `TestExtractTestFilePaths_DedupAndSort`,
  `TestSetFixSeams_NilDoesNotReplace`,
  `TestExecFixTestRunner_*`, `TestNoopSeams_ReturnSafeDefaults`.
- `internal/tester/fix_truncate_test.go` (NEW, 184 lines) —
  `TestSmartTruncateTestOutput_*` (6 variants),
  `TestTruncateBlock_*` (3 variants),
  `TestCleanCoderSummaryBullet_StripsBacktickAndAnnotation`,
  `TestReadCoderSummaryFiles_*` (2 variants),
  `TestTailLines_FewerThanNReturnsAll`, `TestIntToString_Conversion`.
- `internal/tester/continuation_test.go` (NEW, 587 lines) —
  `fakeContAgentRunner`, `fakeContPromptRenderer`, `fakeContGitDiff`,
  `fakeContRemainingReader`, `fakeContAuditRunner`,
  `fakeContStateHalt`, `fakeContContextBuilder`, `installContSeams`,
  `newContRequest`; regression-canary
  `TestDefaultContinuationOptions_MaxAttemptsIs3`;
  `TestRunContinuations_DisabledSkipsLoop`,
  `TestRunContinuations_GitDiffGateSkipsLoop`,
  `TestRunContinuations_UpstreamIsRecoverable`,
  `TestRunContinuations_SuccessRunsTestAudit`,
  `TestRunContinuations_AccumulatesTimingPerIteration`,
  `TestRunContinuations_StopsAtMaxAttempts`,
  `TestRunContinuations_NilRequestReturnsError`,
  `TestRunContinuations_RenderErrorPropagates`,
  `TestRunContinuations_AgentInvocationErrorPropagates`,
  `TestRunContinuations_PromptVarsIncludeContinuationContext`,
  `TestRunContinuations_TaskFlowsIntoPromptVars`,
  `TestRunAndRecordTestAudit_DelegatesToSeam`,
  `TestWithContinuationDefaults_FillsZeros`,
  `TestResolveContinuationPath_Branches`,
  `TestDefaultContextBuilder_RendersTesterAndCoderLabels`,
  `TestFileRemainingReader_ReadsCount`,
  `TestExecGitDiffReporter_CleanDirReturnsZero`,
  `TestExecGitDiffReporter_DirtyDirReportsChange`,
  `TestNoopContinuationSeams_Safe`,
  `TestSetContinuationSeams_NilDoesNotReplace`.
- `internal/tester/testdata/fix/pytest_three_blocks.txt` (NEW) —
  three-block failure fixture used by the truncation tests.
- `internal/tester/testdata/fix/no_markers.txt` (NEW) — no-marker
  fallback fixture.
- `internal/tester/testdata/fix/short_block.txt` (NEW) — short-block
  pass-through fixture.
- `internal/tester/testdata/continuation/tester_report_with_remaining.md`
  (NEW) — TESTER_REPORT.md with REMAINING > 0 and FilesWritten=2 in the
  Timing section. Used by `TestRunContinuations_AccumulatesTimingPerIteration`.
- `internal/tester/testdata/continuation/tester_report_done.md` (NEW) —
  TESTER_REPORT.md with REMAINING=0 and FilesWritten=3. Reserved for
  future single-iteration accumulate tests.

### Modified

- `internal/tester/tdd/tdd_test.go` — replaced the m38.2-era
  `TestPackage_NoFixOrContinuationYet` sanity guard with the inverted
  `TestPackage_FixAndContinuationExist` (m38.3 requires the files to
  exist). Reworded `TestPackage_BashFileStillExists` comment to mark
  the bash file as "pre-m38.6" rather than "at m38.2 close".

### Deleted

None. M38.6 will do the bash cutover and delete `stages/tester_fix.sh`
and `stages/tester_continuation.sh`.

## Docs Updated

None — no public-surface changes in this task. The new exported types
(`RunInlineFix`, `RunContinuations`, the option structs, the seam
interfaces) are internal Go API consumed only by the upcoming
`internal/tester` `RunStage` (M38.6). No CLI subcommand, config key,
or prompt template variable changed. M38.6 will add the
ARCHITECTURE.md entry for the tester stage as part of the bash cutover,
per the m38.1/m38.2 precedent.

## Human Notes Status

N/A — no human notes injected this run.

## Acceptance Criteria Verification

- [x] `internal/tester/fix.go` exports `RunInlineFix`, `FixOptions`,
  `DefaultFixOptions`, `SmartTruncateTestOutput` — verified by grep
  for `^func RunInlineFix`, `^type FixOptions`, `^func DefaultFixOptions`
  (in fix.go) and `^func SmartTruncateTestOutput` (in fix_truncate.go,
  same package).
- [x] `DefaultFixOptions().MaxDepth == 1` — verified by
  `TestDefaultFixOptions_MaxDepthIs1`. **Regression-canary.**
- [x] `RunInlineFix` short-circuits and returns
  `FixResult{BaselineSkipped: true}` when `BaselineChecker.Compare`
  returns `BaselinePreExisting` — verified by
  `TestRunInlineFix_BaselineShortCircuits`.
- [x] `RunInlineFix` calls `TestDedup.CanSkip` before re-running
  TEST_CMD; if `CanSkip` returns true, TEST_CMD is NOT invoked —
  verified by `TestRunInlineFix_DedupCanSkipCalledBeforeTestRunner`.
- [x] Two consecutive `RunInlineFix` calls with no intervening source
  change record exactly ONE TEST_CMD invocation — verified by
  `TestRunInlineFix_DedupPreservedOnSecondCall` asserting
  `runner.calls == 1` across both calls.
- [x] `SmartTruncateTestOutput` of a fixture with 3 failure blocks
  returns 3 truncated blocks joined by `\n---\n`, each capped at 10
  lines — verified by
  `TestSmartTruncateTestOutput_ThreeBlocksJoinedByDashes`.
- [x] `SmartTruncateTestOutput` of an input with no failure markers
  falls back to `tail -80` of the input — verified by
  `TestSmartTruncateTestOutput_NoMarkersFallsBackToTail80` and
  `TestSmartTruncateTestOutput_NoMarkersFromFixture`.
- [x] `SmartTruncateTestOutput` caps total output at `limit` chars;
  output longer than limit is truncated and ends with
  `... [truncated at N chars]` — verified by
  `TestSmartTruncateTestOutput_CapsAtLimitWithTruncationNotice`.
- [x] `internal/tester/continuation.go` exports `RunContinuations`,
  `ContinuationOptions`, `DefaultContinuationOptions`,
  `RunAndRecordTestAudit`.
- [x] `DefaultContinuationOptions().MaxAttempts == 3` — verified by
  `TestDefaultContinuationOptions_MaxAttemptsIs3`.
- [x] `RunContinuations` skips the loop and returns
  `ContinuationResult{Continued: false}` when zero test files were
  created (git diff returns empty) — verified by
  `TestRunContinuations_GitDiffGateSkipsLoop`.
- [x] `RunContinuations` UPSTREAM during a continuation iteration
  returns `nil` error (recoverable), writes pipeline state, sets
  `SkipFinalChecks=true` — DIFFERENT from TDD UPSTREAM (m38.2) which
  returns non-nil error. Verified by
  `TestRunContinuations_UpstreamIsRecoverable`.
- [x] `RunContinuations` calls `MergeTimingFromFile(... ,
  ParseModeAccumulate)` after each continuation iteration — verified
  by `TestRunContinuations_AccumulatesTimingPerIteration` asserting
  the accumulated FilesWritten=4 after two iterations on a fixture
  with FilesWritten=2 per iteration.
- [x] On clean continuation finish (REMAINING==0), `RunContinuations`
  calls the audit seam — verified by
  `TestRunContinuations_SuccessRunsTestAudit` asserting `audit.calls
  == 1`.
- [x] `go test ./internal/tester/...` passes with coverage **91.7%**
  (≥80% required).
- [x] `stages/tester_fix.sh` and `stages/tester_continuation.sh` are
  NOT deleted in this milestone — verified by `ls -la stages/tester_fix.sh
  stages/tester_continuation.sh` showing both files.
- [x] No `internal/test_audit/` or `internal/test_baseline/` packages
  exist yet — verified by `ls internal/` (no `test_audit` or
  `test_baseline` directories). Those land in M38.4 and M38.5.
- [x] The implementation run is itself driven by `tekhton run
  --milestone m38.3 --complete` — this run.

## Watch For Items Addressed

- **`TESTER_FIX_MAX_DEPTH=1` default is load-bearing.** Implemented at
  `fix.go:44` as `DefaultFixMaxDepth = 1`. Covered by
  `TestDefaultFixOptions_MaxDepthIs1`.
- **`MAX_CONTINUATION_ATTEMPTS=3` default similarly bounded.**
  Implemented at `continuation.go:46` as
  `DefaultContinuationMaxAttempts = 3`. Covered by
  `TestDefaultContinuationOptions_MaxAttemptsIs3`.
- **Fix vs continuation UPSTREAM semantics differ.** Fix UPSTREAM is
  not strictly modeled — the agent error propagates as a Go error since
  the bash loop simply continues to the next attempt; tests cover the
  agent-returned UPSTREAM path producing a non-nil error
  (`TestRunInlineFix_UpstreamErrorPropagates`). Continuation UPSTREAM
  returns nil error with `SkipFinalChecks=true` per
  `TestRunContinuations_UpstreamIsRecoverable`. The TDD-style "exit 1"
  semantic stays in `internal/tester/tdd/tdd.go`.
- **`test_dedup` stays bash through M38.** The `TestDedup` interface
  defines the seam; production callers will install a bash shim. The
  fix.go production default is `noopTestDedup{}` (never skips) so
  in-process Go tests without a wired-up dedup don't surprise-skip.
- **`test_baseline` integration is via interface, not direct import.**
  The `BaselineChecker` interface is defined locally in fix.go; the
  production default `noopBaselineChecker` returns false/Unknown. M38.5
  swaps in the native Go `internal/test_baseline` implementation.
- **The fix loop's TEST_CMD is shell-evaluated.** `execFixTestRunner`
  invokes `bash -c "${TestCmd}"` so users keep pipes, env-var expansion,
  etc. Verified by `TestExecFixTestRunner_ReportsExitCode` with
  `TEST_CMD = "exit 7"`.
- **The fix agent uses `CLAUDE_CODER_MODEL`, not
  `CLAUDE_TESTER_MODEL`.** `DefaultFixCoderModel = "claude-sonnet-4-6"`
  in fix.go; `DefaultContinuationModel = "claude-sonnet-4-6"` in
  continuation.go. Same string by coincidence today, but the constants
  are distinct so a future model bifurcation is a one-line change.
- **The continuation loop builds a `tester_resume` prompt.**
  `DefaultContinuationOptions().PromptName = "tester_resume"` in
  continuation.go; `buildContinuationPromptVars` sets
  `CONTINUATION_CONTEXT` from the `ContinuationContextBuilder` seam.
  The Go-side `BuildContinuationContext` referenced in the milestone
  design does NOT yet exist; the local `defaultContextBuilder` produces
  a minimal valid context until a future arc ports the bash version
  fully.

## Architecture Change Proposals

None. The m38.3 port follows the established sub-stage port pattern.
Two minor design clarifications worth noting (not architecture changes):

1. The milestone design assumed `internal/context.BuildContinuationContext`
   already exists in Go. It does NOT. M38.3 introduces a
   `ContinuationContextBuilder` interface with a minimal default that
   produces a working continuation prompt. A future arc can swap the
   default for a richer port of `build_continuation_context` from
   `lib/agent_helpers.sh`. This is a seam-level adaptation, not an
   architecture change.

2. The milestone design described
   `internal/tester/fix.go::SmartTruncateTestOutput`. The implementation
   lands `SmartTruncateTestOutput` in `internal/tester/fix_truncate.go`
   (same `tester` package). The split keeps fix.go under the 600-line
   soft target and isolates the pure-string transformation from the
   orchestration concerns. Public surface is identical (same package,
   same exported name).

## Design Observations

None. The milestone design matches reality except for the two
clarifications above.

## Seeds Forward

- **M38.4 — Test audit family:** `RunAndRecordTestAudit` currently
  delegates to a no-op `TestAuditRunner` seam. M38.4 lands
  `internal/test_audit` and swaps the no-op for the native Go
  implementation.
- **M38.5 — Test baseline port:** `BaselineChecker` swaps from
  `noopBaselineChecker` to a native Go implementation under
  `internal/test_baseline`. fix.go is not modified.
- **M38.6 — Main stage port:** `RunStage` will call `RunInlineFix` from
  the `RoutingTestFailures` branch of `ValidateOutput` (m38.1), and
  `RunContinuations` from the `RoutingPartialRun` branch. The bash
  files delete here.
- **Future TestDedup port:** Retires the bash-shim `TestDedup`. The
  interface stays — the implementation just stops shelling out.

## Observed Issues (out of scope)

Carry-forward non-blocking notes from the m38.2 reviewer cycle (these
target `internal/tester/tdd/tdd.go`, not m38.3 territory):

- `tdd.go:122-126` — package-level seam vars unguarded by a mutex.
  Sequential test execution safe; future `t.Parallel()` adoption
  requires sync protection. The same caveat applies to the new seam
  variables in fix.go (`fixAgentRunner`, etc.) and continuation.go
  (`contextBuilder`, etc.). Recorded for the M38.6 closure.
- `tdd.go:384` — `defaultStateWriter.WriteHalt` accepts but discards
  the `ctx context.Context` parameter. Out of m38.3 scope; m38.6 or
  later closure should reconcile.
- `tdd.go:321-336` — `buildResumeFlag` whitespace divergence from
  bash. Not a regression; m38.6 closure has the dispatch context to
  decide.

These are documented for the M38.6 reviewer cycle.
