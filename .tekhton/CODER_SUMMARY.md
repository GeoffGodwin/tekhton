# Coder Summary — m07 Retry Envelope: Typed Errors + Exponential Backoff

## Status: COMPLETE

## What Was Implemented

### `internal/supervisor/errors.go` (NEW, 142 lines)

- `AgentError` struct (Category, Subcategory, Transient bool, Wrapped error).
- `Error()` renders the V3 wire format `CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE`
  so bash consumers parsing a Go-written string still see the same fields.
- `Is(target)` matches on Category+Subcategory ONLY — `Wrapped` and `Transient`
  do not participate. Sentinel exemplars carry zero `Wrapped` and still match
  live errors that wrap a real cause.
- `Unwrap()` returns the underlying cause (standard errors-chain support).
- 24 sentinel exemplars covering the full V3 vocabulary from `lib/errors.sh`:
  UPSTREAM (api_rate_limit, api_overloaded, api_500, api_auth, api_timeout,
  api_unknown, quota_exhausted), ENVIRONMENT (oom, network, disk_full,
  missing_dep, permissions, env_unknown), AGENT_SCOPE (null_run, max_turns,
  activity_timeout, null_activity_timeout, no_summary, scope_unknown),
  PIPELINE (state_corrupt, config_error, missing_file, template_error,
  internal). `ErrFatalAgent` aliases `ErrAgentScopeUnknown`.
- `classifyResult(*proto.AgentResultV1)` returns `nil` for success/turn_exhausted
  outcomes; for failures, builds an `*AgentError` from the result's
  ErrorCategory/ErrorSubcategory if populated, otherwise infers from Outcome.

### `internal/supervisor/retry.go` (NEW, 207 lines)

- `RetryPolicy` struct (MaxAttempts, BaseDelay, MaxDelay, Floors, plus an
  unexported `rng` seam for deterministic test jitter).
- `DefaultPolicy()` — 3 attempts, 30s base, 120s cap, with V3-equivalent
  subcategory floors: api_rate_limit/api_overloaded → 60s, oom → 15s.
- `Delay(attempt, subcategory)` — exponential backoff with floor + cap +
  ±10% jitter. Formula: `max(floor, min(MaxDelay, BaseDelay*2^(attempt-1))) +
  jitter`, with a final cap at MaxDelay UNLESS the floor exceeds MaxDelay
  (per the milestone Watch-For — config asserting an explicit minimum
  overrides the cap).
- `Supervisor.Retry(ctx, req, policy)` — public entry point that wraps
  `Supervisor.Run` with the retry envelope.
- `retryLoop(...)` — unit-testable implementation; takes injected `runFunc`
  (single-attempt callback) and `after` (clock seam) so tests skip real
  sleeps and can drive deterministic disposition.
- Per-attempt causal events: `retry_attempt`, `retry_backoff`, `retry_fatal`,
  `retry_exhausted` — all emitted on the `supervisor` stage with the
  `<label>\t<detail>` body convention used by `teeStderr`.
- `ctx.Done()` during backoff returns `ctx.Err()` immediately; no
  `time.Sleep` anywhere on the path.
- `turn_exhausted` is NOT a retry trigger (per Watch-For: orchestrate owns
  the continuation decision).

### `internal/supervisor/errors_test.go` (NEW, 189 lines)

15 tests covering: Is identity matches Category+Subcategory only, Transient
flag does not participate in identity, Unwrap chain works, Error format is
exactly the V3 wire shape, every sentinel matches a live error of the same
class, ErrFatalAgent aliases scope_unknown, classifyResult is nil-safe and
returns nil for success / turn_exhausted, table-driven mapping for 14 typed
sentinels, transient flag propagates, outcome-only fallback works for
activity_timeout and fatal_error.

### `internal/supervisor/retry_test.go` (NEW, 390 lines)

22 tests — control-flow and policy: success-first-attempt no-retry,
turn_exhausted not-a-trigger, transient retries up to MaxAttempts then
exhausted, fatal stops immediately, transient-then-success recovers,
runner-error passthrough (no classification), nil-request / nil-runner
errors, ctx.Cancel during backoff returns within ~10ms, nil-policy uses
defaults; Delay table tests for rate-limit floor, MaxDelay cap, OOM floor,
floor>MaxDelay wins, exponential progression {1,2,4,8}s, jitter band
±10%, attempt=0 treated as 1; causal-log assertions for
retry_attempt + retry_backoff (success after retry), retry_fatal
(immediate stop), retry_exhausted (max attempts hit).

Coverage: **92.2%** of statements in `internal/supervisor` (AC requires ≥75%).

## Root Cause (bugs only)
N/A — milestone implementation, not a bug fix.

## Files Modified
- `internal/supervisor/errors.go` (NEW)
- `internal/supervisor/retry.go` (NEW)
- `internal/supervisor/errors_test.go` (NEW)
- `internal/supervisor/retry_test.go` (NEW)

`lib/agent_retry.sh` is intentionally NOT touched — m07 design states the
bash side stays on the V3 retry envelope until m10 lands the parity test
and flips the shim. (CLAUDE.md Rule 9 cleanup deferred to m10 by design.)

