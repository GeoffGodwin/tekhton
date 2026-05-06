<!-- milestone-meta
id: "9"
status: "done"
-->

# m09 — Windows/WSL Reaper + fsnotify Change Detection

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 2 / 6. Two platform-specific concerns close out the supervisor's behavior parity: (1) Windows process trees are not killed automatically by `os/exec` when context cancels, and `claude.exe` orphans hide from the bash process group; (2) the activity timer firing should be checked against actual filesystem activity (`find -newer` polling in V3) before it kills an apparently-idle but actually-working agent. |
| **Gap** | (1) `lib/agent_monitor_platform.sh::_kill_agent_windows` reaps WSL `claude.exe` orphans via `taskkill.exe`. No Go equivalent. (2) `lib/agent_monitor.sh` polls `find -newer` to detect "agent is silently working on files" and override the activity-timeout firing. No Go equivalent. |
| **m09 fills** | (1) `internal/supervisor/reaper_windows.go` (build-tagged) using `JobObjects` to kill the entire process tree on Windows. POSIX side gets a no-op stub. (2) `internal/supervisor/fsnotify.go` watches `req.WorkingDir` for file modifications; when the activity timer fires, it checks the fsnotify event channel for recent activity and overrides the timeout if any was seen since the last reset. (3) Polling fallback (`find`-equivalent walk) when fsnotify init fails (rare, but happens on certain mounts). |
| **Depends on** | m08 |
| **Files changed** | `internal/supervisor/reaper.go`, `internal/supervisor/reaper_windows.go`, `internal/supervisor/reaper_unix.go`, `internal/supervisor/fsnotify.go`, `internal/supervisor/fsnotify_test.go`, `internal/supervisor/run.go` (modify) |
| **Stability after this milestone** | **Not stable for production until m10 lands.** Platform parity is now complete in Go but production stays on bash until m10. |
| **Dogfooding stance** | Hold. The supervisor is now feature-complete vs the bash version on every supported platform; m10 wires the parity gate and the cutover. |

---

## Design

### Platform reaper interface

`internal/supervisor/reaper.go` declares the cross-platform interface; the actual implementation is build-tagged.

```go
type Reaper interface {
    // Attach binds the supervisor to a launched process so the reaper can
    // track its tree. Called immediately after exec.Start().
    Attach(cmd *exec.Cmd) error

    // Kill terminates the process and every descendant. Must succeed even
    // if the root has already exited (orphans are the whole point).
    Kill() error

    // Detach releases tracking on graceful exit.
    Detach() error
}

func newReaper() Reaper  // platform-dispatched
```

Two implementations:

- `reaper_unix.go` (build tag `!windows`): a thin wrapper around `exec.CommandContext`'s native cleanup. `Kill()` sends `SIGTERM`, then `SIGKILL` after a configurable grace. `Attach`/`Detach` are no-ops because POSIX process groups (set via `Setpgid`) handle children.
- `reaper_windows.go` (build tag `windows`): uses `golang.org/x/sys/windows` to create a Job Object, assign the process to it on `Attach`, and call `TerminateJobObject` on `Kill`. Replaces the V3 `taskkill.exe /T` dance.

Run integration:

```go
// internal/supervisor/run.go (modified)
reaper := newReaper()
cmd := exec.CommandContext(ctx, "claude", buildArgs(req)...)
// POSIX: set process group so we can signal the whole tree
if runtime.GOOS != "windows" { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }
if err := cmd.Start(); err != nil { return nil, fmt.Errorf("start: %w", err) }
defer reaper.Detach()
if err := reaper.Attach(cmd); err != nil { /* log, continue — reaper is best-effort */ }

// On context cancel or activity timeout, call reaper.Kill() before falling
// through to cmd.Wait(). The native ctx-cancel path remains as a backstop.
```

### fsnotify watcher

`internal/supervisor/fsnotify.go`:

```go
type ActivityWatcher struct {
    dir       string
    notifier  *fsnotify.Watcher
    lastEvent atomic.Int64           // unix nano
    fallback  bool                    // true when fsnotify init failed
}

func NewActivityWatcher(dir string) (*ActivityWatcher, error)

// HadActivitySince returns true if a file was modified inside dir after t.
// In fsnotify mode this is O(1) (read lastEvent atomic). In fallback mode
// it walks dir and checks mtimes (V3 find -newer parity).
func (w *ActivityWatcher) HadActivitySince(t time.Time) bool

func (w *ActivityWatcher) Close() error
```

The watcher recursively adds the project tree. Excludes `.git/`, `.tekhton/CAUSAL_LOG.jsonl` (the supervisor's own writes shouldn't count), the binary output dir, and standard ignore patterns.

### Activity timer integration

`internal/supervisor/run.go` (modified):

```go
watcher, _ := NewActivityWatcher(req.WorkingDir)  // best-effort
defer watcher.Close()

activityTimer := time.AfterFunc(activityTO, func() {
    // Before killing, check fsnotify: did the agent touch files recently?
    lastResetTime := time.Unix(0, lastActivity.Load())
    if watcher != nil && watcher.HadActivitySince(lastResetTime) {
        // False alarm — agent is working silently. Reset and continue.
        lastActivity.Store(time.Now().UnixNano())
        activityTimer.Reset(activityTO)
        s.causal.Emit(req.Label, "activity_timer_overridden", "fsnotify saw filesystem activity", nil, nil)
        return
    }
    s.causal.Emit(req.Label, "activity_timeout_fired", "no stdout or fs activity within window", nil, nil)
    cancel(ctx, ErrActivityTimeout)
})
```

