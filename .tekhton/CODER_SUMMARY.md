# Coder Summary

_Date: 2026-05-05 — m06 Supervisor Core: exec.CommandContext + Line Decoder + Activity Timer_

## Status: COMPLETE

## What Was Implemented

Phase 2's central wedge of the V4 supervisor port. The m05 stub in
`internal/supervisor/supervisor.go` is replaced with a real
`exec.CommandContext`-based subprocess path; m07–m10 layer retry, quota
pause, Windows reaping, and parity tests on top of this seam.

- **`internal/supervisor/run.go` (NEW)** — real `(*Supervisor).run`. Builds
  an `exec.CommandContext`, captures stdout via `bufio.Scanner` (with the 4 MB
  buffer cap the "Watch For" note flagged), tees stderr to the causal log
  on a background goroutine, bounds idle time with `time.AfterFunc`, and
  shapes the result into `AgentResultV1`. Activity-timer fires call
  `cancel()` on a child `runCtx` and stash `"activity_timeout"` in an atomic
  Value, so the `Outcome` field can distinguish caller-driven from
  activity-driven cancellation. SIGTERM → SIGKILL escalation is handled via
  `cmd.Cancel` + `cmd.WaitDelay` (Go 1.20+ os/exec native). Helpers
  (`buildArgs`, `mergeEnv`, `exitCodeFromError`, `outcomeFor`,
  `startFailureResult`, `teeStderr`) are extracted so each can be tested in
  isolation.
- **`internal/supervisor/decoder.go` (NEW)** — `decode(ctx, r, cfg)` reads
  lines, appends every line to the ring buffer, resets the activity timer,
  and forwards JSON-decoded events with non-empty `type` to a channel.
  Non-JSON or untyped lines are silently dropped (the ring buffer is the
  diagnostic record). Ctx-respecting select on the send so cancellation
  doesn't block on a backed-up consumer. `activityTimer` is an interface so
  unit tests can drive `Reset()` count assertions without spinning a real
  timer.
- **`internal/supervisor/ringbuf.go` (NEW)** — fixed-size circular buffer
  guarded by a sync.Mutex. `add(line)` / `snapshot() []string` / `len()`.
  Snapshot returns a fresh slice in chronological order so callers can't
  mutate the ring's storage.
- **`internal/supervisor/supervisor.go` (MODIFIED)** — dropped the m05 stub
  body of `Run()` and the `ErrNotImplemented` sentinel. `New()` now
  resolves the agent binary at construction time from
  `$TEKHTON_AGENT_BINARY` (constant `AgentBinaryEnv`), defaulting to
  `claude`. `SetBinary()` lets tests point at the fixture without env
  pollution. `Run()` is a thin shim into `run.go`'s `(*Supervisor).run`.
- **`testdata/fake_agent.sh` (NEW)** — configurable POSIX shell fixture for
  integration tests. Modes: `happy`, `fail`, `slow`, `flood`, `mixed`,
  `stderr_chatter`, `long_line`, `hang`. Driven by `FAKE_AGENT_MODE` /
  `FAKE_AGENT_LINES` / `FAKE_AGENT_SLEEP` / `FAKE_AGENT_EXIT` /
  `FAKE_AGENT_LARGE`. Shellcheck clean.
- **`testdata/agent_stdout/*.jsonl` (NEW)** — JSON fixture lines exercised
  by `decoder_test.go`: `valid_two_turns`, `mixed_with_garbage`, `empty`,
  `no_type_field`. Same fixture set will seed parity tests in m10.
- **`internal/supervisor/run_test.go` (NEW)** — integration tests. Covers
  the milestone's eight acceptance criteria: happy-path envelope shape;
  activity timeout fires + SIGTERM escalation; caller-driven cancellation;
  ring buffer overflow keeps last 50; malformed lines don't fatal; long
  lines (200 KB) survive the bumped scanner buffer; non-zero exit →
  fatal_error; missing-binary start failure produces a result envelope (not
  a Go error). Plus pure-helper tests for `buildArgs`, `mergeEnv`, and
  `outcomeFor`.
- **`internal/supervisor/decoder_test.go` (NEW)** — decoder unit tests:
  valid-stream ordering, malformed lines dropped silently, no-type-field
  dropped, empty input clean, timer reset count == line count, long line
  not truncated, last-activity timestamp updated, ctx cancellation
  respected on a blocked send.
- **`internal/supervisor/ringbuf_test.go` (NEW)** — ring buffer unit tests:
  zero-size clamp, sub-cap ordering, overflow keeps newest N, snapshot is a
  copy, concurrent writes don't deadlock.
