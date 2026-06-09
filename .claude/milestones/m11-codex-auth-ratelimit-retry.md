<!-- milestone-meta
id: "11"
status: "todo"
-->

# m11 (V5) — Codex Auth + Rate-Limit Detection + Retry

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 11 — fifth of the Codex provider arc. m07-m10 ship invocation + decode + tool translation + streaming. m11 adds the resilience layer AND establishes the cost-tier story that drives V5: authentication wiring (CODEX_API_KEY env vs `~/.codex/auth.json` OAuth), rate-limit interpretation, and retry logic. **Cost framing**: Codex CLI has TWO billing modes — sign-in with ChatGPT (uses your Plus/Pro/Team subscription quota = FREE within window) vs API key (paid per-token = expensive). With Anthropic's June 15 2026 change forcing `claude --print` to API-metered pricing regardless of Max subscription tier, Codex's ChatGPT-subscription path becomes the ONLY subscription/free-quota route Tekhton can use until local models land in V5 Phase 2. m11's auth resolution is therefore a cost decision, not just a wiring detail: stored OAuth at `~/.codex/auth.json` is the preferred path because it's free within quota; API key is the explicit paid fallback the operator opts into. Three critical audit facts: (1) Codex's primary env var is `CODEX_API_KEY` not `OPENAI_API_KEY`, (2) the CLI stores OAuth tokens in `~/.codex/auth.json` and Codex prefers stored auth when present, (3) Codex doesn't surface HTTP 429 well (GitHub issue #4840) — rate-limit signaling comes via the `RateLimitSnapshot` payload of `token_count` events and the `UsageLimitExceeded` CodexErrorKind. m11 implements every piece + matches the retry semantics of the Claude provider's quota-pause machinery (m08 in V4). The cross-provider tier visibility lands in m13; m12 wires the cost-ranked chain. |
| **Gap** | At m10 close, the Codex provider has zero auth awareness: it assumes the operator's environment is correctly configured before runtime. When auth fails, the run gets `OutcomeUpstreamError / ErrorSubcategory=AUTH` (from m08) and gives up. Rate-limit handling is similarly absent: m08 captures `RateLimitSnapshot` in `OutcomeResult.RateLimits` but no code consumes it. There's no retry policy — every `UpstreamError` is a single-shot failure. The V4 supervisor (Claude provider's backing) has the quota-pause + Retry-After + exponential-backoff machinery from m08 of V4; the Codex provider needs equivalent behavior. The semantics need to be cross-provider consistent: a Tekhton stage that fails with `UpstreamError` on one provider should fall back to the other (m12) with the same retry policy. |
| **m11 fills** | (1) `internal/provider/codex/auth.go` — auth resolution: precedence is `req.ProviderSpecific["codex.api_key"]` > `CODEX_API_KEY` env > stored OAuth at `~/.codex/auth.json`. When using an explicit API key, exports `CODEX_API_KEY` to the subprocess env via `cmd.Env`. (2) `internal/provider/codex/ratelimit.go` — typed `RateLimitSnapshot` decoder (m08 left it as `json.RawMessage`) with `Window`, `Used`, `Limit`, `ResetAt`, `Remaining()` fields. Helper `(*RateLimitSnapshot).ShouldRetryAfter() (time.Duration, bool)` returns the suggested wait time when remaining is low. (3) `internal/provider/codex/retry.go` — `RetryPolicy` struct with `MaxAttempts`, `BaseDelay`, `MaxDelay`, `RetryableSubcategories`. `(*Provider).RunAgentWithRetry(ctx, req)` wraps `RunAgent` with the policy: classifies the result's `ErrorSubcategory` against the retryable list, sleeps per backoff schedule, re-invokes. Sleep durations adapt to `RateLimitSnapshot.ShouldRetryAfter()` when available. (4) `RetryableSubcategories` defaults match Tekhton's recovery taxonomy: `QUOTA` (with RateLimitSnapshot-driven backoff), `OVERLOADED`, `NETWORK`, `STREAM`, `RETRY_EXHAUSTED`. NOT retryable: `AUTH`, `BAD_REQUEST`, `CONTEXT_OVERFLOW`, `POLICY`, `SANDBOX`. (5) Tests covering each branch + a recorded retry sequence with stub binary emitting transient errors then success. |
| **Depends on** | m07, m08, m10 (m09 independent — tool translation orthogonal to retry) |
| **Files changed** | `internal/provider/codex/auth.go` (~140 LOC), `internal/provider/codex/ratelimit.go` (~160 LOC), `internal/provider/codex/retry.go` (~180 LOC), `internal/provider/codex/codex.go` (modify — surface RunAgentWithRetry, ~30 LOC delta), `internal/provider/codex/auth_test.go` (~120 LOC), `internal/provider/codex/ratelimit_test.go` (~140 LOC), `internal/provider/codex/retry_test.go` (~200 LOC), `internal/provider/codex/testdata/ratelimit_snapshots/*.json` (recorded fixtures), `VERSION` |

---

## Design

### Sequencing note

m11 lands AFTER m08 (event decoder gives us the typed
`OutcomeResult.RateLimits`) and AFTER m10 (streaming integration is
the natural site for mid-turn rate-limit observation if we want it
later — though m11's MVP retries between runs, not mid-stream).

### Goal 1 — Auth resolution

**File:** `internal/provider/codex/auth.go`.

```go
package codex

import (
    "encoding/json"
    "errors"
    "fmt"
    "os"
    "os/exec"
    "path/filepath"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// resolveAuth determines which auth method to use for a Codex
// invocation AND returns the cost tier the resolved auth represents.
// Precedence (highest to lowest):
//
//   1. req.ProviderSpecific["codex.api_key"]  — explicit per-request override → tier "api" (paid)
//   2. stored OAuth at ~/.codex/auth.json     — ChatGPT subscription          → tier "subscription" (free within quota)
//   3. CODEX_API_KEY env var                  — process-level API key         → tier "api" (paid)
//
// IMPORTANT: subscription OAuth precedes the env-var API key. The
// previous m11 draft had API key first; we corrected this so the
// default path stays in the free tier whenever ChatGPT OAuth is
// present. Operators who want to force API-key usage do so explicitly
// via ProviderSpecific["codex.api_key"] OR by removing ~/.codex/auth.json.
//
// Returns:
//   - envOverrides: env slice to pass via cmd.Env (nil when using OAuth)
//   - tier: "subscription" | "api" — surfaced via m13's Provider.Tier()
//   - err: when no auth source is available
func resolveAuth(req *provider.Request) (envOverrides []string, tier string, err error) {
    // Per-request explicit override (paid tier — operator's choice).
    if key := req.ProviderSpecific["codex.api_key"]; key != "" {
        return []string{"CODEX_API_KEY=" + key}, "api", nil
    }
    // Stored OAuth — ChatGPT subscription. Free within quota. PREFERRED.
    if authPath := storedAuthPath(); fileExists(authPath) {
        return nil, "subscription", nil
    }
    // Env-var API key — fallback paid tier.
    if envKey := os.Getenv("CODEX_API_KEY"); envKey != "" {
        return nil, "api", nil  // Already in process env, no override needed.
    }
    return nil, "", errors.New("codex auth: no stored OAuth at ~/.codex/auth.json and no CODEX_API_KEY — run `codex login` for subscription (free within quota) or set CODEX_API_KEY for API-tier (paid)")
}

func storedAuthPath() string {
    if home, err := os.UserHomeDir(); err == nil {
        return filepath.Join(home, ".codex", "auth.json")
    }
    return ""
}

func fileExists(p string) bool {
    if p == "" { return false }
    _, err := os.Stat(p)
    return err == nil
}
```

### Goal 2 — Typed RateLimitSnapshot

**File:** `internal/provider/codex/ratelimit.go`.

```go
package codex

import (
    "encoding/json"
    "fmt"
    "time"
)

// RateLimitSnapshot is the typed decoder for Codex's rate-limit
// payload embedded in token_count events. m08 left this as
// json.RawMessage; m11 parses the fields used for retry timing.
//
// The Codex protocol's RateLimitSnapshot (Rust source) has at
// minimum a primary window and a secondary window — m11 captures
// both as a slice.
type RateLimitSnapshot struct {
    Windows []RateLimitWindow `json:"windows"`
    // Other fields preserved as RawMessage for forward-compat.
    Raw json.RawMessage `json:"-"`
}

type RateLimitWindow struct {
    Name       string     `json:"name"`        // "primary", "secondary", etc.
    Used       int64      `json:"used"`
    Limit      int64      `json:"limit"`
    ResetAt    *time.Time `json:"reset_at,omitempty"`
    WindowSecs int64      `json:"window_secs,omitempty"`
}

func (w *RateLimitWindow) Remaining() int64 {
    if w.Limit <= 0 { return 0 }
    rem := w.Limit - w.Used
    if rem < 0 { return 0 }
    return rem
}

// ShouldRetryAfter examines the snapshot's windows and returns the
// suggested wait duration when a retry is likely productive. Returns
// (0, false) when no useful guidance can be derived (e.g., no
// windows, all windows have non-trivial remaining, no ResetAt).
func (s *RateLimitSnapshot) ShouldRetryAfter() (time.Duration, bool) {
    if s == nil || len(s.Windows) == 0 {
        return 0, false
    }
    // Look at the window with the SMALLEST remaining capacity. If
    // remaining is 0 and ResetAt is in the future, wait until reset.
    var (
        worst        *RateLimitWindow
        worstRemaining int64 = -1
    )
    for i := range s.Windows {
        w := &s.Windows[i]
        rem := w.Remaining()
        if worstRemaining < 0 || rem < worstRemaining {
            worst = w
            worstRemaining = rem
        }
    }
    if worst == nil {
        return 0, false
    }
    if worstRemaining == 0 && worst.ResetAt != nil {
        wait := time.Until(*worst.ResetAt)
        if wait < 0 { wait = 0 }
        return wait, true
    }
    return 0, false
}

// UnmarshalRateLimits is a helper to decode the raw rate-limits
// payload from a TokenCountEvent. Used by deriveOutcome (m08) when
// promoting OutcomeResult.RateLimits to a typed value.
func UnmarshalRateLimits(raw json.RawMessage) (*RateLimitSnapshot, error) {
    if len(raw) == 0 {
        return nil, nil
    }
    var snap RateLimitSnapshot
    if err := json.Unmarshal(raw, &snap); err != nil {
        return nil, fmt.Errorf("ratelimit: decode: %w", err)
    }
    snap.Raw = raw
    return &snap, nil
}
```

### Goal 3 — Retry policy + wrapper

**File:** `internal/provider/codex/retry.go`.

```go
package codex

import (
    "context"
    "math/rand"
    "time"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// RetryPolicy controls how Codex provider responds to retryable
// failures. Sensible defaults are exposed via DefaultRetryPolicy.
type RetryPolicy struct {
    MaxAttempts             int           // Total attempts including the first. 1 = no retries.
    BaseDelay               time.Duration // First retry waits BaseDelay; subsequent grow exponentially.
    MaxDelay                time.Duration // Cap on individual sleep durations.
    JitterFraction          float64       // 0.0–1.0; ±jitter as fraction of the base for that attempt.
    RetryableSubcategories  map[string]bool
}

// DefaultRetryPolicy is the recommended starting point.
//
// Subcategories that retry: QUOTA (with rate-limit-driven wait),
// OVERLOADED, NETWORK, STREAM, RETRY_EXHAUSTED.
//
// Subcategories that do NOT retry: AUTH (bad credentials don't
// recover), BAD_REQUEST (malformed input persists),
// CONTEXT_OVERFLOW (prompt too large — same prompt won't fit on
// retry), POLICY (content policy blocks persist), SANDBOX (sandbox
// violations are deterministic).
func DefaultRetryPolicy() *RetryPolicy {
    return &RetryPolicy{
        MaxAttempts:     3,
        BaseDelay:       2 * time.Second,
        MaxDelay:        2 * time.Minute,
        JitterFraction:  0.2,
        RetryableSubcategories: map[string]bool{
            "QUOTA":             true,
            "OVERLOADED":        true,
            "NETWORK":           true,
            "STREAM":            true,
            "RETRY_EXHAUSTED":   true,
            "UNTYPED":           true,
            "SERVER_5XX":        true,
        },
    }
}

// (*Provider).RunAgentWithRetry is the retry-aware entry point.
// Callers that want single-shot behavior continue to use RunAgent.
func (p *Provider) RunAgentWithRetry(ctx context.Context, req *provider.Request, policy *RetryPolicy) (*provider.Result, error) {
    if policy == nil {
        policy = DefaultRetryPolicy()
    }

    var (
        lastResult *provider.Result
        lastErr    error
        attempt    int
    )

    for attempt = 1; attempt <= policy.MaxAttempts; attempt++ {
        res, err := p.RunAgent(ctx, req)
        if err != nil {
            // Process-level error — not retryable.
            return nil, err
        }
        lastResult = res
        lastErr = nil

        if res.Outcome == provider.OutcomeSuccess {
            return res, nil
        }
        if !policy.RetryableSubcategories[res.ErrorSubcategory] {
            // Not in the retryable set — return as-is.
            return res, nil
        }
        if attempt == policy.MaxAttempts {
            break  // Exhausted.
        }

        // Compute sleep duration.
        wait := backoffWithJitter(policy.BaseDelay, attempt, policy.MaxDelay, policy.JitterFraction)
        // If we have a RateLimitSnapshot suggesting a longer wait, honor it.
        if rl := extractRateLimitsFromResult(res); rl != nil {
            if rlWait, ok := rl.ShouldRetryAfter(); ok && rlWait > wait {
                wait = capWait(rlWait, policy.MaxDelay)
            }
        }

        select {
        case <-time.After(wait):
        case <-ctx.Done():
            return res, ctx.Err()
        }
    }

    return lastResult, lastErr
}

func backoffWithJitter(base time.Duration, attempt int, maxDelay time.Duration, jitterFrac float64) time.Duration {
    // Exponential: base * 2^(attempt-1)
    shift := attempt - 1
    if shift < 0 { shift = 0 }
    if shift > 10 { shift = 10 }  // Avoid overflow.
    dur := base << shift
    if dur > maxDelay {
        dur = maxDelay
    }
    if jitterFrac > 0 {
        jitter := time.Duration(float64(dur) * jitterFrac * (2*rand.Float64() - 1))
        dur += jitter
        if dur < 0 { dur = base }
    }
    return dur
}

func capWait(d, maxDelay time.Duration) time.Duration {
    if d > maxDelay { return maxDelay }
    return d
}

// extractRateLimitsFromResult digs the *RateLimitSnapshot out of the
// provider.Result. m08's OutcomeResult.RateLimits is in the typed
// derive path; for the Provider.Result we re-decode from
// RawProviderData when present. (A cleaner refactor would expose
// the typed RateLimits on provider.Result, but that requires the
// V5 m01 envelope to widen — out of m11 scope.)
func extractRateLimitsFromResult(res *provider.Result) *RateLimitSnapshot {
    // ... walk RawProviderData JSONL for the last token_count event,
    // decode its rate_limits payload via UnmarshalRateLimits.
    return nil  // implementation
}
```

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/codex/auth.go` | Create | `resolveAuth` with three-tier precedence. ~140 LOC. |
| `internal/provider/codex/ratelimit.go` | Create | Typed `RateLimitSnapshot` + `ShouldRetryAfter` + `UnmarshalRateLimits`. ~160 LOC. |
| `internal/provider/codex/retry.go` | Create | `RetryPolicy`, `DefaultRetryPolicy`, `RunAgentWithRetry`, backoff helper. ~180 LOC. |
| `internal/provider/codex/codex.go` | Modify | Surface `RunAgentWithRetry`; call `resolveAuth` in invocation path; wire auth env to `cmd.Env`. ~30 LOC. |
| `internal/provider/codex/auth_test.go` | Create | Precedence tests for all three auth paths. ~120 LOC. |
| `internal/provider/codex/ratelimit_test.go` | Create | Window arithmetic + ShouldRetryAfter tests. ~140 LOC. |
| `internal/provider/codex/retry_test.go` | Create | Backoff + jitter + retry-success-on-attempt-N tests using stub binary. ~200 LOC. |
| `internal/provider/codex/testdata/ratelimit_snapshots/*.json` | Create | Three fixtures: low-remaining, exhausted-with-reset, empty. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `resolveAuth` returns `["CODEX_API_KEY=<key>"]` when `req.ProviderSpecific["codex.api_key"] = "<key>"`. Verified.
- [ ] `resolveAuth` returns nil (no override) when `CODEX_API_KEY` is in process env. Verified.
- [ ] `resolveAuth` returns nil when stored OAuth at `~/.codex/auth.json` exists. Verified.
- [ ] `resolveAuth` returns an error when no auth source is available. Verified.
- [ ] `RateLimitSnapshot.ShouldRetryAfter()` returns `(d, true)` with `d > 0` when a window has 0 remaining and ResetAt in the future. Verified.
- [ ] `ShouldRetryAfter()` returns `(0, false)` when all windows have non-trivial remaining. Verified.
- [ ] `DefaultRetryPolicy().RetryableSubcategories["AUTH"]` is false. `["QUOTA"]` is true. `["BAD_REQUEST"]` is false. Verified.
- [ ] `RunAgentWithRetry` with `MaxAttempts=3` calls `RunAgent` up to 3 times when each attempt returns a retryable subcategory. Verified by `TestRunAgentWithRetry_RetriesUpToMax`.
- [ ] `RunAgentWithRetry` returns success on the FIRST successful attempt and doesn't proceed to further retries. Verified.
- [ ] `RunAgentWithRetry` honors `ctx.Done()` mid-backoff and returns `ctx.Err()`. Verified.
- [ ] `RunAgentWithRetry` extends the backoff duration when `RateLimitSnapshot.ShouldRetryAfter()` suggests a longer wait. Verified by a fixture-driven test.
- [ ] `RunAgent` invocation includes `CODEX_API_KEY=<key>` in `cmd.Env` when `req.ProviderSpecific["codex.api_key"]` is set. Verified.
- [ ] `backoffWithJitter` produces durations that grow exponentially attempt over attempt and stay bounded by `MaxDelay`. Verified by a property-style test.
- [ ] No regression in m07-m10 tests.
- [ ] `golangci-lint run` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **`req.ProviderSpecific["codex.api_key"]` is sensitive.** Don't log
  it. Don't include it in `RawProviderData`. The auth resolution path
  reads it once and exports it to the subprocess env; nothing else
  in the provider should reference it.
- **Stored OAuth is the default for human-driven Codex users.** Don't
  log `~/.codex/auth.json` contents — it has access tokens. Use
  `fileExists` for presence checks, not `os.ReadFile`.
- **The retryable subcategory set is the contract.** Adding a
  subcategory to it means "Tekhton will silently retry this Codex
  error class." Adding `AUTH` would be a bug (retrying with the same
  bad key just fails again). The list above is the audited set.
- **Backoff overflow.** `time.Duration` is int64 nanoseconds.
  `base << shift` with `shift > 30` overflows. The cap at `shift = 10`
  keeps us safe (`base * 1024` max before `MaxDelay` cap).
- **Jitter direction matters.** Symmetric jitter (±frac) can produce
  a wait shorter than `base` on small attempts. That's fine for
  high-contention scenarios but document it. If we ever need
  strictly-monotonic backoff, drop the jitter.
- **`extractRateLimitsFromResult` is a soft seam.** A cleaner V5 m07+
  refactor would surface the typed `*RateLimitSnapshot` directly on
  `provider.Result` (currently it's only in m08's
  `OutcomeResult.RateLimits`). That cross-cutting change is out of
  m11 scope; the helper digs through `RawProviderData` as a
  workaround.
- **HTTP 429 doesn't surface (GH issue #4840).** The bash-side
  recovery for Codex must rely on the `UsageLimitExceeded`
  subcategory and `RateLimitSnapshot`, not HTTP headers. This
  milestone's retry policy honors the typed signal — don't add
  HTTP header parsing as a "belt and suspenders" without verifying
  Codex actually emits them.

## Seeds Forward

- **Mid-stream rate-limit observation.** m10's streaming path could
  surface `token_count` events to a retry policy mid-turn, enabling
  early-abort when the snapshot shows imminent exhaustion. m11's
  MVP retries between runs only; the streaming hook is positioned
  but not wired.
- **Cross-provider retry consistency.** m12 will route between
  Claude and Codex. Both should respect the SAME
  `RetryableSubcategories` set. A shared `internal/provider/retry/`
  package could host the policy with provider-specific implementations.
  Tracked as a m12+ candidate.
- **Telemetry on retry-rate.** Each retry should fire a causal event
  (`retry_attempt`) so a rising retry rate becomes visible. Out of
  m11 scope; the seam supports it cleanly.
- **Per-stage retry policies.** The Codex provider's
  `RunAgentWithRetry` accepts a `*RetryPolicy`. Stages can populate
  custom policies in their request setup (e.g., reviewer stage with
  `MaxAttempts=5` for transient flakes). m12's pipeline.conf
  configuration could expose `RETRY_*` keys per stage.
- **Storage hardening.** `~/.codex/auth.json` permissions check at
  resolve time (warn if world-readable). Out of m11 scope; a security
  hardening enhancement.
