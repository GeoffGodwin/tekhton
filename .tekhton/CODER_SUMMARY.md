# Coder Summary — m08 Quota Pause/Resume + Retry-After Parsing

## Status: COMPLETE

## What Was Implemented

### `internal/proto/agent_v1.go` (modified — additive)

- New optional `RetryAfter string` field on `AgentResultV1`. Carries the
  upstream Retry-After header verbatim (integer seconds OR HTTP-Date) so
  the retry envelope can drive a quota pause without re-parsing claude
  stderr. Additive only — proto major stays v1, existing consumers are
  unaffected.

### `internal/supervisor/quota.go` (NEW, 190 lines)

- `QuotaPause` struct: `Until`, `Reason`, `ChunkSize`, `MaxDuration`, plus
  unexported `clock` and `sleep` test seams so chunked-sleep behavior is
  verifiable without real time.
- `Supervisor.EnterQuotaPause(ctx, p)`: chunked select-sleep that wakes
  every `ChunkSize` (default 5s, max 60s) to emit a `quota_tick` causal
  event and re-evaluate ctx. Returns nil on natural release,
  `ctx.Err()` on cancellation, or `ErrQuotaPauseCapped` when MaxDuration
  fires before Until (default 5h15m).
- `ParseRetryAfter(string) (time.Time, bool)`: integer seconds via
  `strconv.Atoi`; falls back to `http.ParseTime` for RFC1123 / RFC850 /
  asctime. Empty / negative / unparseable returns `(zero, false)`.
- `ErrQuotaPauseCapped` sentinel exported so callers can `errors.Is` on
  the cap path without string matching.
- Causal events emitted: `quota_pause` (entry), `quota_tick` (per chunk),
  `quota_resume` (exit), `quota_pause_capped` (cap fired). All on the
  `supervisor` stage with `<reason>\t<detail>` body convention so bash
  consumers parse them like any other supervisor event.

### `internal/supervisor/quota_probe.go` (NEW, 293 lines)

- `ProbeKind` enum (`ProbeVersion` / `ProbeZeroTurn` / `ProbeFallback`)
  with `String()` rendering matching V3 names (`version`, `zero_turn`,
  `fallback`). The cheapest probe (Version) is the default; Fallback
  consumes API quota and is meant only as last resort.
- `ProbeResult` enum (`ProbeQuotaActive` / `ProbeQuotaLifted` /
  `ProbeError`).
- `Supervisor.Probe(ctx, kind) ProbeResult`: thin wrapper over the
  unexported `probe(ctx, kind, runner)` workhorse so tests inject a
  scripted `probeRunner`.
- `runProbeCommand`: production exec path. Argument shapes mirror
  `lib/quota_probe.sh _quota_probe` so V3↔Go behavior is observably
  identical at the CLI seam.
- `isRateLimitStderr`: case-insensitive scan for the V3 marker vocabulary
  (`rate limit`, `rate-limit`, `rate_limit`, `quota exceed`,
  `usage limit`, `too many requests`, `429`, `capacity`, `overloaded`).
- `ProbeSchedule` with `MinInterval` / `MaxInterval` / `rng` seam.
  `DefaultProbeSchedule` returns the V3 floor/ceiling (10m/30m).
  `NextDelay(probeNum, prevDelay)`: 10m floor, 1.5× back-off, 30m cap,
  ±10% jitter. The 1.5× math is `*3/2` integer ns (matches bash exactly).

### `internal/supervisor/retry.go` (modified, +70 lines)

- New `pauseFunc` type alongside the existing `runFunc`.
- `Supervisor.Retry` now passes `s.EnterQuotaPause` as the pause seam.
- `retryLoop` gained a `pause pauseFunc` parameter. When the inner
  classification matches `ErrUpstreamRateLimit` or `ErrQuotaExhausted`
  AND a pause helper is wired, the loop:
    1. Reads `result.RetryAfter`, parses via `ParseRetryAfter`.
    2. Falls back to a 15-minute conservative default when missing/bad.
    3. Calls the pause helper.
    4. Re-runs the agent **without consuming a retry attempt**
       (matches V3 quota arc).
