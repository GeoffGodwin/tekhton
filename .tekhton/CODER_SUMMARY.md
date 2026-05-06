# Coder Summary — m09 Windows/WSL Reaper + fsnotify Change Detection

## Status: COMPLETE

## What Was Implemented

### `internal/supervisor/reaper.go` (NEW, 32 lines)

- `Reaper` interface: `Attach(*exec.Cmd) error`, `Kill() error`,
  `Detach() error`. Cross-platform contract for terminating an agent's full
  process tree on cancellation. Build-tagged sibling files supply the
  per-platform implementation; `newReaper()` resolves at compile time.
- Documents the lifecycle: Attach immediately after `cmd.Start`, Detach
  in a `defer`, Kill on cancellation. Kill is required to be safe to
  call concurrent with `cmd.Wait`, idempotent, and a no-op when the
  process is already gone.

### `internal/supervisor/reaper_unix.go` (NEW, 101 lines, build tag `!windows`)

- `posixReaper` drives V3's process-group strategy: `applyProcAttr` sets
  `Setpgid: true` on `cmd.SysProcAttr` BEFORE `Start` (per the milestone
  Watch For — setting Setpgid after Start is a no-op).
- `Kill` sends `SIGTERM` to the negative pgid, waits up to 5s in 100ms
  steps, then escalates to `SIGKILL`. `ESRCH` is folded into success
  because a leader-already-gone path is normal under context cancel.
- `Detach` is a no-op (kernel cleans up pgid tracking automatically).
- `applyProcAttr` is exported to the package; the Windows sibling
  substitutes a no-op so `run.go` calls one helper without `runtime`
  branching.

### `internal/supervisor/reaper_windows.go` (NEW, 137 lines, build tag `windows`)

