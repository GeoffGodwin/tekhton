<!-- milestone-meta
id: "8"
status: "todo"
-->

# m08 — Quota Pause/Resume + Retry-After Parsing

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 2 / 6. Retries cover transient errors; quota pause covers the case where Anthropic has imposed a cooldown that won't refresh in 60–120s but in minutes-to-hours. The V3 system grew an elaborate quota arc (m124–m125) that handles long pauses, TUI countdown, layered probes, and Retry-After header parsing. m08 ports this layer into Go so production cutover at m10 doesn't lose a year of resilience work. |
| **Gap** | `lib/quota.sh`, `lib/quota_sleep.sh`, `lib/quota_probe.sh`, `lib/agent_retry_pause.sh` implement: chunked sleep with SIGINT responsiveness, layered probes (version → zero-turn → fallback) with back-off + jitter, TUI pause API, hard caps. None of this exists in Go. |
| **m08 fills** | (1) `internal/supervisor/quota.go` with `EnterQuotaPause(ctx, until, reason)`, chunked sleep, layered probes. (2) Retry-After header parsing from `claude` API error responses. (3) Integration with the m07 retry envelope: `ErrUpstreamRateLimit` triggers a pause-before-retry path. (4) Quota status surfaced in `AgentResultV1` for TUI/dashboard consumption (the TUI sidecar stays Python and reads this from causal events, unchanged). |
| **Depends on** | m07 |
| **Files changed** | `internal/supervisor/quota.go`, `internal/supervisor/quota_probe.go`, `internal/supervisor/retry.go` (modify), `internal/supervisor/quota_test.go`, `cmd/tekhton/quota.go` |
| **Stability after this milestone** | **Not stable for production until m10 lands.** Quota logic is feature-complete in Go but production stays on bash until m10. |
| **Dogfooding stance** | Hold. The Go quota path can be exercised against a mock claude binary that returns 429s; production quota handling stays in bash until m10. |

---

## Design

### Pause helper

```go
type QuotaPause struct {
    Until        time.Time     // expected end of pause (from Retry-After or default cap)
    Reason       string        // "api_rate_limit" | "explicit_quota" | "fallback_probe"
    ChunkSize    time.Duration // QUOTA_SLEEP_CHUNK from V3, default 5s, max 60s
    MaxDuration  time.Duration // QUOTA_MAX_PAUSE_DURATION, default 5h15m
}

// EnterQuotaPause sleeps until either Until is reached, ctx is cancelled, or
// MaxDuration elapses. Sleeps in ChunkSize-bounded slices so SIGINT lands within
// ChunkSize seconds. Emits causal events on entry, every chunk boundary (for TUI
// countdown), and exit.
func (s *Supervisor) EnterQuotaPause(ctx context.Context, p QuotaPause) error
```

The chunked-sleep pattern is the same as `lib/quota_sleep.sh`: a series of `select { case <-time.After(chunk): case <-ctx.Done(): return ctx.Err() }`. Each chunk boundary emits a `quota_tick` causal event so the Python TUI can show a countdown without polling the Go process.

### Layered probe

`internal/supervisor/quota_probe.go` implements V3's three-tier probe (m125):

1. **Version probe.** Fast, cheap. Calls `claude --version` and asserts a clean exit. If it succeeds during the pause window, the quota was lifted early.
2. **Zero-turn probe.** Calls `claude` with `--max-turns 0` and a no-op prompt. Slightly more expensive; catches the case where `--version` works but real invocations don't.
3. **Fallback probe.** Tiny real invocation. Last resort; emits a causal event flagging the probe cost.

Probe interval starts at `QUOTA_PROBE_MIN_INTERVAL` (10m) and grows 1.5× per attempt up to `QUOTA_PROBE_MAX_INTERVAL` (30m). All clamps configurable.

```go
type ProbeResult int
const (
    ProbeQuotaActive ProbeResult = iota  // still rate-limited
    ProbeQuotaLifted
    ProbeError                            // probe itself failed; treat as still-active
)

func (s *Supervisor) Probe(ctx context.Context, kind ProbeKind) ProbeResult
```

### Retry-After parsing

Anthropic 429 responses include `Retry-After` (seconds) or an absolute date. The decoder in m06 surfaces `error_subcategory: "api_rate_limit"` and a `Retry-After` value in `AgentResultV1.Fields`; m08's pause helper consumes that.

```go
func ParseRetryAfter(headerValue string) (until time.Time, ok bool) {
    if secs, err := strconv.Atoi(headerValue); err == nil {
        return time.Now().Add(time.Duration(secs) * time.Second), true
    }
    if t, err := http.ParseTime(headerValue); err == nil {
        return t, true
    }
    return time.Time{}, false
}
```

Falls back to `QUOTA_MAX_PAUSE_DURATION` cap when the header is absent or unparseable.

### Retry envelope integration

`internal/supervisor/retry.go` (modified):

```go
func (s *Supervisor) Retry(ctx context.Context, req *proto.AgentRequestV1, p *RetryPolicy) (*proto.AgentResultV1, error) {
    for attempt := 1; attempt <= p.MaxAttempts; attempt++ {
        result, _ := s.Run(ctx, req)
        cls := classifyResult(result)

        // NEW: rate-limit goes through quota pause, not normal backoff
        if errors.Is(cls, ErrUpstreamRateLimit) {
            until, _ := ParseRetryAfter(result.Fields["retry_after"])
            if until.IsZero() { until = time.Now().Add(15 * time.Minute) }  // conservative default
            if err := s.EnterQuotaPause(ctx, QuotaPause{Until: until, Reason: "api_rate_limit"}); err != nil {
                return result, err
            }
            continue  // retry without burning an attempt — quota pause is its own counter
        }

        // m07 retry logic continues unchanged here ...
    }
}
```