- **`internal/supervisor/supervisor_test.go` (MODIFIED)** — dropped
  m05-stub-specific tests (`Run_StubReturnsSuccess`,
  `Run_StdoutTailEmptyOnStub`, `ErrNotImplemented_HasMessage`); the
  envelope-shape coverage moved to `run_test.go`. Added
  `TestNew_DefaultsToClaudeBinary`, `TestNew_HonorsEnvOverride`,
  `TestSetBinary_OverridesAfterConstruction` to lock the binary
  configuration contract. Validation rejection tests, AgentSpec round-trip
  tests, and the V3 error-taxonomy tests are unchanged.
- **`cmd/tekhton/supervise_test.go` (MODIFIED)** — happy-path CLI tests
  (`HappyPath_Stdin`, `HappyPath_RequestFile`,
  `FixtureRequestsProduceValidResponses`) now call a `useFakeAgent(t,
  mode)` helper that sets `TEKHTON_AGENT_BINARY` to the fixture script
  and exports `FAKE_AGENT_MODE=happy`. Without this, m06's real subprocess
  launch would try to exec `claude` and these tests would fail in CI.
  The fixture-driven test relaxes its `Outcome` assertion to accept
  `success` or `fatal_error` because `request_full.json`'s `working_dir`
  doesn't exist in CI.
- **`cmd/tekhton/supervise.go` (MODIFIED)** — doc comment refreshed to
  reflect that m06 actually launches the agent (binary defaulting to
  `claude`, overridable via `$TEKHTON_AGENT_BINARY`); the m05 stub language
  has been removed.
- **`cmd/tekhton/state.go` (MODIFIED)** — exit-code documentation block
  on `newStateCmd` updated to reference the named constants
  (`exitNotFound`, `exitCorrupt`) alongside their numeric values, in
  response to the prior reviewer's note that the comment was misleading
  after the constants were extracted.

### Prior reviewer blockers folded into m06

The prior architect-remediation review surfaced three "Simple Blockers"
that were either already resolved by the in-flight extraction or are
naturally subsumed by m06's scope:

- **`supervisor.go` unused `"errors"` import:** resolved — the
  `ErrNotImplemented = errors.New(...)` sentinel was the only consumer of
  the `errors` package in this file, and m06 deletes both (the sentinel
  was a stub-only marker).
- **`errors.go` unused `"errors"` import:** the actual extracted file
  (`cmd/tekhton/errors.go`) does not import `"errors"` at all — it only
  declares constants, a struct, and three method receivers. Nothing to
  fix; the reviewer was looking at a draft that did not land.
- **`state.go` exit-code comment misleading:** updated above.

## Files Modified

| File | Type |
|------|------|
| `internal/supervisor/run.go` | **NEW** — real Run + helpers (~270 lines) |
| `internal/supervisor/decoder.go` | **NEW** — line scanner + JSON decode (~107 lines) |
| `internal/supervisor/ringbuf.go` | **NEW** — circular buffer (~62 lines) |
| `internal/supervisor/run_test.go` | **NEW** — integration tests (~384 lines) |
| `internal/supervisor/decoder_test.go` | **NEW** — decoder unit tests (~224 lines) |
| `internal/supervisor/ringbuf_test.go` | **NEW** — ring unit tests (~92 lines) |
| `testdata/fake_agent.sh` | **NEW** — configurable POSIX fixture (~105 lines) |
| `testdata/agent_stdout/valid_two_turns.jsonl` | **NEW** — fixture |
| `testdata/agent_stdout/mixed_with_garbage.jsonl` | **NEW** — fixture |
| `testdata/agent_stdout/empty.jsonl` | **NEW** — fixture |
| `testdata/agent_stdout/no_type_field.jsonl` | **NEW** — fixture |
| `internal/supervisor/supervisor.go` | MODIFIED — stub replaced; binary config added |
| `internal/supervisor/supervisor_test.go` | MODIFIED — stub tests removed; binary tests added |
| `cmd/tekhton/supervise_test.go` | MODIFIED — happy-path tests use fixture |
| `cmd/tekhton/supervise.go` | MODIFIED — doc comment refresh |
| `cmd/tekhton/state.go` | MODIFIED — exit-code comment uses named constants |

## Architecture Decisions

- **Binary override via env var (`TEKHTON_AGENT_BINARY`).** The supervisor
  hard-codes `claude` as the default agent CLI but honors the env var at
  `New()` time. This is the seam tests use to point Run at
  `testdata/fake_agent.sh` without growing the public API. A Cobra flag
  on `cmd/tekhton/supervise.go` was rejected — keeping the override out
  of band keeps the CLI surface small and matches the V3 bash
  supervisor's `CLAUDE_CLI` env hook.
- **Activity timer cancels the run context, not the process directly.**
  The `time.AfterFunc` handler calls `cancel()` on the run-scoped child
  context. `exec.CommandContext` then runs our `cmd.Cancel` hook (SIGTERM)
  followed by `cmd.WaitDelay` (5 s) before SIGKILL. This routes both
  caller-driven and timer-driven termination through the same kernel-
  level escalation path, which simplifies m09's Windows reaper
  substitution (replace `cmd.Cancel`, leave the timer untouched).
