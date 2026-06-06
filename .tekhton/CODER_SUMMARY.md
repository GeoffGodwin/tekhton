# Coder Summary

## Status: COMPLETE

## What Was Implemented

m45 — Completion Gate: stop false-halting on transient TEST_CMD failure
after a large coder refactor. Five Goals, all landed.

### Goal 1 — Grace window before the first TEST_CMD invocation

`internal/gates/completion.go::CompletionGate.Run` now sleeps for
`GraceSecs` and calls `bestEffortSync()` before invoking `runner.Run`
for the first time. The sleep uses the canonical cancel-friendly
`select { case <-time.After(d): case <-ctx.Done(): return ctx.Err() }`
form, so a parent context cancel aborts inside the grace window
without waiting it out. `bestEffortSync()` is the build-tagged
`syscall.Sync` wrapper — Unix variant in
`internal/gates/completion_sync_unix.go`, no-op stub in
`internal/gates/completion_sync_windows.go`. Default 3s via the new
`COMPLETION_GATE_GRACE_SECS` env key, clamped 0–60 at the CLI seam.

### Goal 2 — One-retry policy on the no-baseline failure path

`runTestCmd` now falls through to a `RetryOnNoBaseline` branch when
the no-baseline path returns a non-zero exit. The retry sleeps
`RetryDelay`, calls `runner.Run` once more, and on
(retryErr == nil && retryExitCode == 0) it:

1. Emits a `completion_gate_flake` causal event via the pluggable
   `Causal` field (CausalEmitter interface), with the documented
   fields `first_exit`, `retry_exit`, `test_cmd`, `milestone`.
2. Logs `Completion gate: first TEST_CMD flaked (exit=N), retry
   passed. Proceeding.` so the operator sees what happened.
3. Calls `Dedup.RecordPass()` if a Dedup hook is wired.
4. Returns nil — the gate proceeds.