The override fires up to N times per run (configurable, default 3) before the timer becomes permanent — protects against pathological "writes one file every 5 minutes forever" loops. Fired-and-overridden events are tracked via causal events for diagnosis.

### Fallback polling

When `fsnotify.NewWatcher` fails (rare; some FUSE mounts, certain WSL configs), `ActivityWatcher` falls back to the V3 `find -newer` strategy: at activity-timer-fire time it walks the project tree and checks mtimes against `lastResetTime`. Slower but correct. A causal event flags the fallback so users know to investigate.

### Test strategy

`internal/supervisor/fsnotify_test.go`:

- Create temp dir, instantiate watcher, touch a file, assert `HadActivitySince(beforeTouch)` returns true.
- Touch a file inside `.git/`, assert excluded.
- Force fallback mode, repeat the above.
- Watcher init failure: pass a non-existent dir; assert error returned without panicking.

`internal/supervisor/run_test.go` (extended):

- Fake agent stays silent on stdout but writes a file every 2s. Activity timeout 5s. Assert agent runs to completion (timer overrides ≥ 3 times).
- Fake agent stays silent and writes nothing. Assert activity timeout fires after 5s.

Windows reaper tested in CI on `windows-latest`:

- Spawn fake-agent-that-spawns-children-then-detaches. Cancel context. Assert `tasklist` shows zero remaining children within 2s.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/supervisor/reaper.go` | Create | `Reaper` interface + dispatch. ~30 lines. |
| `internal/supervisor/reaper_unix.go` | Create | POSIX no-op + setpgid hint. ~30 lines. |
| `internal/supervisor/reaper_windows.go` | Create | JobObject-based tree kill. ~80 lines. |
| `internal/supervisor/fsnotify.go` | Create | Activity watcher + fallback. ~150 lines. |
| `internal/supervisor/fsnotify_test.go` | Create | Watcher unit tests, both modes. |
| `internal/supervisor/run.go` | Modify | Wire reaper + watcher into `Run`. ~40 lines added. |

---

## Acceptance Criteria

- [ ] On POSIX, `Reaper.Kill` terminates the process tree (verified by spawning a script that forks 3 children and asserting all four PIDs are gone within 2s of cancel).
- [ ] On Windows, `Reaper.Kill` terminates the process tree via JobObject (CI test on `windows-latest` runner).
- [ ] `ActivityWatcher` reports activity within 100ms of a file touch in the watched tree.
- [ ] `ActivityWatcher` excludes `.git/`, `bin/`, `.tekhton/CAUSAL_LOG.jsonl`, and standard ignore patterns.
- [ ] When fsnotify init fails, `ActivityWatcher` switches to fallback polling and logs a causal event flagging the mode.
- [ ] Activity-timer override fires when fake agent writes files but emits no stdout: agent runs to completion, override events emitted to causal log.
- [ ] Activity-timer override exhausts after 3 firings: subsequent timer firings kill the agent. The cap is configurable.
- [ ] Self-host check on `linux/amd64`, `darwin/amd64`, AND `windows/amd64` runners passes (matrix from m01).
- [ ] Coverage for `internal/supervisor` ≥ 80%.
- [ ] m01–m08 acceptance criteria still pass; bash supervisor still owns production.

## Watch For

- **`Setpgid` on Linux requires `cmd.SysProcAttr` set BEFORE `cmd.Start()`.** Setting it after is a no-op and the process tree won't form correctly.
- **JobObjects on Windows are inherited by children.** If a child explicitly detaches (rare for `claude` but possible for some shell tools it spawns), the JobObject still tracks it. Test against this case explicitly.
- **fsnotify recursive watch is NOT free.** Adding 1000+ directories to the watcher costs memory and FD count. The exclude list (`.git/`, `node_modules/` — add these — `.cache/`, etc.) materially affects watcher cost.
- **fsnotify on macOS uses kqueue, on Linux uses inotify, on Windows uses ReadDirectoryChangesW.** All three have edge cases (kqueue fires on dir-not-file events; inotify has watch limits; Windows fires per-byte writes). Test on all three platforms in CI.
- **Override cap is a safety valve, not a feature.** Default 3. Don't raise it without a documented reason — pathological loops are exactly what activity timeouts are supposed to catch.
- **Self-supervising the fsnotify package itself.** A bug in `fsnotify` could silently stop reporting events; we'd never know until an agent hung. Add a periodic "is the watcher still alive" check (every 60s emit a synthetic touch and verify the channel sees it).
- **Don't watch `.tekhton/`.** The supervisor writes there constantly (causal log, state); watching it would create a feedback loop of self-reset.

## Seeds Forward

- **m10 parity & cutover:** the Windows CI runner case is the parity test's most complex scenario — covered here so m10 inherits a passing baseline.
- **Phase 4 orchestrate port:** the activity watcher might be promoted to a process-wide singleton (one watcher serves all stages) for efficiency. m09 keeps the per-Run instance for simplicity; refactor when justified.
- **Decision register §6 (Python `tools/` boundary):** the fsnotify decision (Go-native vs Python-bridge) is settled — Go wins. The trigger to revisit is a fsnotify Go-side bug we can't resolve, which would push the activity-watcher logic back behind the Python sidecar.
- **Future SIGTSTP/SIGCONT support:** Ctrl-Z + bg + fg flow doesn't currently work cleanly. The reaper interface here gives a place to wire it in if needed; out of scope for V4.
