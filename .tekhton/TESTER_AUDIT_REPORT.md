## Test Audit Report

### Audit Summary
Tests audited: 4 files, 36 test functions  
Files: internal/provider/provider_test.go, internal/provider/claude/claude_test.go,
internal/provider/codex/codex_test.go, internal/runner/provider_chain_test.go  
Verdict: PASS

---

### Findings

#### EXERCISE: Dead code in stub-binary test
- File: internal/provider/codex/codex_test.go:163–167
- Issue: `TestRunAgent_StubBinary` calls `os.Executable()`, assigns the result to `echo`, then immediately discards it with `_ = echo`. The `t.Skip` guard around it will never fire in any normal environment. The variable is a leftover from a draft that planned to use the test binary itself as the codex stub before pivoting to `/bin/echo`. It does not affect correctness but misleads readers into thinking the call is load-bearing.
- Severity: LOW
- Action: Remove lines 163–167 (the `os.Executable()` block through `_ = echo`). The test body starting at `p := codex.NewWithBinary("/bin/echo")` is self-contained and does not need it.

#### COVERAGE: TurnEnd.Timestamp not asserted in streaming events test
- File: internal/provider/claude/claude_test.go:86–113
- Issue: `TestProvider_StreamingEvents` asserts `events[0].Timestamp` (TurnStart) and `events[2].Timestamp` (RunEnd) are non-zero, but does not check `events[1].Timestamp` (TurnEnd). The implementation at `claude.go:122–126` sets `Timestamp: time.Now()` on TurnEnd just as it does for the other two events. A refactor that accidentally dropped the timestamp assignment from TurnEnd would pass this test silently. The inline comment acknowledges the gap.
- Severity: LOW
- Action: Add `if events[1].Timestamp.IsZero() { t.Errorf("TurnEnd.Timestamp is zero — provider must set time.Now() on emission") }` after the existing `TurnEnd.Turn` assertion (after line 103).

#### COVERAGE: NullRun field not asserted in stub-binary test
- File: internal/provider/codex/codex_test.go:160–191
- Issue: With `/bin/echo` as the codex binary, `decodeStream` produces no valid events and `deriveOutcome([], 0)` maps to `Outcome=Success, NullRun=true`. The test asserts `OutcomeSuccess` and `ExitCode=0` but does not assert `res.NullRun == true`. Downstream stage logic branches on `NullRun`; a regression flipping that field would pass this test silently. The test comment concedes this ("good enough for a scaffold test") but does not propose a fix.
- Severity: LOW
- Action: Add `if !res.NullRun { t.Errorf("NullRun: want true for echo stub producing no valid JSONL, got false") }` at the end of the assertion block.

#### COVERAGE: Null-run threshold boundary not pinned
- File: internal/provider/claude/claude_test.go:201–219
- Issue: `TestTranslateOutcome_UpstreamWithLowTurns` uses `TurnsUsed: 1` and asserts OutcomeNullRun wins over OutcomeUpstreamError. The governing threshold is `supervisor.DefaultNullRunThreshold = 2`. The exact boundary (`TurnsUsed == DefaultNullRunThreshold`, still a null run) and the first-over case (`TurnsUsed == DefaultNullRunThreshold+1`, no longer a null run) are untested. If the `<=` comparison in `IsNullRun()` becomes `<`, or the constant changes, this single-sample test would not catch it.
- Severity: LOW
- Action: Add two sub-cases parameterised on `supervisor.DefaultNullRunThreshold` and `supervisor.DefaultNullRunThreshold+1` to pin the boundary in both directions.

#### COVERAGE: Vacuous TierUsed guard in process-error test
- File: internal/runner/provider_chain_test.go:199–204
- Issue: `TestChain_RunAgent_ProcessError` correctly asserts `err != nil`. The second check `if res != nil && res.TierUsed != ""` is vacuous because `fixedProvider.RunAgent` returns `(nil, err)` on process error, and `Chain.RunAgent` propagates that nil result directly. Since `res` is always nil, the `TierUsed` branch never executes. The test does not assert `res == nil`, so a future implementation change returning a non-nil result with TierUsed set on process error would pass unchallenged.
- Severity: LOW
- Action: Replace the vacuous guard with an explicit assertion: `if res != nil { t.Errorf("RunAgent: want nil result on process error, got %+v", res) }`.

---

### Notes (no action required)

**Assertion honesty:** Every assertion was cross-referenced against the implementation. Tier constant values match `provider.go`; `TierCostRank()` switch arms match the test table exactly; `Outcome` and `EventKind` iota ordering matches `provider.go` and `event.go`; interface method count is correct (3: Name, Tier, RunAgent); `Chain.RunAgent` fallthrough logic, RequiredTier enforcement, TierUsed stamping, and `translateOutcome()` precedence rules all match `provider_chain.go` and `claude.go` exactly. No hard-coded magic values, tautological assertions, or always-passing checks were found beyond the vacuous guard noted above.

**Concurrency test:** `TestProvider_Tier_Concurrent` correctly documents the data race on `codex.go:cachedTier` (read at line 61, written at lines 65 and 69 with no synchronization). The test body is sound — each goroutine writes to a distinct `results[i]` slot, and the barrier/WaitGroup ordering is correct. As the test comment states, the race is surfaced only under `go test -race`. This is an honest, correctly bounded test.

**Test isolation:** All four files use `t.TempDir()`, `t.Setenv()`, and in-memory stubs exclusively. No test reads mutable pipeline state files, build reports, or `.claude/` artifacts. Isolation is clean across the entire suite.

**Scope alignment:** No orphaned imports, stale type references, or tests exercising removed behavior were found. All referenced types and functions (`codex.NewWithBinary`, `runner.NewChain`, `runner.ErrTierLimitExceeded`, `provider.TierCostRank`, etc.) exist in the current implementation.

**Weakening check:** The tester added new tests and extended existing suites. No existing assertion was removed or broadened. No weakening detected.
