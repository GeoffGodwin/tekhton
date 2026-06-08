package scout

// Apply preserves both invariants from bash apply_scout_turn_limits:
//
//   - Floor invariant: no Recommended value below the configured floor
//     pulls the output below the floor. The Recommended-zero / negative /
//     parse-failure case keeps the floor as-is.
//   - Scaling invariant: a positive Recommended value above the floor is
//     reflected verbatim in the output. The scout's complexity-band
//     estimate is the authoritative budget when the scout has spoken.
//
// Concretely: out[role] = max(estimate.Recommended[role], floors[role])
// when Recommended > 0; out[role] = floors[role] otherwise.
//
// A nil estimate is treated as a parse failure for every role and returns
// the floors unchanged — defensive against orchestrator wiring bugs where
// scout was skipped or the report was unreadable.
//
// The DYNAMIC_TURNS_ENABLED gate (which decides whether to invoke the
// scout agent) is intentionally NOT consulted here. Per the m39.3 Watch
// For: "DYNAMIC_TURNS_ENABLED decides whether to scout, NOT whether to
// apply scout's recommendations." Once an estimate exists, Apply runs.
func Apply(e *Estimate, floors TurnLimits) TurnLimits {
	out := floors
	if e == nil {
		return out
	}
	if e.RecommendedCoder > 0 {
		out.Coder = maxInt(e.RecommendedCoder, floors.Coder)
	}
	if e.RecommendedReviewer > 0 {
		out.Reviewer = maxInt(e.RecommendedReviewer, floors.Reviewer)
	}
	if e.RecommendedTester > 0 {
		out.Tester = maxInt(e.RecommendedTester, floors.Tester)
	}
	return out
}

// maxInt avoids the runtime min/max generic call so the package builds
// against older Go toolchains. Trivial inline; kept named for callsite
// clarity.
func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