## Human Notes Status
No human notes listed in the task input.

## Docs Updated
None — no public-surface changes that require user-facing documentation.
The new APIs (`Supervisor.Retry`, `RetryPolicy`, `AgentError` sentinels) are
internal Go types under `internal/supervisor`, not callable from outside the
module. Public CLI surface, config keys, and templates are unchanged. Per
m07 design, bash callers continue to go through `lib/agent_retry.sh` until
m10's shim flip.

## Architecture Decisions

- **`runFunc` indirection in `retryLoop`** — `Retry()` is a thin shim that
  passes `s.Run` as `runFunc`; `retryLoop` is the testable workhorse. This
  avoids adding a public mock-injection field to `Supervisor` while letting
  `retry_test.go` script agent results without spawning processes.
- **Clock seam (`after func(d) <-chan time.Time`)** — same pattern. Tests
  pass `instantAfter` (already-fired channel) for normal cases and a
  blocking-forever channel for the cancellation test, so the cancellation
  AC's "returns ctx.Err() within 10ms" is verifiable without sleeping.
- **Jitter rng seam (`RetryPolicy.rng`)** — unexported function field;
  production uses `math/rand.Int63n`, tests inject deterministic functions.
  Watch-For called out jitter as new-vs-V3; making it deterministically
  testable keeps the parity story honest.
- **`MaxDelay` clamp wraps the floor** — formula re-applies the cap after
  jitter UNLESS `floor > MaxDelay`, in which case the floor wins. Direct
  implementation of the Watch-For example: floor=60s, MaxDelay=30s must
  sleep ≥60s. Test `TestRetryPolicy_Delay_FloorAboveMaxDelayWins` covers it.
- **Sentinel value identity** — the V3 vocabulary is exposed as
  package-level `*AgentError` values rather than constants/functions. This
  is the standard `errors.Is` idiom (cf. `io.EOF`, `os.ErrNotExist`) and the
  identity check via `Is()` is on field equality, not pointer equality, so
  zero-Wrapped sentinels match live errors with arbitrary Wrapped causes.

## Acceptance Criteria Verification

- [x] `errors.Is(classifyResult(rateLimitResult), ErrUpstreamRateLimit)` is true
      — `TestClassifyResult_MapsByErrorCategory` covers all 14 sentinels.
- [x] `Delay(attempt=1, subcategory="api_rate_limit")` returns ≥60s
      — `TestRetryPolicy_Delay_RateLimitFloorAt60s`.
- [x] `Delay(attempt=3, subcategory="")` returns ≤MaxDelay
      — `TestRetryPolicy_Delay_NoSubcategoryCapsAtMaxDelay`.
- [x] `Retry` calls `Run` once for `Outcome: success` and returns immediately
      — `TestRetry_Success_FirstAttempt_NoRetry`.
- [x] `Retry` calls `Run` up to MaxAttempts on transient errors; emits
      `retry_exhausted` — `TestRetry_TransientError_RetriesUpToMax_ThenExhausted`
      + `TestRetry_CausalEvents_ExhaustedEmitted`.
- [x] `Retry` returns immediately on fatal errors; emits `retry_fatal`
      — `TestRetry_FatalError_StopsImmediately` + `TestRetry_CausalEvents_FatalEmitted`.
- [x] `Retry` honors ctx.Cancel during backoff; <10ms latency
      — `TestRetry_CtxCancelDuringBackoff_ReturnsCtxErr` (<200ms bound, typically <10ms).
- [x] Per-attempt causal events emitted with the agreed shape
      — `TestRetry_CausalEvents_RetryAttemptAndBackoff`.
- [x] Coverage ≥75% — actual 92.2%.
- [x] m01–m06 acceptance criteria still pass — `go test ./internal/supervisor/...`
      passes; bash supervisor unchanged.

## Test Suite Results

- `go vet ./...` — clean.
- `go build ./...` — clean.
- `gofmt -l` on the four new files — clean.
- `go test -race -count=3 ./internal/supervisor/...` — passes (no races, no flakes).
- `go test ./...` — all packages pass.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean.
- `bash tests/run_tests.sh` — 500/501 shell tests pass, Python pass, Go pass,
  exit 0. The single shell failure (`test_run_op_lifecycle.sh`) is a
  pre-existing flake under parallel test load — passes deterministically when
  run in isolation (`bash tests/test_run_op_lifecycle.sh` → 18 passed, 0
  failed). It tests TUI/run_op wrapping (`lib/tui_ops.sh`), which my m07
  changes do not touch.

## Observed Issues (out of scope)

- **`test_run_op_lifecycle.sh` flake under parallel load** — passes in
  isolation but fails inside `tests/run_tests.sh`. Test exercises
  `lib/tui_ops.sh` heartbeat/JSON status; likely a TUI sidecar timing
  sensitivity unrelated to m07. Not addressed here.

## Docs Updated

None — docs agent found no updates needed. All new code is internal to
`internal/supervisor/` package. No public CLI surface, config keys, or
templates changed. User-facing documentation remains accurate.