On retry failure the captured stream becomes the dump-file payload
(so operators see the second attempt's diagnostics) and the gate
falls through to the original halt path returning
`ErrCompletionTestFailed`.

The retry is intentionally NOT applied to the have-baseline branch
per the milestone's Watch For directive — when a baseline exists,
the baseline-compare path already filters pre-existing failures, so
a non-zero exit there is novel breakage and should halt
immediately. `TestCompletionGate_RetrySkippedWhenBaselineExists`
locks this in.

Defaults: `COMPLETION_GATE_RETRY_NO_BASELINE=true`,
`COMPLETION_GATE_RETRY_DELAY_SECS=5` (clamped 0–60).

### Goal 3 — Env contract additions

- `internal/config/defaults.go` gains three entries grouped with
  `COMPLETION_GATE_TEST_ENABLED`. Order chosen so resume seeding
  remains deterministic.
- `internal/config/sections.go` — the existing
  "Test Gate, Audit, Baseline" `SectionRule` swapped its narrow
  `matchExact("COMPLETION_GATE_TEST_ENABLED")` for a
  `hasPrefix("COMPLETION_GATE")` arm so all current and future
  COMPLETION_GATE_* keys cluster together in `pipeline.conf.example`
  without needing per-key bookkeeping.
- `cmd/tekhton/gate.go::completionGateFromEnv` reads the new keys
  through `envSeconds`/`envBool` helpers, clamps the duration values
  to [0s, 60s] via a new `clampSeconds()` helper, and wires a
  `gates.CausalFunc` adapter that exec's
  `internal/causal.Log` to write the actual `completion_gate_flake`
  JSONL line.

### Goal 4 — Tests

`internal/gates/completion_test.go` gains six new cases:

1. `TestCompletionGate_NoBaselineFirstFailsRetryPasses` — happy
   path: sequenceRunner returns `{exit:1,out:FAIL}` then
   `{exit:0,out:OK}`; asserts nil error, `Dedup.RecordPass` called,
   `fakeCausalEmitter` received exactly one event with the four
   documented fields populated correctly.
2. `TestCompletionGate_NoBaselineBothFail` — pessimistic path:
   sequenceRunner returns exit=1 twice; asserts
   `ErrCompletionTestFailed`, two runner calls, zero causal events.
3. `TestCompletionGate_GracePeriodRespectsContextCancel` — sets
   `GraceSecs:10s`, cancels ctx after 50ms; asserts
   `context.Canceled`, total wall-clock under 5s, zero runner calls.
4. `TestCompletionGate_RetryDelayRespectsContextCancel` — same idea
   but for the retry-delay sleep; asserts one runner call (initial
   only) and ctx cancel beats the 10s delay.
5. `TestCompletionGate_RetryDisabledHaltsImmediately` — proves the
   opt-out: `RetryOnNoBaseline:false` reverts to pre-m45 behavior
   (one runner call, immediate halt).
6. `TestCompletionGate_RetrySkippedWhenBaselineExists` — proves the
   design invariant: the retry doesn't fire on the have-baseline
   branch even when `RetryOnNoBaseline:true`.

`fakeCausalEmitter` (new) implements `CausalEmitter` and records
each call's eventType + a defensive copy of the fields map.

### Goal 5 — Shim-boundary integration test

`tests/test_completion_gate_retry.sh` (185 lines, shellcheck clean)
drives `tekhton gate completion` against two scenarios:

1. **flake-then-pass** — writes a sentinel-file TEST_CMD script
   (`flake_test_cmd`) that fails on first call and passes on every
   subsequent call. Asserts the gate exits 0, the sentinel was
   created (proving TEST_CMD ran), and the causal log contains a
   `"type":"completion_gate_flake"` event with all four documented
   fields embedded in the detail string. Also asserts
   `"stage":"completion_gate"`.
2. **both-fail** — `TEST_CMD=false`, asserts non-zero exit and no
   `completion_gate_flake` event in the causal log.

`COMPLETION_GATE_GRACE_SECS=0` and `COMPLETION_GATE_RETRY_DELAY_SECS=0`
are set in both scenarios so the test runs in ~1s rather than waiting
out the 3+5 second defaults. The test self-skips cleanly when the
`tekhton` binary is missing (e.g. on a fresh clone before
`make build`).

### Goal 6 — Docs

`CLAUDE.md`'s Template Variables table gains three rows for the new
env keys with the documented defaults, ranges, and Watch For caveats
("retry is intentionally NOT applied to the have-baseline branch").

`templates/pipeline.conf.example` gains a commented-out tunable
block under the existing `COMPLETION_GATE_TEST_ENABLED` line in the
"Test Gate, Audit, Baseline" section, explaining the
WSL2-vs-faster-fs / CI-vs-local tradeoff for operators.

## Root Cause (bugs only)

N/A — m45 is a gate-hardening feature milestone, not a bug fix.
The Arc Motivation in the milestone explains the observed false-halt
pattern (m36.2 + m36.3): the completion gate's `TEST_CMD` was firing
within milliseconds of the coder's last syscall after a 200+ turn
refactor. Transient causes observed: stale test_dedup fingerprint,
file-system write barrier not yet flushed, test runner caching
deleted-file metadata, port collision on newly-spawned test
subprocess. m45 narrows the window (grace + sync) and adds a single
retry to absorb the residual flake without weakening the gate's
purpose (genuine breakage still halts because the retry fails too).

## Files Modified

### Modified
- `internal/gates/completion.go` — Goal 1+2. Added `GraceSecs`,
  `RetryOnNoBaseline`, `RetryDelay`, `Causal` fields to
  `CompletionGate`. Added `CausalEmitter` interface +
  `CausalFunc` adapter. Implemented grace-window sleep + sync in
  `runTestCmd` before the first `runner.Run` call. Implemented
  one-retry policy on the no-baseline failure path with
  `completion_gate_flake` causal emission. Net 320→421 lines (under
  the 600-line soft target and 1000-line hard ceiling).
- `internal/gates/completion_test.go` — Goal 4. Six new tests +
  `fakeCausalEmitter` helper. 319→524 lines.
- `internal/config/defaults.go` — Goal 3. Three new default entries
  grouped under `COMPLETION_GATE_TEST_ENABLED`. 621→624 lines.
- `internal/config/sections.go` — Goal 3. Swapped narrow matchExact
  for `hasPrefix("COMPLETION_GATE")` on the
  "Test Gate, Audit, Baseline" rule. Net same.
- `cmd/tekhton/gate.go` — Goal 3. Added `causal` import,
  `clampSeconds()` helper, three new fields populated from env in
  `completionGateFromEnv`, `completionCausalEmitter` factory wiring
  `CausalFunc` to `internal/causal.Log`, `formatCausalDetail`
  deterministic-order detail renderer. 342→418 lines.
- `templates/pipeline.conf.example` — Goal 6. Three new commented
  tunables under the existing `COMPLETION_GATE_TEST_ENABLED` block
  with operator guidance on the WSL2/CI tradeoff.
- `CLAUDE.md` — Goal 6. Three new rows in the Template Variables
  table.

### Created (NEW)
- `internal/gates/completion_sync_unix.go` (NEW, 13 lines) — Unix
  build of `bestEffortSync()` wrapping `syscall.Sync`. Build tag
  `!windows`.
- `internal/gates/completion_sync_windows.go` (NEW, 8 lines) —
  Windows no-op stub. Build tag `windows`. Both files together
  keep the call portable per the milestone's Watch For directive.
- `tests/test_completion_gate_retry.sh` (NEW, 185 lines) — Goal 5
  shim-boundary integration test.

## Docs Updated

- `CLAUDE.md` — three new rows in the Template Variables table.
- `templates/pipeline.conf.example` — three new commented tunables
  in the "Test Gate, Audit, Baseline" section.

These cover the public-surface changes (the three new
`pipeline.conf` env keys). No CLI flags, exported function
signatures, or prompt template variables were added or changed.

## Acceptance Criteria Verification

- [x] `internal/gates/completion.go::Run`, when called with
      `GraceSecs > 0`, sleeps that duration before invoking
      `runner.Run` for the first time. Verified by
      `TestCompletionGate_GracePeriodRespectsContextCancel` (zero
      runner calls during a cancelled 10s grace window).
- [x] `internal/gates/completion.go::Run`, when no baseline is set
      and the first `TEST_CMD` invocation returns non-zero but the
      second returns zero, returns nil and calls
      `Dedup.RecordPass()`. Verified by
      `TestCompletionGate_NoBaselineFirstFailsRetryPasses`
      (dedup.recorded == true, Causal received 1 event).
- [x] `internal/gates/completion.go::Run`, when both `TEST_CMD`
      invocations return non-zero in the no-baseline branch, returns
      `ErrCompletionTestFailed`. Verified by
      `TestCompletionGate_NoBaselineBothFail` (2 runner calls, 0
      causal events, errors.Is matches).
- [x] On successful retry, a `completion_gate_flake` event is
      appended to `${CAUSAL_LOG_FILE}` with `first_exit`,
      `retry_exit`, `test_cmd`, and `milestone` fields. Verified by
      `tests/test_completion_gate_retry.sh` scenario 1 — the
      detail line passes all four `grep -- "${key}=${value}"`
      assertions plus the `"stage":"completion_gate"` assertion.
- [x] `COMPLETION_GATE_GRACE_SECS`, `COMPLETION_GATE_RETRY_NO_BASELINE`,
      and `COMPLETION_GATE_RETRY_DELAY_SECS` appear in
      `internal/config/defaults.go` with the documented defaults.
      Verified — `grep -E "COMPLETION_GATE_(GRACE|RETRY)"
      internal/config/defaults.go` returns 3 matches.
- [x] The three keys land in the build-and-completion-gate section
      of a freshly-rendered defaults environment. Verified —
      `bin/tekhton config defaults --emit shell | grep COMPLETION_GATE_`
      returns 4 lines (the 3 new + the existing TEST_ENABLED). The
      section rule clusters them together under "Test Gate, Audit,
      Baseline".
- [x] No regression in: `internal/gates/...` (all 21 tests pass),
      `internal/pipeline/runner_test.go` (the
      `BlockingStage = "completion_gate"` cases still fire when both
      invocations fail — `TestRunner.go` cached pass),
      `internal/config/...` (cached pass). Full `go test ./...`:
      all packages pass.
- [x] `shellcheck tests/test_completion_gate_retry.sh` returns zero
      warnings. `shellcheck templates/pipeline.conf.example` warnings
      are pre-existing SC2034 noise on the example assignments —
      unchanged by m45.
- [x] `golangci-lint run ./internal/gates/... ./internal/config/...`
      and `go vet ./internal/gates/... ./internal/config/...` clean
      on the modified code. (golangci-lint reports one unrelated
      typecheck error on the user's Go stdlib's
      `chacha20poly1305/fips140only_go1.26.go` — same pre-existing
      noise observed during m44.)
- [x] Full suite passes: `bash tests/run_tests.sh` → Shell 512
      passed / 0 failed, Go all packages pass.

## Watch For Items Addressed

- **Cancel-friendly grace sleep:** Both new sleeps use
  `select { case <-time.After(...): case <-ctx.Done(): return
  ctx.Err() }`. `TestCompletionGate_GracePeriodRespectsContextCancel`
  and `TestCompletionGate_RetryDelayRespectsContextCancel` lock
  this in.
- **Portable `syscall.Sync`:** Build-tagged into
  `completion_sync_unix.go` (`//go:build !windows`) and
  `completion_sync_windows.go` (`//go:build windows`). The Windows
  variant is a documented no-op stub — the grace window still helps
  narrow the race even without the fsync hint.
- **Retry only on no-baseline branch:** Locked in by
  `TestCompletionGate_RetrySkippedWhenBaselineExists` — even with
  `RetryOnNoBaseline=true`, the have-baseline branch halts on the
  first novel failure without invoking the runner a second time.
- **Defaults tuned for WSL2 documented:** The CLAUDE.md row and the
  `pipeline.conf.example` block both explain the WSL2-vs-faster-fs /
  CI tradeoff. Clamps 0–60 at the CLI seam prevent pathological
  values from stalling the pipeline.
- **Zero-file-writes scenario callout:** Acknowledged in the
  milestone as a future optimization (read CODER_SUMMARY.md's `##
  Files Modified` count and skip the grace when 0) — out of scope
  for m45 per the milestone's explicit "out of scope for m45"
  language.
- **Observability signal:** `completion_gate_flake` causal events
  let future analysis spot a climbing flake rate. The shim-boundary
  test asserts the event's presence + payload shape, so the
  observability surface stays stable for the m47 Seeds Forward
  (RUN_SUMMARY/Watchtower surfacing).

## Human Notes Status

No human notes were attached to this milestone.

## Observed Issues (out of scope)

None. The change is narrow and contained to the completion-gate Go
code + the three new env keys + their docs. No drive-by cleanup was
performed on the surrounding files.

## Architecture Change Proposals

None. The change is a pure feature extension within the existing
`internal/gates/` package boundary. The new `CausalEmitter`
interface is a local seam (one consumer, one producer in the CLI
layer) and does not introduce a new cross-package dependency —
`internal/causal.Log` was already importable. No
`ARCHITECTURE.md` updates needed.

## Design Observations

None. The milestone design's `g.causal("type", map[string]string)`
sketch became a `CausalEmitter` interface plus a `CausalFunc`
adapter for clean test-side substitution. The semantics are
identical to the design sketch — the interface form just makes the
test seam explicit. The fields map renders deterministically in the
CLI via `formatCausalDetail` so the causal log's detail string is
stable across runs (avoids spurious diffs in long-term analysis).