- Inner pause loop drains successive 429s as a single retry attempt; an
  attempt only consumes budget once the run produces a non-quota-pause
  result.
- New helpers `shouldQuotaPause(cls)` and `handleQuotaPause(ctx, log,
  pause, result, label)` keep the policy decision and pause dispatch
  small and unit-testable.
- `pause` may be nil — backwards-compatible with existing tests that
  pass `nil` for the pre-m08 path.
- New causal event: `retry_quota_pause` with detail
  `until=<RFC3339> source=<header|default>` so dashboards can render
  the pause cause.

### `cmd/tekhton/quota.go` (NEW, 244 lines)

- `tekhton quota status [--path P] [--json]`: walks the causal log,
  finds the most recent `quota_pause` / `quota_resume` event pair, and
  prints `paused: <reason>` or `active`. `--json` mode emits a stable
  envelope (`paused`, `reason`, `last_event_id`, `last_event_type`,
  `last_detail`).
- `tekhton quota probe [--kind version|zero-turn|fallback] [--timeout]`:
  runs one probe and prints `active`/`lifted`/`error`. Returns
  exit 70 on probe error so wrapper scripts can branch.
- `parseProbeKind` accepts both dash (`zero-turn`) and underscore
  (`zero_turn`) forms — V3 operator scripts use both.
- Wired into `cmd/tekhton/main.go` via `cmd.AddCommand(newQuotaCmd())`.

### `internal/supervisor/quota_test.go` (NEW, 481 lines)

22 tests covering:

- `EnterQuotaPause`: natural release with tick events; ctx cancel mid-pause
  returns `context.Canceled`; MaxDuration cap fires `ErrQuotaPauseCapped`
  with the `quota_pause_capped` causal event; Until-in-past is a no-op
  pause/resume pair; defaults applied when `ChunkSize=0`.
- `ParseRetryAfter`: integer seconds resolves to `now+N`;
  `http.ParseTime` resolves an RFC1123 string; garbage / empty / negative
  returns `(zero, false)`.
- `Probe` (via fake runner): exit-0 → Lifted; rate-limit stderr
  (4 V3 marker variants) → Active; runner error → Error;
  unrecognized nonzero exit → Error (conservative); causal event emitted
  with `kind=` and `exit=` fields.
- `Probe` public wrapper exercises `runProbeCommand` against a missing
  binary so the production-only seam has coverage.
- `ProbeSchedule.NextDelay`: first delay = MinInterval; 1.5× back-off
  step-by-step (10m → 15m → 22m30s → cap at 30m); ±10% jitter band
  (rng=0/10/20 → 90/100/110%).
- `isRateLimitStderr`: detects each V3 vocabulary marker including
  case-insensitive matches; rejects unrelated stderr.
- `ProbeKind.String` and `ProbeResult.String` cover each enum + unknown
  fallback.

### `internal/supervisor/retry_test.go` (modified, +5 tests)

- `TestRetry_RateLimit_TriggersPauseThenSucceeds` — 429-then-200
  sequence: one runner call to rate-limit, one pause call, one runner
  call to success; retry_quota_pause causal event present.
- `TestRetry_RateLimit_DoesNotConsumeRetryAttempt` — three rate-limited
  results then success: 4 runner calls, 3 pause calls, all within
  MaxAttempts=3 (the AC: pauses are "free" from the policy counter).
- `TestRetry_RateLimit_NoRetryAfterUsesDefault` — empty `result.RetryAfter`
  falls back to 15m default; `source=default` recorded in causal log.
- `TestRetry_RateLimit_PauseErrorAbortsRun` — pause helper returning
  `ErrQuotaPauseCapped` ends the run with that error; `errors.Is` matches.
- `TestRetry_RateLimit_NilPauseFallsBackToBackoff` — nil pause helper
  uses ordinary exponential backoff (backwards compat).