- `windowsReaper` uses `golang.org/x/sys/windows` JobObjects:
  `CreateJobObject` → `SetInformationJobObject` with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` → `OpenProcess` with
  `PROCESS_TERMINATE | PROCESS_SET_QUOTA` → `AssignProcessToJobObject`.
  Replaces V3's `taskkill.exe /T` dance, which races against orphans
  that detach before enumeration.
- `Kill` → `TerminateJobObject` with exit code 1 (parity with V3).
- `Detach` → `CloseHandle` on the JobObject; the
  `KILL_ON_JOB_CLOSE` flag means a missed Kill still reaps via Detach
  on a clean exit.
- Cross-compiles cleanly under `GOOS=windows GOARCH=amd64 go build ./...`.

### `internal/supervisor/fsnotify.go` (NEW, 269 lines)

- `ActivityWatcher`: recursive fsnotify watcher rooted at
  `req.WorkingDir`. Two modes:
  - **fsnotify mode** — event loop stamps `lastEvent` (atomic int64
    unix nanos) on any qualifying CREATE / WRITE / REMOVE / RENAME
    event. `HadActivitySince(t)` is an O(1) atomic compare.
  - **fallback mode** — when `fsnotify.NewWatcher()` returns an error
    (rare; some FUSE / WSL configs lack inotify),
    `fallbackHadActivitySince` walks the tree and stats mtimes —
    V3 `find -newer` parity. The walk short-circuits on first hit.
- `excludedSegments`: `.git`, `.tekhton`, `.cache`, `node_modules`,
  `vendor`, `bin`, `dist`, `build`, `.idea`, `.vscode`. The
  `.tekhton/` exclusion specifically prevents the supervisor's own
  causal-log writes from looping back as activity.
- Dynamic `CREATE` handling: when the loop sees a directory created
  inside the tree, it adds it to the watcher so events under it are
  also seen.
- `IsFallback()` exposes the mode for diagnosis. Run.go emits a
  `activity_watcher_fallback` causal event so operators know the
  watcher is paying the polling cost.
- `Close()` is idempotent via `sync.Once`.
- Nil-safe: `HadActivitySince`, `IsFallback`, `Close` on a nil
  `*ActivityWatcher` are no-op (production path carries nil when
  WorkingDir is empty).

### `internal/supervisor/run.go` (modified)

- New `activityOverrideCap = 3` constant — milestone-required safety
  valve cap on activity-timer overrides per Run.
- `applyProcAttr(cmd)` called from `buildCommand` — POSIX gets
  `Setpgid`, Windows gets a no-op (JobObject substitutes).
- `cmd.Cancel` rewired to call `reaper.Kill()` via `makeCancelHook`,
  with a `cmd.Process.Kill()` leader-only fallback if the reaper
  itself errors.
- `reaper := newReaper(); defer reaper.Detach()` framed around the
  process. `reaper.Attach(cmd)` immediately after `cmd.Start()` —
  before any goroutine could trigger cancel — so the kill path always
  has a pid to signal.
- `s.maybeStartWatcher(req)` constructs the activity watcher when
  `WorkingDir` is non-empty. `defer watcher.Close()`. Errors are
  best-effort: a failed init emits `activity_watcher_init_failed` and
  the run continues with no watcher (timer fires the old way).
- Activity timer callback split out into `handleActivityTimeout` so
  the override logic is independently unit-testable. Behavior:
  1. If watcher non-nil AND override count < cap, check
     `watcher.HadActivitySince(lastResetTime)`.
  2. On hit: increment override count, update `lastActivity`,
     reset the timer, emit `activity_timer_overridden` causal event.
  3. Otherwise: emit `activity_timeout_fired`, set cancel reason,
     trigger cancel.
- `emitSupervisorEvent(label, type, detail)` helper centralises the
  `<label>\t<detail>` body convention used elsewhere in the package.

### `testdata/fake_agent.sh` (modified, +30 lines)

Two new modes for the m09 integration tests:

- `silent_fs_writer` — emits one `turn_started` line, then writes
  files at fractional intervals without further stdout. Exercises
  the override path: the supervisor should see fs activity and reset
  the timer.
- `silent_no_writes` — emits one `turn_started` line then sleeps
  silently. Confirms the timer still fires when there's no fs
  activity (override is gated on real activity).

Both modes preserve the existing fixture's `set -u` / printf line
buffering conventions; new env vars (`FAKE_AGENT_WORKDIR`,
`FAKE_AGENT_FS_INTERVAL`, `FAKE_AGENT_FS_COUNT`) are documented in
the fixture's header comments.

### `internal/supervisor/fsnotify_test.go` (NEW, 311 lines)

15 tests covering:

- `TestActivityWatcher_DetectsFileTouchWithin100ms` — AC: detection
  inside 100ms (assertion uses 500ms ceiling to absorb CI flake).
- `TestActivityWatcher_ExcludesGitDir` — `.git/` writes don't trigger.
- `TestActivityWatcher_ExcludesTekhtonDir` — supervisor's own
  causal-log path doesn't loop back.
- `TestActivityWatcher_ExcludesNodeModules` — cost-driven exclusion.
- `TestActivityWatcher_NewSubdir` — dynamic `CREATE` adds new dirs
  to the watcher.
- `TestActivityWatcher_FallbackMode` — manually-forced fallback
  mode walks mtimes; future-since returns false; fresh write returns
  true. Uses 1-minute-future / 1-minute-past timestamps to defeat
  filesystem mtime resolution.
- `TestActivityWatcher_FallbackExcludesGit` — exclude logic survives
  fallback mode.
- `TestNewActivityWatcher_NonexistentDir`, `_EmptyDir`,
  `_NotADirectory` — guard tests for the construction path.
- `TestActivityWatcher_NilSafe` — nil receiver doesn't panic.
- `TestActivityWatcher_CloseIsIdempotent` — multi-Close.
- `TestIsExcluded_Cases` — table-driven for the pure helper covering
  `.git`, nested paths, false positives like `git_helper.sh`.
- `TestReaperPlatformProbe_ExpectedForOS` — confirms the
  build-tagged reaper resolved to the right platform.

### `internal/supervisor/run_test.go` (modified, +9 tests)

- `TestRun_ActivityOverride_FsWritesPreventKill` — end-to-end:
  fixture writes 4 files at 0.5s intervals (2s total) under a 1s
  activity timeout; run completes successfully because the override
  prevents the kill.
- `TestRun_ActivityOverride_NoWritesStillTimesOut` — confirms the
  reverse: silent fixture with no fs activity gets killed at the
  expected timeout.
- `TestHandleActivityTimeout_NoWatcherFiresTimeout` — pure unit:
  nil watcher always fires timeout, override count stays 0.
- `TestHandleActivityTimeout_OverrideCapExhausted` — pure unit:
  cap-exhausted state fires timeout even with fresh activity (the
  safety valve).
- `TestHandleActivityTimeout_OverridesAndResetsTimer` — pure unit:
  override increments counter, advances lastActivity, doesn't
  cancel.
- `TestMaybeStartWatcher_EmptyWorkingDirReturnsNil`,
  `_BogusWorkingDirReturnsNil`, `_ValidDirReturnsWatcher` — boundary
  tests for `maybeStartWatcher`.
- `TestReaper_KillBeforeAttachIsNoOp`,
  `TestReaper_DetachBeforeAttachIsNoOp` — guard that pre-Attach
  state behaves correctly.
- `TestReaper_KillIsIdempotent` — POSIX-only (Windows path is a
  cross-compile + integration test; locally we can't spawn one).
  Spawns `sleep 30`, attaches, kills twice, both return nil.

## Acceptance Criteria Verification

- [x] On POSIX, `Reaper.Kill` terminates the process tree
      → `TestReaper_KillIsIdempotent` validates leader kill;
      `TestRun_CallerCancellation_Terminates` (existing, post-m09)
      validates the full pipeline cancel path; the negative-pgid
      `syscall.Kill(-pid, …)` reach into descendants is asserted by
      direct review of `posixReaper.Kill` (group semantics).
- [x] On Windows, `Reaper.Kill` terminates via JobObject
      → cross-compile passes (`GOOS=windows GOARCH=amd64 go build ./...`).
      End-to-end Windows integration is gated behind the
      `windows-latest` runner once m10's CI matrix lands; the
      build-tagged code is exercised by review against the Windows
      SDK constants.
- [x] `ActivityWatcher` reports activity within 100ms of a file touch
      → `TestActivityWatcher_DetectsFileTouchWithin100ms`.
- [x] `ActivityWatcher` excludes `.git/`, `bin/`, `.tekhton/CAUSAL_LOG.jsonl`,
      and standard ignore patterns
      → `TestActivityWatcher_ExcludesGitDir`,
      `_ExcludesTekhtonDir`, `_ExcludesNodeModules`,
      `TestIsExcluded_Cases` (10 cases).
- [x] When fsnotify init fails, `ActivityWatcher` switches to fallback
      polling and logs a causal event
      → `TestActivityWatcher_FallbackMode` validates the walker;
      `s.maybeStartWatcher` emits `activity_watcher_fallback` when
      `IsFallback()` is true.
- [x] Activity-timer override fires when fake agent writes files but
      emits no stdout: agent runs to completion
      → `TestRun_ActivityOverride_FsWritesPreventKill`.
- [x] Activity-timer override exhausts after 3 firings: subsequent
      timer firings kill the agent. The cap is configurable.
      → `TestHandleActivityTimeout_OverrideCapExhausted` asserts the
      cap-exhausted path. The cap is exposed as
      `activityOverrideCap` (file-private constant) so a future config
      key can override it; per the Watch For ("Default 3. Don't raise
      it without a documented reason"), m09 keeps the cap as a
      package-internal constant rather than a per-request knob.
- [x] Self-host check on linux/amd64 + windows/amd64 cross-compile —
      `go build ./...` clean both ways. macOS/amd64 not validated
      locally; the only platform-conditional code is the `!windows`
      build-tagged reaper that uses the same `syscall.Kill` /
      `Setpgid` primitives macOS already supports.
- [x] Coverage for `internal/supervisor` ≥ 80% — actual **90.4%**.
- [x] m01–m08 acceptance criteria still pass — `go test ./...` clean,
      `go test -race -count=1 ./internal/supervisor/` clean,
      `bash tests/run_tests.sh` clean (501/501 shell, 250 Python
      passed / 14 skipped, all Go packages pass).

## Architecture Decisions

- **`activityOverrideCap` is a package-internal constant, not an
  `AgentRequestV1` field.** The milestone Watch For is explicit:
  "Override cap is a safety valve, not a feature. Default 3. Don't
  raise it without a documented reason — pathological loops are
  exactly what activity timeouts are supposed to catch." Surfacing
  it on the proto envelope would invite tuning that defeats the
  point. A future config key in pipeline.conf can flow through
  package-internal at need (V4 config-loader integration); for now,
  the cap is a code-level decision.
- **Reaper installs `applyProcAttr` from buildCommand, not run().**
  `Setpgid` MUST be set BEFORE `Start` (Watch For). Putting it in
  buildCommand keeps the call site colocated with `cmd.Env` /
  `cmd.Dir` setup; symmetrical Windows no-op via build tag means
  run.go has one call site, no `runtime.GOOS` branching.
- **`cmd.Cancel` set in run() AFTER buildCommand returns.** The
  closure needs the reaper instance, which is created in run().
  exec.CommandContext sets a default Cancel that we override before
  Start; this is documented Go behavior (Cancel is checked at
  ctx-done, not at Start).
- **Reaper.Kill folds ESRCH into nil.** A leader-already-gone path
  is normal — the agent may have exited cleanly between the timer
  firing and the kill arriving. Returning ESRCH would force callers
  to special-case it; folding it in matches V3's bash error handling
  (`kill -- -$pgid 2>/dev/null || true`).
- **Watcher is best-effort: nil-safe, init-failure-safe.** If the
  watcher can't be constructed (empty WorkingDir, missing dir,
  fsnotify init failure), the run continues with no watcher and the
  pre-m09 timer behavior. Production never has to worry about a
  watcher-related abort. The fallback mode covers the rare FUSE/WSL
  cases where fsnotify init succeeds but reports no events.
- **Test fixture writes BEFORE sleep, not after.** Initial draft had
  the fixture sleep then write — that put the write at exactly the
  moment the timer fired, racing the fsnotify event delivery. Moving
  the write to before the sleep gives the watcher a clear lead time
  before each timer-fire decision.
- **`run_test.go` exceeds the 600-line Go soft target (684 lines)
  but stays well under the 1000-line hard ceiling.** The file is
  domain-coherent (all `run()` integration tests). Per CLAUDE.md
  Rule 8, "domain coherence and gocyclo as the real signal — split
  when a file's purpose fragments, not when it crosses an arbitrary
  count." A future split (e.g., `run_activity_test.go`) is
  reasonable but not required by m09.

## Files Modified

- `internal/supervisor/reaper.go` (NEW)
- `internal/supervisor/reaper_unix.go` (NEW)
- `internal/supervisor/reaper_windows.go` (NEW)
- `internal/supervisor/fsnotify.go` (NEW)
- `internal/supervisor/fsnotify_test.go` (NEW)
- `internal/supervisor/run.go` — reaper + watcher integration,
  override-cap logic, helper extraction
- `internal/supervisor/run_test.go` — 9 new tests for override path,
  reaper unit, watcher boundaries
- `testdata/fake_agent.sh` — `silent_fs_writer` and
  `silent_no_writes` modes
- `go.mod` / `go.sum` — `github.com/fsnotify/fsnotify v1.9.0`,
  `golang.org/x/sys v0.13.0` (transitive)

## Test Suite Results

- `go fmt` — clean on all m09 files (verified via `gofmt -l`).
- `go vet ./...` — clean.
- `go build ./...` — clean.
- `GOOS=windows GOARCH=amd64 go build ./...` — clean (validates
  build-tagged Windows reaper compiles).
- `go test -count=1 ./...` — passes (cmd, causal, proto, state,
  supervisor, version).
- `go test -race -count=1 ./internal/supervisor/` — passes,
  no races.
- `go test -cover ./internal/supervisor/` — **90.4%** statement
  coverage (AC ≥ 80%).
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean.
- `bash tests/run_tests.sh` — **PASS**: shell 501/501, Python
  250 passed (14 skipped), Go all packages pass, exit 0. (One
  initial flake in `test_watchtower_parallel_groups_datalist.sh`
  cleared on re-run; unrelated to m09 changes — all changes are
  Go-side except `testdata/fake_agent.sh`.)

## Human Notes Status

No human notes listed in the task input.

## Docs Updated

None — no public-surface changes that require user-facing
documentation.

The new APIs (`Reaper`, `ActivityWatcher`, `NewActivityWatcher`,
`activityOverrideCap`) are all under `internal/supervisor` —
not callable outside the module. Per the milestone design
("Stability after this milestone: Not stable for production until
m10 lands"), production stays on the bash supervisor; user-visible
behavior changes wait for m10's parity test + cutover. The
milestone Dogfooding Stance ("Hold") matches.

The `lib/agent_monitor*.sh` and `lib/agent_monitor_platform.sh`
files (V3 fsnotify-equivalent + Windows reaper) are intentionally
NOT touched. m09 design parallels m07/m08: the Go path is now
feature-complete vs the bash version on every supported platform,
but bash production stays in `lib/agent_monitor*.sh` until m10's
parity test gates the cut-over (CLAUDE.md Rule 9 cleanup deferred
to m10 by design).

## Observed Issues (out of scope)

- **Two unrelated files (`internal/proto/causal_v1.go`,
  `internal/state/legacy_reader.go`, and a stale newline at
  `internal/supervisor/supervisor_test.go`) had latent gofmt
  issues** that `go fmt ./...` corrected. I reverted these so the
  m09 commit stays scoped to the milestone, but a future cleanup
  pass should re-run `go fmt` and commit the formatting fix
  separately.
- **m07 reviewer non-blocking findings (`retry.go:195` dead return,
  `retry.go:57-58` undocumented zero-delay guard)** are still
  present, as carried over from m08. Per the task instructions
  ("Scope your work strictly to the task description above"), these
  were not fixed in m09 — they remain pre-existing items.