Note: quota pauses do NOT consume retry attempts. A 5-hour pause followed by a successful run is "one attempt" from the retry policy's perspective. This matches V3 behavior.

### CLI

`cmd/tekhton/quota.go`:

| Command | Behavior |
|---------|----------|
| `tekhton quota status` | Reads recent causal events; prints current pause state (active / inactive, until, reason). |
| `tekhton quota probe [--kind version\|zero-turn\|fallback]` | Run a single probe and print result. Used for diagnostics + the bash side of m10's parity test. |

### Bash side

**No bash files modified.** `lib/quota.sh` etc. continue to handle production quota. m08 builds the Go path and tests it against a mock; m10 flips.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/supervisor/quota.go` | Create | `EnterQuotaPause`, chunked sleep, causal `quota_tick` emission. ~120 lines. |
| `internal/supervisor/quota_probe.go` | Create | Three-tier probe + back-off scheduler. ~100 lines. |
| `internal/supervisor/retry.go` | Modify | Add ErrUpstreamRateLimit → quota-pause path. ~30 lines added. |
| `internal/supervisor/quota_test.go` | Create | Time-mocked tests: chunked sleep responds to cancel within ChunkSize; probe back-off respects min/max; pause survives mock 429 sequence. |
| `cmd/tekhton/quota.go` | Create | `status` + `probe` subcommands. |

---

## Acceptance Criteria

- [ ] `EnterQuotaPause` with `Until: now+10s` returns within 10s without error; emits entry, ≥1 tick, exit causal events.
- [ ] `EnterQuotaPause` with `ctx.Cancel()` mid-pause returns `context.Canceled` within `ChunkSize` (5s default).
- [ ] `EnterQuotaPause` with `Until: now+1y` returns after `MaxDuration` (default 5h15m) with a `quota_pause_capped` causal event.
- [ ] `ParseRetryAfter("60")` returns `now+60s`; `ParseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT")` returns the parsed time; `ParseRetryAfter("garbage")` returns `(zero, false)`.
- [ ] `Probe(ctx, ProbeVersion)` against a mock claude that exits 0 returns `ProbeQuotaLifted`; against one that exits 429 returns `ProbeQuotaActive`.
- [ ] Probe back-off: first probe at min interval; subsequent probes at 1.5× up to max. Time-mocked test asserts the schedule.
- [ ] `Retry` with a 429-then-200 mock sequence: enters quota pause, emits expected causal events, returns success on the post-pause attempt without consuming a retry slot.
- [ ] `tekhton quota status` reads the live causal log and reports `paused: true` during a pause; `paused: false` after.
- [ ] Coverage for `internal/supervisor` ≥ 78%.
- [ ] m01–m07 acceptance criteria still pass; bash supervisor still owns production; self-host check still passes.

## Watch For

- **Quota pauses don't consume retry attempts.** This is intentional and matches V3. A 5h pause followed by success is one attempt, not "MaxAttempts exhausted by waiting."
- **`ChunkSize` bounds SIGINT responsiveness.** Default 5s. Don't raise above 60s — the user's Ctrl-C should land within seconds, not minutes.
- **`MaxDuration` is a hard cap.** Default 5h15m matches the upstream quota window plus a clock-skew buffer. If a probe surfaces an "actually 12 hours" pause, the cap fires and the run exits gracefully (the user re-runs later) rather than hanging the supervisor indefinitely.
- **Retry-After header may be a date or seconds.** Don't assume one form. `http.ParseTime` handles RFC1123 + variants; integer parse handles seconds.
- **Probe choice matters for cost.** `version` probe is free (subprocess exit code only). `fallback` probe burns API quota. Default to `version`; only escalate when probes disagree (`version` says lifted, real invocation says still-rate-limited).
- **TUI sees quota state via causal events.** The Python TUI sidecar polls `causal.event.v1` lines for `quota_tick` and renders the countdown. Don't add a separate IPC channel — the events ARE the channel.
- **Don't double-emit.** Both bash quota code AND Go quota code emit causal events through the m02 path. During Phase 2 only the bash side runs in production, so no collision. Post-m10 only Go runs. The window where both could run is m10's parity test, which uses a mock log to avoid the issue.

## Seeds Forward

- **m10 parity & cutover:** the parity test must include a 429 sequence to exercise the quota path end-to-end.
- **Phase 4 TUI port:** when the Python TUI eventually reads from a Go-side IPC instead of polling causal events, the quota event shape stays stable — only the transport changes.
- **Decision §1 (multi-binary):** if a long-running `tekhton quota wait` daemon ever materialises (for shared rate-limit coordination across parallel teams in V5), the pause helper here is the natural seed. The m08 API is in-process; refactoring to a service is mechanical.
- **Future provider abstraction (V5):** when V5 introduces multi-provider support, each provider plugs in its own quota signals. The shape `(rate-limit-detected, retry-after-from-headers, probe-strategy)` here is the interface other providers will implement.
