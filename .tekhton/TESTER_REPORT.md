## Planned Tests
- [x] `internal/provider/provider_test.go` — update interface method count to 3, add TierCostRank table-driven test, tier constant value assertions
- [x] `internal/provider/claude/claude_test.go` — Tier() returns "api" by default, returns "subscription" with TEKHTON_CLAUDE_PRE_JUNE_15=true
- [x] `internal/provider/codex/codex_test.go` — Tier() returns subscription when auth.json exists, api when CODEX_API_KEY set, unknown when neither
- [x] `internal/runner/provider_chain_test.go` — SortByCostRank reorders cheaper-first, RunAgent records TierUsed from winning provider

## Test Run Results
Passed: 249  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/provider/provider_test.go`
- [x] `internal/provider/claude/claude_test.go`
- [x] `internal/provider/codex/codex_test.go`
- [x] `internal/runner/provider_chain_test.go`

## Timing
- Test executions: 6
- Approximate total test execution time: 25s
- Test files written: 4

---

## Test Audit Report

### Audit Summary
Tests audited: 4 files, 36 test functions
Verdict: PASS

### Findings

#### NAMING: Dead code in stub binary test
- File: internal/provider/codex/codex_test.go:121-125
- Issue: `TestRunAgent_StubBinary` calls `os.Executable()`, assigns to `echo`, then immediately discards it with `_ = echo`. The t.Skip guard wrapping it will never trigger (os.Executable fails only in extraordinarily broken environments). The code appears to be a leftover from when the test was going to use the test binary itself as the codex stub before pivoting to `/bin/echo`. It misleads readers into thinking os.Executable is load-bearing.
- Severity: LOW
- Action: Remove the four dead lines (os.Executable call through `_ = echo`). The test works fine without them.

#### COVERAGE: TurnEnd.Timestamp not verified in streaming events test
- File: internal/provider/claude/claude_test.go:86-113
- Issue: `TestProvider_StreamingEvents` verifies that TurnStart and RunEnd events carry non-zero Timestamps, but does not check events[1] (TurnEnd). The implementation at claude.go:122-126 sets `Timestamp: time.Now()` on TurnEnd just as it does for the other two events. The inline comment acknowledges this gap ("Reviewer coverage gap"), which is fine as a note, but the gap itself is real — a future refactor that drops the timestamp from TurnEnd would not be caught.
- Severity: LOW
- Action: Add `if events[1].Timestamp.IsZero() { t.Error(...) }` after the existing TurnEnd.Turn assertion.

#### COVERAGE: Null-run threshold boundary not tested
- File: internal/provider/claude/claude_test.go:201-219
- Issue: `TestTranslateOutcome_UpstreamWithLowTurns` uses `TurnsUsed: 1` and asserts OutcomeNullRun wins over OutcomeUpstreamError. The corresponding threshold is `supervisor.DefaultNullRunThreshold = 2`. The exact boundary case (TurnsUsed=2, still a null run) and the first-over case (TurnsUsed=3, no longer a null run) are untested. If the threshold changes or the `<=` becomes `<`, this test would not catch it.
- Severity: LOW
- Action: Add two sub-cases using `supervisor.DefaultNullRunThreshold` and `supervisor.DefaultNullRunThreshold+1` to pin the boundary in both directions.

#### EXERCISE: TestRunAgent_StubBinary exercises degenerate path only
- File: internal/provider/codex/codex_test.go:117-148
- Issue: Using `/bin/echo` as the codex binary means the subprocess produces no valid JSONL. `decodeStream` returns empty events; `deriveOutcome` maps (events=[], exitCode=0) → OutcomeSuccess+NullRun=true. The test confirms the provider does not crash and Outcome=Success, which is correct. However, it does not assert `res.NullRun == true`, leaving a silent discrepancy between the outcome and the null-run flag that stages downstream depend on. The test comment concedes this ("good enough for a scaffold test").
- Severity: LOW
- Action: Add `if !res.NullRun { t.Error(...) }` to the existing assertion block, or add a separate test with a real codex-shaped output fixture to exercise the non-degenerate path.

### Notes (no action required)

All assertions in every file were verified against the implementation:

- `provider_test.go`: Tier constants, TierCostRank values, Outcome/EventKind iota ordering, and interface method count all match `provider.go` and `event.go` exactly.
- `claude_test.go`: translateOutcome precedence (IsNullRun before ErrorCategory), channel-close-on-error guarantee, and Tier env-variable logic all match `claude.go` exactly. `TestProvider_EventChan_ClosedOnWritePromptFileError` correctly verifies the m05 fix (defer close before writePromptFile).
- `codex_test.go`: Tier resolution order (OAuth > API key > unknown) matches `codex.go:Tier()` exactly. `TestProvider_Tier_OAuthPrecedesEnvKey` correctly pins the precedence rule.
- `provider_chain_test.go`: Fallthrough-on-UpstreamError, no-fallthrough-on-MaxTurns, all-exhausted last-result return, RequiredTier rejection (`errors.Is(err, runner.ErrTierLimitExceeded)` is valid because the implementation returns the sentinel directly), and TierUsed stamping all match `provider_chain.go` exactly.

Test isolation is clean across all four files (t.TempDir, t.Setenv, in-memory stubs only). No test reads mutable project files or depends on pipeline run state.
