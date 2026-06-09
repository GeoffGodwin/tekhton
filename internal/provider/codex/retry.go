// Package codex — Retry policy and RunAgentWithRetry.
// V5 m11 — RetryPolicy, DefaultRetryPolicy, RunAgentWithRetry, backoff helpers.
package codex

import (
	"context"
	"math/rand"
	"time"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// RetryPolicy controls how the Codex provider responds to retryable failures.
// Sensible defaults are exposed via DefaultRetryPolicy.
type RetryPolicy struct {
	// MaxAttempts is the total number of attempts including the first. 1 = no retries.
	MaxAttempts int

	// BaseDelay is the initial sleep duration before the first retry.
	// Subsequent retries grow exponentially: base * 2^(attempt-1).
	BaseDelay time.Duration

	// MaxDelay caps individual sleep durations regardless of exponential growth.
	MaxDelay time.Duration

	// JitterFraction adds symmetric jitter as a fraction of the computed delay.
	// 0.0 disables jitter; 0.2 adds ±20%. Jitter can produce waits shorter than
	// BaseDelay on early attempts — accept that for high-contention scenarios.
	JitterFraction float64

	// RetryableSubcategories is the set of ErrorSubcategory values that trigger
	// a retry. Subcategories absent from this map cause immediate return.
	RetryableSubcategories map[string]bool
}

// DefaultRetryPolicy returns the recommended retry configuration.
//
// Retryable subcategories: QUOTA (rate-limit driven), OVERLOADED, NETWORK,
// STREAM, RETRY_EXHAUSTED, UNTYPED, SERVER_5XX.
//
// Non-retryable: AUTH (bad credentials don't recover on retry), BAD_REQUEST
// (malformed input persists), CONTEXT_OVERFLOW (same prompt won't fit),
// POLICY (content policy blocks persist), SANDBOX (deterministic violations).
func DefaultRetryPolicy() *RetryPolicy {
	return &RetryPolicy{
		MaxAttempts:    3,
		BaseDelay:      2 * time.Second,
		MaxDelay:       2 * time.Minute,
		JitterFraction: 0.2,
		RetryableSubcategories: map[string]bool{
			"QUOTA":           true,
			"OVERLOADED":      true,
			"NETWORK":         true,
			"STREAM":          true,
			"RETRY_EXHAUSTED": true,
			"UNTYPED":         true,
			"SERVER_5XX":      true,
		},
	}
}

// RunAgentWithRetry is the retry-aware entry point for the Codex provider.
// It wraps RunAgent with the given policy: classifies ErrorSubcategory against
// the retryable set, sleeps per backoff schedule, re-invokes up to MaxAttempts.
//
// When policy is nil, DefaultRetryPolicy is used. Callers that want single-shot
// behavior continue to use RunAgent directly.
//
// Sleep durations adapt to RateLimitSnapshot.ShouldRetryAfter() when available
// and suggest a longer wait than the computed backoff.
func (p *Provider) RunAgentWithRetry(ctx context.Context, req *provider.Request, policy *RetryPolicy) (*provider.Result, error) {
	if policy == nil {
		policy = DefaultRetryPolicy()
	}

	var lastResult *provider.Result

	for attempt := 1; attempt <= policy.MaxAttempts; attempt++ {
		res, err := p.RunAgent(ctx, req)
		if err != nil {
			// Process-level error — not retryable.
			return nil, err
		}
		lastResult = res

		if res.Outcome == provider.OutcomeSuccess {
			return res, nil
		}
		if !policy.RetryableSubcategories[res.ErrorSubcategory] {
			// Non-retryable subcategory — return as-is.
			return res, nil
		}
		if attempt == policy.MaxAttempts {
			break // Exhausted.
		}

		// Compute sleep duration with optional rate-limit override.
		wait := backoffWithJitter(policy.BaseDelay, attempt, policy.MaxDelay, policy.JitterFraction)
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

	return lastResult, nil
}

// backoffWithJitter computes the sleep duration for a given attempt number.
// Growth is exponential: base * 2^(attempt-1), capped at maxDelay. Symmetric
// jitter of ±jitterFrac is applied after the cap.
func backoffWithJitter(base time.Duration, attempt int, maxDelay time.Duration, jitterFrac float64) time.Duration {
	shift := attempt - 1
	if shift < 0 {
		shift = 0
	}
	if shift > 10 { // prevent int64 overflow: base * 2^10 = 1024x is the max multiplier
		shift = 10
	}
	dur := base << shift
	if dur > maxDelay {
		dur = maxDelay
	}
	if jitterFrac > 0 {
		jitter := time.Duration(float64(dur) * jitterFrac * (2*rand.Float64() - 1))
		dur += jitter
		if dur < 0 {
			dur = base
		}
	}
	return dur
}

func capWait(d, maxDelay time.Duration) time.Duration {
	if d > maxDelay {
		return maxDelay
	}
	return d
}

// extractRateLimitsFromResult is a soft seam that extracts *RateLimitSnapshot
// from a provider.Result. A cleaner V5 m07+ refactor would surface the typed
// RateLimitSnapshot directly on provider.Result; for now it returns nil as
// a placeholder (out of m11 scope — requires the V5 envelope to widen).
func extractRateLimitsFromResult(_ *provider.Result) *RateLimitSnapshot {
	return nil
}