- All 12 existing `retryLoop` test invocations updated to pass `nil` for
  the new `pause pauseFunc` parameter — pre-m08 behavior preserved.

### `cmd/tekhton/quota_test.go` (NEW, 142 lines)

6 tests covering: empty log → "active"; quota_pause without resume →
"paused: <reason>"; pause-then-resume → "active"; --json envelope round-
trips; probe rejects bogus --kind; parseProbeKind accepts both dash and
underscore variants of zero-turn.

## Acceptance Criteria Verification

- [x] `EnterQuotaPause` with `Until: now+10s` returns within 10s without
      error; emits entry, ≥1 tick, exit causal events
      → `TestEnterQuotaPause_NaturalRelease`.
- [x] `EnterQuotaPause` with `ctx.Cancel()` mid-pause returns
      `context.Canceled` within `ChunkSize`
      → `TestEnterQuotaPause_CtxCancelMidPause_ReturnsCtxErr`.
- [x] `EnterQuotaPause` with `Until: now+1y` returns after `MaxDuration`
      with a `quota_pause_capped` causal event
      → `TestEnterQuotaPause_MaxDurationCap`.
- [x] `ParseRetryAfter("60")` returns `now+60s`;
      `ParseRetryAfter("Wed, 21 Oct 2026 …")` returns the parsed time;
      `ParseRetryAfter("garbage")` returns `(zero, false)`
      → `TestParseRetryAfter_*` (3 tests).
- [x] `Probe(ctx, ProbeVersion)` against an exit-0 mock returns
      `ProbeQuotaLifted`; against a 429-stderr mock returns
      `ProbeQuotaActive`
      → `TestProbe_QuotaLifted_OnZeroExit`,
      `TestProbe_QuotaActive_OnRateLimitStderr`.
- [x] Probe back-off: first probe at min interval; subsequent probes at
      1.5× up to max; time-mocked test asserts the schedule
      → `TestProbeSchedule_BackoffGrowsBy3Halves`.
- [x] `Retry` with a 429-then-200 mock sequence: enters quota pause,
      emits expected causal events, returns success on the post-pause
      attempt without consuming a retry slot
      → `TestRetry_RateLimit_TriggersPauseThenSucceeds`,
      `TestRetry_RateLimit_DoesNotConsumeRetryAttempt`.
- [x] `tekhton quota status` reads the live causal log and reports
      paused: true during a pause; paused: false after
      → `TestQuotaStatusCmd_*` (4 tests including --json round-trip).
- [x] Coverage for `internal/supervisor` ≥ 78% — actual **92.0%**.
- [x] m01–m07 acceptance criteria still pass — `go test ./internal/...`
      passes; bash supervisor unchanged; self-host check still passes.

## Architecture Decisions

- **`RetryAfter` lives on `AgentResultV1` (not a new `Fields` map).**
  The milestone description sketched a `result.Fields["retry_after"]`
  shape, but `AgentResultV1` doesn't have a Fields map. Adding a map for
  one optional value would have been over-engineering and changed the
  proto envelope shape. A typed `RetryAfter string` field is additive
  (proto comment explicitly allows additive changes), discoverable, and
  matches the existing `ErrorMessage` / `ErrorCategory` neighbors.
- **`pause` is an explicit dependency, nil-tolerant.** `retryLoop`
  accepts `pauseFunc` as a positional arg; production passes
  `s.EnterQuotaPause`, tests pass either a fake or `nil`. The nil
  tolerance preserves the pre-m08 retry behavior for callers that have
  not wired a pause helper — important because the m08 design says
  bash production stays in `lib/quota.sh` until m10.
- **Inner pause-drain loop, not `attempt--`.** Quota pauses do not
  consume retry attempts — V3 behavior. Implemented as an inner `for`
  inside the outer attempt loop rather than the `attempt--; continue`
  trick, because the inner-loop pattern is uncontroversial across Go
  linters.
- **`*3/2` integer ns for 1.5× back-off.** Matches the bash version
  byte-for-byte. Avoids float drift between V3 and Go probe schedules
  during the m10 parity test.
