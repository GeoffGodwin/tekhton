<!-- milestone-meta
id: "6"
status: "todo"
-->

# m06 — Supervisor Core: exec.CommandContext + Line Decoder + Activity Timer

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 2 / 6 — the central wedge of the supervisor port. Replaces the FIFO + background-subshell + foreground-reader contortion in `lib/agent_monitor.sh` (~301 lines) with one `exec.CommandContext`, one `bufio.Scanner` goroutine, and one `time.AfterFunc` activity timer. This is where Go's process-supervision primitives prove themselves. |
| **Gap** | Bash uses a FIFO + background subshell + foreground reader because it has no async/select. JSON lines are parsed via inline `python3 -c`. The activity timer is a foreground sleep loop. Cross-subshell state moves through files. None of this is portable to Go without a complete rewrite. |
| **m06 fills** | (1) Real `Supervisor.Run` that launches `claude` (or any agent CLI) with `exec.CommandContext`, captures stdout via `bufio.Scanner`, decodes each line as `claude`'s streaming JSON event format. (2) `time.AfterFunc`-based activity timer reset on every line. (3) Ring buffer (50 lines) of recent stdout for the result envelope. (4) Stderr tee to the causal log + stage log file. (5) Cancellation via `context.Context` propagates SIGTERM → SIGKILL escalation through `os/exec` natively. |
| **Depends on** | m05 |
| **Files changed** | `internal/supervisor/run.go`, `internal/supervisor/decoder.go`, `internal/supervisor/ringbuf.go`, `internal/supervisor/run_test.go`, `internal/supervisor/decoder_test.go`, `testdata/agent_stdout/` |
| **Stability after this milestone** | **Not stable for production until m10 lands.** The supervisor can launch and supervise an agent, but lacks retry/quota-pause/Windows-reaping/fsnotify. Bash supervisor still owns production. |
| **Dogfooding stance** | Hold. The Go supervisor can now actually run an agent end-to-end on POSIX with no quota issues — useful for ad-hoc developer testing — but production paths stay on bash until m10. |

---

## Design

### Run shape

```go
func (s *Supervisor) Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
    // 1. Build cmd from request envelope
    cmd := exec.CommandContext(ctx, "claude", buildArgs(req)...)
    cmd.Dir = req.WorkingDir
    cmd.Env = mergeEnv(os.Environ(), req.EnvOverrides)

    stdout, _ := cmd.StdoutPipe()
    stderr, _ := cmd.StderrPipe()

    // 2. Spawn
    started := time.Now()
    if err := cmd.Start(); err != nil { return nil, fmt.Errorf("start: %w", err) }

    // 3. Activity timer
    var lastActivity atomic.Int64
    lastActivity.Store(started.UnixNano())
    activityTO := time.Duration(req.ActivityTO) * time.Second
    activityTimer := time.AfterFunc(activityTO, func() {
        // m09 will add fsnotify check here as override
        cancel(ctx, ErrActivityTimeout)  // cancels Run's context
    })
    defer activityTimer.Stop()

    // 4. Decoder goroutine
    rb := newRingBuf(50)
    decoded := make(chan event)
    go decode(stdout, decoded, rb, &lastActivity, activityTimer, activityTO)

    // 5. Stderr tee goroutine (to log file + ring buffer for diagnostics)
    go teeStderr(stderr, s.causal, req.Label)

    // 6. Wait
    err := cmd.Wait()
    duration := time.Since(started)
    return buildResult(req, cmd, err, rb, duration), nil
}
```

The exact shape is illustrative — the actual code factors `decode`, `teeStderr`, `buildResult`, and timer reset into named functions for testability.

### Line decoder

`internal/supervisor/decoder.go`:

```go
type event struct {
    Type   string          `json:"type"`           // "turn_started", "turn_ended", "tool_use", "error", …
    Turn   int             `json:"turn,omitempty"`
    Detail json.RawMessage `json:"detail,omitempty"`
    Raw    string          // original line, for ring buffer
}

func decode(r io.Reader, out chan<- event, rb *ringBuf, lastActivity *atomic.Int64,
            timer *time.AfterFunc, activityTO time.Duration) {
    sc := bufio.NewScanner(r)
    sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)  // claude can emit big JSON lines
    for sc.Scan() {
        line := sc.Text()
        rb.add(line)
        lastActivity.Store(time.Now().UnixNano())
        timer.Reset(activityTO)

        var ev event
        if err := json.Unmarshal([]byte(line), &ev); err == nil {
            ev.Raw = line
            out <- ev
        }
        // non-JSON lines: tracked in ring buffer, no event emitted
    }
}
```

The decoder replaces the entire `python3 -c "import json; …"` invocation chain in bash. Critically, **timer reset on every line** preserves the V3 behavior where any output (JSON or not) counts as activity.

### Ring buffer

`internal/supervisor/ringbuf.go` is a 30-line type with a fixed-size circular slice, mutex-guarded. Exposes `add(string)` and `snapshot() []string`. `snapshot()` is what fills `AgentResultV1.StdoutTail`.

### Cancellation

The context passed to `Run` is the cancellation handle. Callers (m07 retry, m08 quota, eventually orchestrate.go) cancel it via `context.WithCancel`. `exec.CommandContext` handles SIGTERM → SIGKILL escalation natively (default 5s grace; configurable via `cmd.Cancel` and `cmd.WaitDelay` on Go 1.20+).

The activity timer firing calls `cancel(ctx, ErrActivityTimeout)` — actually a small helper that records the cancellation reason in a context value so `buildResult` can map it to `Outcome: "activity_timeout"`.

