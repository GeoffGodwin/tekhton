## Test Audit Report

### Audit Summary
Tests audited: 5 files, 30 test functions
Verdict: PASS

### Findings

#### COVERAGE: Partial-completion error path not tested
- File: internal/provider/claude/parity_test.go
- Issue: The `supErr != nil && v1 != nil` branch in `RunAgent` (claude.go:115–118) is
  never exercised. That branch returns `(translateResult(v1), supErr)` — a non-nil
  Result alongside a non-nil error — which is the only place in the provider where
  that combination can legitimately arise. No test stub configures both a non-nil
  result and a non-nil error simultaneously.
- Severity: LOW
- Action: Add a table entry with `supErr: errors.New("partial")` and a stub that
  returns a non-nil result alongside that error; assert `got != nil && err != nil`.

#### COVERAGE: Upstream error with turns ≤ NullRunThreshold untested
- File: internal/provider/claude/parity_test.go
- Issue: `translateOutcome` checks `IsNullRun()` before `CategoryUpstream`, meaning
  an upstream error with `turns_used <= DefaultNullRunThreshold` (2) is classified
  as `OutcomeNullRun`, not `OutcomeUpstreamError`. The `upstream_error` fixture uses
  `turns_used=3` — safely above the threshold — so the IsNullRun/Upstream precedence
  decision is exercised only indirectly. The intentional design choice (stated in the
  design notes) that null-run detection masks upstream classification is not pinned
  by any test.
- Severity: LOW
- Action: Add a unit test in `claude_test.go` (where `translateOutcome` is already
  exercised directly) calling `translateOutcome` with `exit_code=1`,
  `turns_used=1`, `error_category=UPSTREAM` and asserting the result is
  `OutcomeNullRun`, not `OutcomeUpstreamError`. This pins the precedence rule as an
  explicit invariant rather than an accident of the fixture.

#### NAMING: "context_cancelled" comment overstates cancellation timing
- File: internal/provider/claude/parity_test.go:72–79
- Issue: The inline comment reads "pre-first-turn cancellation must return a nil
  Result." The test does not cancel the context before `RunAgent` is called; it
  supplies `context.Background()` and has the stub return `context.Canceled` as
  its error. What is actually tested is that a supervisor error on the first
  supervisor call produces `(nil, error)`. The contract being asserted is correct;
  the comment misleads a reader about what execution path is driven.
- Severity: LOW
- Action: Revise the comment to: "when the supervisor returns context.Canceled,
  RunAgent must return (nil, error) — callers must never receive a partial Result
  alongside an error."

### Notes on freshness samples
`internal/coder/prerun/prerun_test.go`, `internal/coder/scout/parity_test.go`, and
`internal/coder/scout/scout_test.go` were not modified in this run. All three use
purpose-built fakes (`recordingDeps`, `scoutFake`) or static fixture files in temp
directories; none read mutable pipeline artifacts. No integrity issues found.