- **Sentinel quota-pause-capped vs string match.** `ErrQuotaPauseCapped`
  is exported as a sentinel error; consumer code uses `errors.Is`.
  Same idiom as `ErrUpstreamRateLimit` etc. from m07.
- **Probe runner indirection.** `Probe` calls `probe(ctx, kind,
  runProbeCommand)`; tests pass scripted `probeRunner`s into the
  unexported `probe` to avoid shelling out. Same shape as `Retry` /
  `retryLoop` in m07 — keeps the test pattern consistent across the
  package.

## Files Modified

- `internal/proto/agent_v1.go` — added `RetryAfter` field
- `internal/supervisor/quota.go` (NEW)
- `internal/supervisor/quota_probe.go` (NEW)
- `internal/supervisor/retry.go` — pause integration (`pauseFunc`,
  inner loop, `shouldQuotaPause`, `handleQuotaPause`)
- `internal/supervisor/quota_test.go` (NEW)
- `internal/supervisor/retry_test.go` — 5 new pause tests; 12 existing
  retryLoop calls updated for new signature
- `cmd/tekhton/quota.go` (NEW)
- `cmd/tekhton/quota_test.go` (NEW)
- `cmd/tekhton/main.go` — `cmd.AddCommand(newQuotaCmd())`

`lib/quota.sh`, `lib/quota_sleep.sh`, `lib/quota_probe.sh`,
`lib/agent_retry_pause.sh` are intentionally NOT touched. m08 design
explicitly says bash production stays on `lib/quota.sh` until m10's
parity test gates the cut-over (CLAUDE.md Rule 9 cleanup deferred to
m10 by design).

## Test Suite Results

- `go fmt ./...` — clean.
- `go vet ./...` — clean.
- `go build ./...` — clean.
- `go test -count=1 ./...` — passes.
- `go test -race -count=2 ./internal/supervisor/...` — passes (no
  races, no flakes).
- `go test -cover ./internal/supervisor/...` — **92.0%** coverage
  (AC requires ≥78%).
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean.
- `bash tests/run_tests.sh` — **PASS**: shell 501/501, Python
  250 passed (14 skipped), Go all packages pass, exit 0. The
  pre-existing `test_run_op_lifecycle.sh` and `test_tui_stop_orphan_recovery.sh`
  flakes that the m07 reviewer noted both passed deterministically in
  this run.
- `golangci-lint` — not installed in this build environment; `go vet`
  + manual review of the new files (no globals beyond the documented
  sentinel pattern, errors typed via `errors.Is`/`errors.As`,
  ctx-first parameter ordering, no `init()` side effects, no
  string-parsed errors) covers the rules golangci would enforce
  per CLAUDE.md Rule 3.

## Human Notes Status

No human notes listed in the task input.

## Docs Updated

None — no public-surface changes that require user-facing documentation.

The new APIs (`Supervisor.EnterQuotaPause`, `Supervisor.Probe`,
`QuotaPause`, `ParseRetryAfter`, `ProbeKind`, `ProbeResult`,
`ProbeSchedule`, `ErrQuotaPauseCapped`) are all under
`internal/supervisor` — not callable outside the module.

The `tekhton quota` CLI is exposed by the Go binary, but per m08 design
("Hold. The Go quota path can be exercised against a mock claude binary
… production quota handling stays in bash until m10") the binary is not
yet in any documented user workflow. m10 is responsible for the
user-facing documentation update when the bash→Go shim flips.

The new `RetryAfter` field on `AgentResultV1` is additive proto v1 —
omitempty JSON tag means existing consumers see no change.

## Observed Issues (out of scope)

- **m07 reviewer non-blocking findings (`retry.go:195` dead return,
  `retry.go:57-58` undocumented zero-delay guard)** are still present.
  Per the task instructions ("Scope your work strictly to the task
  description above … do not expand scope beyond what was requested"),
  these were not fixed in m08 — they are pre-existing items the m07
  reviewer recorded as non-blocking notes. Listing them here so the
  cleanup mechanism can pick them up.
