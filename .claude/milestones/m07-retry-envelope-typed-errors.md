<!-- milestone-meta
id: "7"
status: "todo"
-->

# m07 — Retry Envelope: Typed Errors + Exponential Backoff

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 2 / 6. m06 launches and supervises one agent invocation. Production needs the retry-on-transient layer that wraps it: exponential backoff, subcategory-aware minimum delays (api_rate_limit ≥ 60s, oom ≥ 15s with floor), and typed error dispatch instead of string-cut routing. |
| **Gap** | `lib/agent_retry.sh` (`_run_with_retry`) wraps `_invoke_and_monitor` in a hand-coded loop with subcategory case statements, exponential backoff via `while` loops (bash lacks `**`), and result globals (`_RWR_EXIT`, `_RWR_TURNS`, `_RWR_WAS_ACTIVITY_TIMEOUT`) because functions can't return structs. |
| **m07 fills** | (1) `RetryPolicy` struct in `internal/supervisor/retry.go` with category/subcategory floors, base delay, max delay, attempt cap. (2) `Retry(ctx, req, policy)` helper that calls `Supervisor.Run`, classifies the result, and decides retry vs return. (3) Typed errors (`ErrUpstreamRateLimit`, `ErrUpstreamOOM`, `ErrInternalTimeout`, …) that callers can `errors.Is`/`errors.As` on. (4) Per-attempt causal events with the same shape `lib/agent_retry.sh` emits today. |
| **Depends on** | m06 |
| **Files changed** | `internal/supervisor/retry.go`, `internal/supervisor/errors.go`, `internal/supervisor/retry_test.go`, `internal/supervisor/errors_test.go` |
| **Stability after this milestone** | **Not stable for production until m10 lands.** Retry logic exists in Go and is unit-tested; production stays on `lib/agent_retry.sh` until m10's parity test passes and m10 flips the shim. |
| **Dogfooding stance** | Hold. Useful for ad-hoc Go-side testing (manually invoking `tekhton supervise --retry-policy …` for diagnostic runs); production paths still go through bash retry. |

---

## Design

### Typed errors

`internal/supervisor/errors.go` defines the V3 error taxonomy as Go types:

```go
type AgentError struct {
    Category    string
    Subcategory string
    Transient   bool
    Wrapped     error
}

func (e *AgentError) Error() string { /* CATEGORY|SUBCATEGORY|… format for wire compat */ }
func (e *AgentError) Is(target error) bool { /* match on Category+Subcategory */ }
func (e *AgentError) Unwrap() error { return e.Wrapped }

// Sentinel exemplars — callers compare with errors.Is
var (
    ErrUpstreamRateLimit  = &AgentError{Category: "UPSTREAM",  Subcategory: "api_rate_limit", Transient: true}
    ErrUpstreamOOM        = &AgentError{Category: "UPSTREAM",  Subcategory: "oom",            Transient: true}
    ErrUpstreamTransient  = &AgentError{Category: "UPSTREAM",  Subcategory: "transient",      Transient: true}
    ErrInternalTimeout    = &AgentError{Category: "INTERNAL",  Subcategory: "timeout",        Transient: true}
    ErrActivityTimeout    = &AgentError{Category: "INTERNAL",  Subcategory: "activity_timeout", Transient: true}
    ErrFatalAgent         = &AgentError{Category: "AGENT",     Subcategory: "fatal",          Transient: false}
    // … see lib/errors.sh for the full vocabulary
)
```

The full taxonomy mirrors `lib/errors.sh` exactly; the table is materialized in `internal/supervisor/errors.go` with one source-of-truth comment block linking back to the bash file. Drift between the two is a known foot-gun until m10 deletes the bash side.

`classifyResult(*AgentResultV1) error` maps a non-success `AgentResultV1` into a typed error using the result's `ErrorCategory`/`ErrorSubcategory` fields (which `Run` populates from agent stdout/stderr pattern-matching in m06).

### Retry policy

```go
type RetryPolicy struct {
    MaxAttempts     int           // V3 default: 3
    BaseDelay       time.Duration // V3 default: 30s (TRANSIENT_RETRY_BASE_DELAY)
    MaxDelay        time.Duration // V3 default: 120s (TRANSIENT_RETRY_MAX_DELAY)
    Floors          map[string]time.Duration  // subcategory → minimum delay
}

func DefaultPolicy() *RetryPolicy {
    return &RetryPolicy{
        MaxAttempts: 3,
        BaseDelay:   30 * time.Second,
        MaxDelay:    120 * time.Second,
        Floors: map[string]time.Duration{
            "api_rate_limit": 60 * time.Second,  // V3 explicit floor
            "oom":            15 * time.Second,
        },
    }
}

// Delay computes attempt N's wait, applying floor + cap + jitter.
func (p *RetryPolicy) Delay(attempt int, subcategory string) time.Duration { ... }
```

`Delay` formula: `min(MaxDelay, max(Floors[sub], BaseDelay * 2^(attempt-1))) + jitter(0..10%)`. Matches V3 behavior; jitter is new but inside the float of the existing range.

### Retry helper