### What this milestone explicitly does NOT do

- **No retry envelope.** That's m07.
- **No quota pause.** That's m08.
- **No Windows process-tree reaping.** That's m09 (`os/exec` on POSIX is fine; Windows needs JobObjects).
- **No fsnotify activity override.** That's m09. m06 ships `find -newer` polling parity at the activity-timer site.
- **No bash shim flip.** `lib/agent.sh` is unchanged.

### Test strategy

`internal/supervisor/run_test.go`:

- Spawn a fixture script (`testdata/fake_agent.sh`) that emits known JSON events on stdout with controllable timing. Assert `AgentResultV1` fields match.
- Activity timeout test: fixture sleeps longer than `ActivityTO`. Assert outcome is `activity_timeout`, exit code reflects SIGTERM.
- Cancellation test: caller cancels context after 100ms. Assert process exits, ring buffer captured.
- Ring buffer overflow: fixture emits 100 lines; assert tail contains lines 51–100.

`internal/supervisor/decoder_test.go`:

- Table-driven: each row is `(input string, expected []event)`. Covers valid JSON, malformed JSON, mixed lines, very long lines.
- Activity timer reset: time-mocked test asserting `Reset` called per line.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/supervisor/run.go` | Create | Real `Run` implementation (replaces m05 stub). ~150 lines. |
| `internal/supervisor/decoder.go` | Create | Line scanner + JSON decode + activity-timer reset. ~80 lines. |
| `internal/supervisor/ringbuf.go` | Create | Mutex-guarded fixed-size ring. ~30 lines. |
| `internal/supervisor/run_test.go` | Create | Integration tests against `testdata/fake_agent.sh`. |
| `internal/supervisor/decoder_test.go` | Create | Decoder unit tests, table-driven. |
| `testdata/agent_stdout/` | Create | JSON fixture lines: valid events, malformed, mixed; used by both decoder and orchestrate-side tests. |
| `testdata/fake_agent.sh` | Create | Configurable fake agent (delays, output patterns, exit codes) for integration tests. |

---

## Acceptance Criteria

- [ ] `Supervisor.Run` launches `testdata/fake_agent.sh`, captures stdout, returns `AgentResultV1` with correct `ExitCode`, `TurnsUsed`, `DurationMs`, and `StdoutTail`.
- [ ] Activity timer fires when fake agent sleeps > `ActivityTO` between lines: outcome is `activity_timeout`, agent receives SIGTERM, then SIGKILL after grace.
- [ ] Activity timer is reset on every output line (verified via time-mocked decoder test).
- [ ] Caller-driven cancellation (`context.Cancel()`) terminates the agent within 5s; partial stdout still appears in `StdoutTail`.
- [ ] Ring buffer holds the last 50 lines: fixture emits 100, snapshot contains lines 51–100 in order.
- [ ] Decoder handles malformed JSON lines without panicking — ring buffer captures the raw line, no event emitted.
- [ ] Decoder handles JSON lines up to 4 MB (claude streaming events can be large).
- [ ] Stderr is teed to the causal log as `agent_stderr` events without blocking the stdout decoder.
- [ ] `bash tests/run_tests.sh` produces identical output to HEAD~1 (no bash file modified).
- [ ] m01–m05 acceptance criteria still pass; self-host check still passes.
- [ ] Coverage for `internal/supervisor` ≥ 70% (rises again in m07–m10).

## Watch For

- **`bufio.Scanner` default buffer is 64 KB.** Claude emits multi-MB JSON events for large tool results. Set `sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)` or scanner silently fails with `bufio.ErrTooLong`.
- **Timer reset must be cheap.** It runs per line, so `time.AfterFunc.Reset` is fine but don't replace it with a goroutine-per-line scheme.
- **`exec.CommandContext` on Go 1.20+ supports `cmd.Cancel` and `cmd.WaitDelay`.** Use these for graceful SIGTERM → SIGKILL escalation; pre-1.20 hand-rolling is unnecessary.
- **Stderr tee MUST NOT block stdout decoding.** Independent goroutines, separate scanner instances. A blocked stderr would deadlock the agent if it filled its stderr pipe buffer.
- **`exec.CommandContext` does NOT kill the process tree on Windows.** That's m09's job. Do not work around it here — m06 is POSIX-correct, Windows reaping is the next milestone's seam.
- **Activity timer firing during normal turn boundaries.** A turn that genuinely takes > `ActivityTO` (e.g. a long Bash invocation) will be killed. The fsnotify override in m09 fixes this; until then, set `ActivityTO` conservatively in fixtures.
- **Don't change AgentResultV1's shape.** m05 published it. Adding fields requires a v1.x bump (additive only); changing semantics requires v2 (breaking).

## Seeds Forward

- **m07 retry envelope:** consumes `Outcome` and the error fields to decide whether to re-call `Run`. The shape exists; m07 wraps it.
- **m08 quota pause:** intercepts `error_subcategory == "api_rate_limit"` and pauses before retry. Same `Outcome`/error machinery.
- **m09 Windows reaper + fsnotify:** wraps the activity-timer firing path with an fsnotify-based "are we actually idle" check; replaces the polling fallback. Wraps `exec.CommandContext` cleanup with platform-specific reaping on Windows.
- **m10 parity & cutover:** the fake agent fixture and ring-buffer assertions become the spine of the parity test suite.
- **Phase 4 orchestrate port:** `Orchestrator.runStage` will call `Supervisor.Run` directly. The context-based cancellation here propagates cleanly to that level — no shim needed in-process.
