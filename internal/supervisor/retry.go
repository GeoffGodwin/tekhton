package supervisor

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"time"

	"github.com/geoffgodwin/tekhton/internal/causal"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// RetryPolicy bounds the retry envelope. Defaults match V3's TRANSIENT_RETRY_*
// config keys (lib/agent_retry.sh _should_retry_transient). Subcategory floors
// reproduce the per-error minimums baked into the bash case statement; jitter
// is new in m07 — a deliberate ±10% spread to avoid thundering-herd retries
// against shared rate limits.
type RetryPolicy struct {
	MaxAttempts int
	BaseDelay   time.Duration
	MaxDelay    time.Duration
	Floors      map[string]time.Duration

	// rng injectable for deterministic tests; nil -> math/rand.Int63n.
	rng func(int64) int64
}

// DefaultPolicy returns the V3-equivalent defaults: 3 attempts, 30s base,
// 120s cap, with rate-limit / overloaded / OOM floors taken straight from
// lib/agent_retry.sh.
func DefaultPolicy() *RetryPolicy {
	return &RetryPolicy{
		MaxAttempts: 3,
		BaseDelay:   30 * time.Second,
		MaxDelay:    120 * time.Second,
		Floors: map[string]time.Duration{
			"api_rate_limit": 60 * time.Second,
			"api_overloaded": 60 * time.Second,
			"oom":            15 * time.Second,
		},
	}
}

// Delay computes the wait before attempt+1 based on the just-failed attempt
// (1-indexed) and the result's error subcategory.
//
// Formula: max(floor, min(MaxDelay, BaseDelay * 2^(attempt-1))) + jitter(0..10%).
// The MaxDelay clamp re-applies after jitter UNLESS a subcategory floor
// deliberately exceeds MaxDelay — in that case the floor wins (config
// asserting an explicit minimum that overrides the cap).
func (p *RetryPolicy) Delay(attempt int, subcategory string) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	if p.BaseDelay <= 0 {
		return 0
	}

	delay := p.BaseDelay
	for i := 1; i < attempt; i++ {
		delay *= 2
		if p.MaxDelay > 0 && delay >= p.MaxDelay {
			delay = p.MaxDelay
			break
		}
	}
	if p.MaxDelay > 0 && delay > p.MaxDelay {
		delay = p.MaxDelay
	}

	var floor time.Duration
	if p.Floors != nil {
		floor = p.Floors[subcategory]
		if floor > delay {
			delay = floor
		}
	}

	if delay > 0 {
		bound := int64(delay) / 10
		if bound > 0 {
			delay += time.Duration(p.jitter(bound + 1))
		}
	}

	if p.MaxDelay > 0 && delay > p.MaxDelay && floor <= p.MaxDelay {
		delay = p.MaxDelay
	}
	return delay
}

func (p *RetryPolicy) jitter(n int64) int64 {
	if n <= 0 {
		return 0
	}
	if p.rng != nil {
		return p.rng(n)
	}
	//nolint:gosec // jitter for backoff; not security-sensitive.
	return rand.Int63n(n)
}

// runFunc is the single-attempt callback the retry loop drives. Production
// callers pass Supervisor.Run; tests pass a scripted fake.
type runFunc func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)

// Retry wraps Supervisor.Run with the m07 retry envelope. Transient classified
// failures retry with exponential backoff; fatal failures and runner errors
// return immediately. ctx cancellation during backoff returns ctx.Err() —
// no orphan sleep.
func (s *Supervisor) Retry(ctx context.Context, req *proto.AgentRequestV1, p *RetryPolicy) (*proto.AgentResultV1, error) {
	return retryLoop(ctx, req, p, s.causal, s.Run, time.After)
}

// retryLoop is the unit-testable retry implementation. The injected runner
// (`run`) and clock (`after`) seams let tests stub agent behavior and skip
// real sleeps — there is no time.Sleep anywhere on the path so cancellation
// and time-mocking are uniform.
func retryLoop(
	ctx context.Context,
	req *proto.AgentRequestV1,
	p *RetryPolicy,
	log *causal.Log,
	run runFunc,
	after func(time.Duration) <-chan time.Time,
) (*proto.AgentResultV1, error) {
	if req == nil {
		return nil, fmt.Errorf("supervisor: nil request")
	}
	if run == nil {
		return nil, fmt.Errorf("supervisor: nil runner")
	}
	if p == nil {
		p = DefaultPolicy()
	}
	if after == nil {
		after = time.After
	}

	label := req.Label
	var lastResult *proto.AgentResultV1

	for attempt := 1; attempt <= p.MaxAttempts; attempt++ {
		emitRetryEvent(log, "retry_attempt", label, fmt.Sprintf("attempt %d/%d", attempt, p.MaxAttempts))

		result, runErr := run(ctx, req)
		lastResult = result
		if runErr != nil {
			return result, runErr
		}
		if result == nil {
			return nil, fmt.Errorf("supervisor: runner returned nil result")
		}

		if result.Outcome == proto.OutcomeSuccess || result.Outcome == proto.OutcomeTurnExhausted {
			return result, nil
		}

		cls := classifyResult(result)
		var ae *AgentError
		errors.As(cls, &ae)

		if ae != nil && !ae.Transient {
			emitRetryEvent(log, "retry_fatal", label,
				fmt.Sprintf("not retried; subcategory: %s", ae.Subcategory))
			return result, cls
		}

		if attempt == p.MaxAttempts {
			subcat := ""
			if ae != nil {
				subcat = ae.Subcategory
			}
			emitRetryEvent(log, "retry_exhausted", label,
				fmt.Sprintf("gave up after %d attempts; last error: %s", p.MaxAttempts, subcat))
			return result, cls
		}

		subcat := result.ErrorSubcategory
		if subcat == "" && ae != nil {
			subcat = ae.Subcategory
		}
		delay := p.Delay(attempt, subcat)
		emitRetryEvent(log, "retry_backoff", label,
			fmt.Sprintf("sleeping %s before attempt %d", delay, attempt+1))

		select {
		case <-after(delay):
		case <-ctx.Done():
			return result, ctx.Err()
		}
	}

	return lastResult, nil
}

func emitRetryEvent(log *causal.Log, eventType, label, detail string) {
	if log == nil {
		return
	}
	_, _ = log.Emit(causal.EmitInput{
		Stage:  "supervisor",
		Type:   eventType,
		Detail: fmt.Sprintf("%s\t%s", label, detail),
	})
}
