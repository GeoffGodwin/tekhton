## Test Audit Report

### Audit Summary
Tests audited: 3 files, 20 test functions  
Files: internal/provider/cost_test.go (9 tests), internal/runner/budget_test.go (9 tests + 2 helpers), tests/test_budget_enforcement.sh (10 checks)  
Verdict: NEEDS_WORK

---

### Findings

#### EXERCISE: fakeBudgetPipeline does not satisfy runner.Pipeline — compile error
- File: internal/runner/budget_test.go:212
- Issue: `fakeBudgetPipeline.RunAttempt` is declared as `func (_ context.Context, _ interface{}) (interface{}, error)`. The actual `runner.Pipeline` interface (runner.go:68) requires `RunAttempt(ctx context.Context, req *proto.PipelineAttemptRequestV1) (*proto.PipelineAttemptResultV1, error)`. Go will reject the assignment `runner.New(fakePipeline)` at compile time because the concrete type does not satisfy the interface. No test in `TestRunner_StageBudgetEnforced`, `TestRunner_RunBudgetEnforced`, or `TestRunner_SubscriptionBudgetNotConsumed` will compile or run until the signature is corrected.
- Severity: HIGH
- Action: Change `fakeBudgetPipeline.RunAttempt` to match the interface: `func (f *fakeBudgetPipeline) RunAttempt(_ context.Context, _ *proto.PipelineAttemptRequestV1) (*proto.PipelineAttemptResultV1, error)`. Import `github.com/geoffgodwin/tekhton/internal/proto`. Return `nil, nil` for the success case and `nil, nil` for the subscription case.

#### EXERCISE: minimalMilestoneRequest returns interface{} — type mismatch prevents compilation
- File: internal/runner/budget_test.go:219–224
- Issue: `minimalMilestoneRequest` has return type `interface{}` and the inline comment claims this "so the test file compiles against the runner package shape." This is backwards: `RunSingle` is declared as `RunSingle(ctx context.Context, req *proto.RunRequestV1)` (single.go:21). Passing an `interface{}` value where `*proto.RunRequestV1` is required is a compile-time error in Go. The return type must be `*proto.RunRequestV1`. Additionally, returning `nil` means `validateAndDefault` immediately returns `ErrInvalidRequest` (runner.go:208–210), so the test never reaches any budget enforcement path — it would fail for the wrong reason.
- Severity: HIGH
- Action: Change the return type to `*proto.RunRequestV1` and construct a minimal valid request: at minimum `&proto.RunRequestV1{Task: "test", ProjectDir: t.TempDir()}` with `Mode` set to whatever `RunRequestV1.Validate()` accepts. Verify `validateAndDefault` succeeds on this fixture so execution reaches the budget pre-check.

#### EXERCISE: Budget enforcement tests bypass the code under test
- File: internal/runner/budget_test.go:130–191
- Issue: Even if the two compile errors above were fixed, the budget enforcement tests (`TestRunner_StageBudgetEnforced`, `TestRunner_RunBudgetEnforced`, `TestRunner_SubscriptionBudgetNotConsumed`) still cannot exercise budget logic because: (a) `fakeBudgetPipeline.RunAttempt` returns `(nil, nil)` — it does not populate a `*proto.PipelineAttemptResultV1` with cost metadata, and (b) the runner's budget pre-check (which doesn't exist yet in `runner.go`) is expected to fire *before* calling `Pipeline.RunAttempt`. A fake that always returns nil conveys no cost signal for the post-call accounting path either. The tests assert on `BUDGET_EXCEEDED` but the fake never produces a result that could trigger it. The permissive assertion structure (`if err == nil && result != nil { ... } else if err != nil { ... }`) means a nil result from `RunSingle` silently falls through without failing — a test that can only prove the run produced no result, not that the budget was enforced.
- Severity: HIGH
- Action: Redesign the enforcement tests. The runner needs a pre-flight budget hook (not yet implemented for m14). Until that hook exists, these tests cannot be meaningful. Option A: add a minimal `RunSingle` integration test that wires a real `RunCostAggregator` with a pre-charged `PerStage` map and asserts `BUDGET_EXCEEDED` is returned before `Pipeline.RunAttempt` is called — use a fake that records whether it was called and fail the test if it was. Option B: unit-test the budget check as a standalone function (`WouldExceedBudget` or similar) without going through `RunSingle` at all (the `WouldExceedStageBudget` tests below already do this correctly). Either way, remove the vacuous nil-result fallthrough from the assertions.