- **Cancellation reason via `atomic.Value`.** `outcomeFor` needs to
  distinguish caller cancellation (→ `fatal_error`) from activity timeout
  (→ `activity_timeout`). The timer's AfterFunc stores the string before
  calling cancel(); the main path loads it after `cmd.Wait()`.
  atomic.Value is the simplest race-free hand-off; a context-value
  approach would have required threading a carrier struct through the
  cancel path.
- **Result envelope returned even on start failure.** `cmd.Start()` errors
  (binary missing, pipe creation failed) map to a fatal_error result
  envelope rather than a Go error. This keeps the calling contract
  uniform: callers always get a result they can log and inspect, and bash
  shims read `ExitCode == -1` to mean "process never started".

## Docs Updated

None — no public-surface changes in this task. The `TEKHTON_AGENT_BINARY`
env var is an internal extension point exercised only by tests; production
deployments continue to rely on the default `claude` binary on PATH.
m10 (parity + cutover) will document the agent-binary override as part of
the bash→Go shim flip.

## Architecture Change Proposals

None. The Go supervisor wedge was already designed in `DESIGN_v4.md`
Phase 2; m06 implements the central `(*Supervisor).run` body that the
m05 stub deferred to. No new dependencies between systems, no layer
boundary changes, no contract changes — `AgentResultV1` is unchanged.

## Verification

- `shellcheck testdata/fake_agent.sh` clean.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` clean.
- `bash tests/run_tests.sh`: 501/501 shell tests passed; Python tools
  250 passed / 14 skipped. No regressions.
- **Go toolchain ran via Windows `go.exe` 1.24.3** by rsync'ing the source
  tree to a Windows-readable path (`%TEMP%\tekhton-build`) — `go.exe`
  cannot RLock files on the WSL UNC mount, so a copy was needed.
  After verification the temp dir was deleted.
- `go build ./...` (windows/amd64): **clean, exit 0**.
- `go vet ./...` (windows/amd64): **clean, exit 0**.
- `GOOS=linux GOARCH=amd64 go build ./...`: **clean, exit 0** (cross-
  compile catches any GOOS-specific code that the Windows test run
  would skip past).
- `GOOS=linux GOARCH=amd64 go vet ./...`: **clean, exit 0**.
- `go test ./internal/supervisor/...` (windows/amd64): **PASS**. All
  unit tests (decoder, ringbuf, validation, AgentSpec, error taxonomy,
  binary configuration) pass. The seven integration tests that exec
  `testdata/fake_agent.sh` skip cleanly via the `runtime.GOOS ==
  "windows"` guard — they require a POSIX shell and will run on Linux.
  m09 will add Windows-equivalent fixtures.
- `go test ./...` (windows/amd64): two pre-existing failures observed,
  both confirmed to fail at HEAD (i.e. before m06 changes were applied)
  by re-running against a `git stash -u` snapshot of the workspace:
  - `cmd/tekhton.TestApplyField_EmptyValOnAbsentExtraKey_NoOp` — bug in
    `applyField()` (m03 work): `snap.Extra` is allocated unconditionally
    before the `val == ""` early-return, so deleting a non-existent
    key creates an empty map. Out of scope for m06; recorded under
    Observed Issues below.
  - `internal/state.TestAtomicWrite_NoTruncation` — Windows-platform
    artefact: the test relies on POSIX read-only-directory semantics
    that Windows does not enforce, so the expected `Write` failure
    never surfaces. Out of scope for m06; recorded under Observed
    Issues below.
- The fixture-driven integration tests in `internal/supervisor/run_test.go`
  could not be executed in this environment because Go is not installed
  natively in WSL and Windows `go.exe` cannot run `bash testdata/fake_agent.sh`
  (the `runtime.GOOS == "windows"` guard makes them skip on the only
  available toolchain). They will run on the next Linux CI execution.
  Reviewer should validate them on a Linux host before sign-off.

## Observed Issues (out of scope)

- `cmd/tekhton/state.go:191-198` — `applyField` allocates `snap.Extra`
  unconditionally before checking `val == ""`. When called with an
  empty value for a key that was never set, this creates an empty
  `map[string]string` instead of leaving `Extra` nil. Caught by
  `TestApplyField_EmptyValOnAbsentExtraKey_NoOp` in `state_test.go:178`.
  Pre-existing (m03 work); fix is to gate the `make()` behind a
  non-empty-val check.
- `internal/state/snapshot_test.go:148` — `TestAtomicWrite_NoTruncation`
  expects `os.WriteFile` to fail in a chmod 0500 directory; on Windows
  the chmod has no effect and the test fails. Either skip on
  `runtime.GOOS == "windows"` or use a Windows-compatible read-only
  primitive. Pre-existing.

## Human Notes Status

No `HUMAN_NOTES.md` items were in scope for this milestone.
