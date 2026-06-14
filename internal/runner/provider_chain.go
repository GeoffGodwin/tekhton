// Package runner — Chain type for multi-provider fallback execution.
//
// m13: Chain wraps multiple Providers and executes them in order,
// recording which tier succeeded and supporting cost-ranked sorting.
package runner

import (
	"context"
	"fmt"
	"os"
	"sort"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// ErrTierLimitExceeded is returned by Chain.RunAgent when a provider's
// tier exceeds the required tier set via RequiredTier.
var ErrTierLimitExceeded = fmt.Errorf("runner: %w", errTierLimit)

var errTierLimit = fmt.Errorf("tier limit exceeded")

// Chain wraps multiple providers and falls through to the next on
// OutcomeUpstreamError. On success it records the winning provider's
// tier in Result.TierUsed.
type Chain struct {
	Providers []provider.Provider

	// RequiredTier constrains which providers may be used. If set, any
	// provider whose TierCostRank exceeds TierCostRank(RequiredTier) is
	// rejected at RunAgent time with ErrorSubcategory = "TIER_LIMIT_EXCEEDED".
	// Empty string means no restriction.
	RequiredTier string
}

// NewChain constructs a chain from the given providers in the order supplied.
func NewChain(providers ...provider.Provider) *Chain {
	return &Chain{Providers: providers}
}

// SortByCostRank reorders providers in the chain by Tier() ascending
// (cheaper first). Stable so equal-ranked providers retain their
// relative order.
func (c *Chain) SortByCostRank() {
	sort.SliceStable(c.Providers, func(i, j int) bool {
		return provider.TierCostRank(c.Providers[i].Tier()) <
			provider.TierCostRank(c.Providers[j].Tier())
	})
}

// Tier returns the lowest-cost tier across all providers in the chain —
// the cheapest tier the chain can attempt. Returns TierUnknown when empty.
func (c *Chain) Tier() string {
	best := provider.TierUnknown
	for _, p := range c.Providers {
		if provider.TierCostRank(p.Tier()) < provider.TierCostRank(best) {
			best = p.Tier()
		}
	}
	return best
}

// Name returns "chain(<p1>,<p2>,...)" — used for diagnostics only.
func (c *Chain) Name() string {
	names := ""
	for i, p := range c.Providers {
		if i > 0 {
			names += ","
		}
		names += p.Name()
	}
	return "chain(" + names + ")"
}

// ErrEmptyChain is returned by Chain.RunAgent when no providers are configured.
var ErrEmptyChain = fmt.Errorf("runner: chain has no providers")

// RunAgent iterates providers in order, falling through to the next when
// the current returns OutcomeUpstreamError. On success it stamps
// Result.TierUsed with the winning provider's Tier(). On RequiredTier
// violation it returns an error immediately without calling the provider.
func (c *Chain) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
	if len(c.Providers) == 0 {
		return &provider.Result{
			Outcome:          provider.OutcomeUpstreamError,
			ErrorCategory:    "ENVIRONMENT",
			ErrorSubcategory: "EMPTY_CHAIN",
			ErrorMessage:     "chain has no providers configured",
		}, ErrEmptyChain
	}

	var lastResult *provider.Result
	var lastErr error
	var prevProvider provider.Provider

	for _, p := range c.Providers {
		// Enforce tier limit.
		if c.RequiredTier != "" {
			if provider.TierCostRank(p.Tier()) > provider.TierCostRank(c.RequiredTier) {
				return &provider.Result{
					Outcome:          provider.OutcomeUpstreamError,
					ErrorCategory:    "ENVIRONMENT",
					ErrorSubcategory: "TIER_LIMIT_EXCEEDED",
					ErrorMessage: fmt.Sprintf(
						"provider %q (tier %q) exceeds required tier %q",
						p.Name(), p.Tier(), c.RequiredTier,
					),
				}, ErrTierLimitExceeded
			}
		}

		// m21 — Goal 2: paid-fallback gate. When falling THROUGH from a
		// previous provider into one whose tier rank is strictly greater
		// AND lands on api, require PROVIDER_ALLOW_PAID_FALLBACK=true so a
		// silent codex→claude(api) fallthrough can't generate a surprise
		// metered invoice. Same-tier and downward fallthrough are
		// untouched.
		if prevProvider != nil && p.Tier() == provider.TierAPI &&
			provider.TierCostRank(p.Tier()) > provider.TierCostRank(prevProvider.Tier()) &&
			os.Getenv("PROVIDER_ALLOW_PAID_FALLBACK") != "true" {
			return &provider.Result{
				Outcome:          provider.OutcomeUpstreamError,
				ErrorCategory:    "ENVIRONMENT",
				ErrorSubcategory: "PAID_FALLBACK_BLOCKED",
				ErrorMessage: fmt.Sprintf(
					"chain fallthrough from %q (tier %q) to %q (tier %q) would incur metered API spend; "+
						"set PROVIDER_ALLOW_PAID_FALLBACK=true to opt in",
					prevProvider.Name(), prevProvider.Tier(), p.Name(), p.Tier(),
				),
			}, nil
		}

		res, err := p.RunAgent(ctx, req)
		lastResult = res
		lastErr = err
		prevProvider = p

		if err != nil {
			// Process-level error — stop chain; don't fall through.
			return res, err
		}

		if res.Outcome == provider.OutcomeUpstreamError {
			// Retryable upstream failure — fall through to next provider.
			continue
		}

		// Success (or non-upstream failure) — record tier and stop.
		res.TierUsed = p.Tier()
		return res, nil
	}

	// All providers exhausted via UpstreamError fallthrough.
	return lastResult, lastErr
}