#### SCOPE: Shell test A2 and Go test disagree on which package owns RunCostAggregator
- File: tests/test_budget_enforcement.sh:43–51 vs internal/runner/budget_test.go:7–8
- Issue: Shell test A2 checks for `internal/provider/cost_aggregator.go` and greps for `RunCostAggregator`. The Go test imports `RunCostAggregator` from `github.com/geoffgodwin/tekhton/internal/runner` (budget_test.go:8: `"github.com/geoffgodwin/tekhton/internal/runner"`). After m14 implementation, the struct will live in exactly one of those two packages. Whichever location the implementation chooses, one of these two checks will fail permanently. If `RunCostAggregator` lives in the runner package (as the Go test implies), A2 will always report failure even on a correct implementation.
- Severity: MEDIUM
- Action: Decide the canonical package location for `RunCostAggregator` before implementation. If it lives in `internal/runner/`, update A2 to check `internal/runner/budget.go` (or whichever file it lands in) and grep for `RunCostAggregator` there. If it lives in `internal/provider/`, update the Go test import accordingly.

#### COVERAGE: Shell test A3 silently misreports python3-not-found as a JSON key error
- File: tests/test_budget_enforcement.sh:55–63
- Issue: A3 uses `python3 -c "..."` with `2>/dev/null` to validate `costrates.json`. If `python3` is not on `PATH`, the command exits non-zero, stderr is suppressed, and the failure message is "costrates.json exists but is missing required tier keys or is invalid JSON" — a misleading diagnosis. Python 3 is documented as optional in CLAUDE.md; a developer running this test without Python 3 installed gets a confusing false failure.
- Severity: MEDIUM
- Action: Add a `python3` availability guard before A3: `if ! command -v python3 >/dev/null 2>&1; then echo "SKIP: A3 (python3 not found — install python3 to validate JSON keys)"; else <existing check>; fi`. Alternatively, replace the Python call with `jq` if available, or use a pure-bash JSON key grep as a fallback.

#### SCOPE: cost_test.go references provider.Result.TokenUsage which does not exist
- File: internal/provider/cost_test.go:26–27, 41–42, 61–62, 80–82 (and others)
- Issue: All cost tests assign `res.TokenUsage.InputTokens` and `res.TokenUsage.OutputTokens`. The current `provider.Result` struct (provider.go:166–180) has no `TokenUsage` field. These tests will not compile until m14 adds `TokenUsage` to `Result`. This is expected TDD, but the nested struct accessor shape (`res.TokenUsage.InputTokens`) constrains the implementation: it must be a named field of struct type, not a flat `InputTokens int64` on `Result` directly. If the implementation ships `Result.InputTokens` and `Result.OutputTokens` as top-level fields instead, these tests will need updating.
- Severity: LOW
- Action: The m14 implementation should add `TokenUsage` as a nested struct to `provider.Result` matching the accessor pattern in the tests. No test change needed if the implementation matches; flag this during code review of the m14 implementation.

---

### Notes (no action required)

**Assertion honesty — cost_test.go:** The 1800-cent expected value in `TestDefaultEstimator_ClaudeAPIRate` is honestly derived from the rate table written by `writeDefaultRates` (300 input/1M + 1500 output/1M applied to 1M+1M tokens). Similarly, the 1000-cent value in `TestDefaultEstimator_CodexAPIRate` is derived from 200+800. The 300-cent value in `TestCostRatesEnvOverride` is derived from the custom rates map constructed inline (100+200). No magic constants.

**Assertion honesty — budget_test.go:** The aggregator tests (`TestRunCostAggregator_*` and `TestWouldExceedStageBudget_*`) are well-structured. The `fixedEstimator` stub always returns a configured constant, and test assertions match that constant exactly. Boundary tests correctly pin the exact-equal case (`100+100=200 >= 200 → exceeds`) which is the most common off-by-one mistake in budget code. These tests are sound in isolation; the problem is only with the three enforcement tests that exercise `RunSingle`.

**Weakening check:** These are all newly written tests. No existing test was modified or weakened. Rubric 4 does not apply.

**Test isolation — cost_test.go:** All rate-dependent tests write a controlled `costrates.json` to `t.TempDir()` and set `TEKHTON_COST_RATES_FILE` via `t.Setenv`. `TestDefaultRatesFile_ParsesCleanly` reads `costrates.json` directly from the package directory (a committed static file, not a run artifact) — acceptable, not a run artifact per the isolation rubric.

**Naming:** All test names are descriptive and encode both the scenario and expected outcome (e.g., `TestWouldExceedStageBudget_ExactBoundary`, `TestDefaultEstimator_UnknownRateIsZero`). No naming issues.

**Freshness sample (not under audit):** `cmd/tekhton/crawler_test.go` and `internal/crawler/*_test.go` were not modified this run and are excluded from findings per audit rules.