```go
func (s *Supervisor) Retry(ctx context.Context, req *proto.AgentRequestV1, p *RetryPolicy) (*proto.AgentResultV1, error) {
    var lastResult *proto.AgentResultV1
    var lastErr error
    for attempt := 1; attempt <= p.MaxAttempts; attempt++ {
        s.causal.Emit(req.Label, "retry_attempt", fmt.Sprintf("attempt %d/%d", attempt, p.MaxAttempts), nil, nil)
        result, runErr := s.Run(ctx, req)
        lastResult = result
        if runErr != nil { return result, runErr }  // propagate non-classified errors

        if result.Outcome == "success" || result.Outcome == "turn_exhausted" {
            return result, nil  // turn_exhausted is a retryable-elsewhere signal, not a transient error
        }

        cls := classifyResult(result)
        var ae *AgentError
        if errors.As(cls, &ae) && !ae.Transient {
            return result, cls  // fatal — don't retry
        }
        if attempt == p.MaxAttempts {
            return result, cls  // exhausted
        }

        delay := p.Delay(attempt, result.ErrorSubcategory)
        s.causal.Emit(req.Label, "retry_backoff", fmt.Sprintf("sleeping %s before attempt %d", delay, attempt+1), nil, nil)
        select {
        case <-time.After(delay):
        case <-ctx.Done():
            return result, ctx.Err()  // SIGINT during backoff
        }
    }
    return lastResult, lastErr
}
```

The flow mirrors `_run_with_retry` exactly. SIGINT during backoff cancels cleanly via the context — replaces the bash trap-chain dance.

### What this milestone explicitly does NOT do

- **No quota pause.** That's m08. `api_rate_limit` here just retries with the 60s floor; m08 layers a much longer pause (with TUI updates, Retry-After header parsing) on top.
- **No spinner pause/resume bracket.** That was the `_RWR_*` nameref mechanism in bash. The spinner is the TUI layer's concern; the retry envelope no longer mutates spinner state. (See DESIGN_v4.md "Retry Envelope" section.)
- **No bash shim flip.** `lib/agent_retry.sh` is unchanged.

### Causal events emitted

Per attempt:

| Event type | Payload |
|------------|---------|
| `retry_attempt` | `attempt N/M` |
| `retry_backoff` | `sleeping Xs before attempt N+1` |
| `retry_exhausted` | `gave up after M attempts; last error: <class>` |
| `retry_fatal` | `not retried; subcategory: <subcat>` |

Bash `lib/agent_retry.sh` emits the same event types (DESIGN_v4.md "Retry Envelope" inheritance). m10 parity checks event sequences match.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/supervisor/errors.go` | Create | `AgentError` type, sentinel exemplars, `classifyResult`. ~120 lines. |
| `internal/supervisor/retry.go` | Create | `RetryPolicy` + `Retry`. ~100 lines. |
| `internal/supervisor/errors_test.go` | Create | Sentinel `errors.Is` matching, `classifyResult` table tests. |
| `internal/supervisor/retry_test.go` | Create | Mock `Run` returning configurable `AgentResultV1` sequences; assert retry/give-up/backoff timing. Time-mocked. |

---

## Acceptance Criteria

- [ ] `errors.Is(classifyResult(rateLimitResult), ErrUpstreamRateLimit)` returns true; same for every sentinel in the taxonomy.
- [ ] `RetryPolicy.Delay(attempt=1, subcategory="api_rate_limit")` returns ≥ 60s; `Delay(attempt=3, subcategory="")` returns ≤ MaxDelay.
- [ ] `Retry` calls `Run` once for `Outcome: "success"` and returns immediately.
- [ ] `Retry` calls `Run` up to `MaxAttempts` times for transient errors; gives up with `retry_exhausted` causal event when exhausted.
- [ ] `Retry` returns immediately on fatal errors (`Transient: false`); emits `retry_fatal` causal event.
- [ ] `Retry` honors `ctx.Cancel()` during backoff: returns `context.Canceled` within 10ms of cancellation (table test).
- [ ] Per-attempt causal events emitted in the same shape as `lib/agent_retry.sh` (verified by golden-file comparison of causal log entries from a parity fixture run).
- [ ] Coverage for `internal/supervisor` ≥ 75% (m07 adds testable code).
- [ ] m01–m06 acceptance criteria still pass; self-host check still passes; bash supervisor still owns production.

## Watch For

- **Sentinel-match semantics.** `errors.Is(err, ErrUpstreamRateLimit)` matches on Category+Subcategory only — `Wrapped` and `Transient` fields don't participate. Test this explicitly; getting `Is` wrong silently breaks fatal-vs-transient routing.
- **`turn_exhausted` is NOT a retry trigger.** Bash treats it as a continuation signal handled by orchestrate (`MAX_CONTINUATION_ATTEMPTS`). Retry returns it as a non-error result; the caller decides what to do.
- **The error vocabulary lives in two places until m10.** `lib/errors.sh` and `internal/supervisor/errors.go`. Keep them synchronized — m07 includes a comparator script (`scripts/error-taxonomy-diff.sh`) that fails CI if the bash side adds a category/subcategory the Go side doesn't have.
- **Jitter is new vs V3.** Adding ±10% jitter is a deliberate improvement (avoids thundering-herd on shared rate limits) but it changes observable timing. Document in the milestone retro and verify the parity test allows for it.
- **`MaxDelay` clamp applies AFTER floor.** A subcategory floor of 60s with `MaxDelay: 30s` would otherwise sleep for 30s — wrong. The formula is `min(MaxDelay, max(floor, base*2^n))`.
- **Don't pull in `time.Sleep` directly inside `Retry`.** Use `select { case <-time.After: case <-ctx.Done: }` so cancellation works.

## Seeds Forward

- **m08 quota pause:** intercepts `ErrUpstreamRateLimit` BEFORE it reaches the retry policy's normal backoff. The pause helper sleeps until quota refresh (much longer than 60s); retry then resumes normally.
- **m10 parity & cutover:** the per-attempt causal event golden files become the spine of the retry parity test.
- **Phase 4 orchestrate port:** `Orchestrator.runStage` will call `Supervisor.Retry` directly. The typed error result lets it dispatch to recovery routing without string parsing.
- **Future error taxonomy additions:** new categories/subcategories are added in `internal/supervisor/errors.go` first (Go is now the source of truth post-m10) and ported back to bash only if a bash caller still needs them.
