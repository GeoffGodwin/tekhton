package review

// CycleBudget tracks the review-cycle bookkeeping the M37.2 stage loop will
// consume. Value type — Increment mutates the receiver via pointer, the rest
// are pure. The "Current == 0 before first cycle" convention matches bash
// (review.sh:39 inits REVIEW_CYCLE=0; review.sh:44 increments at the top of
// each iteration, so the first cycle runs with Current == 1).
type CycleBudget struct {
	Current int
	Max     int
}

// Increment advances Current by one. Callers invoke at the top of each
// review-loop iteration; the post-increment value is the human-facing cycle
// number ("cycle 1/3").
func (c *CycleBudget) Increment() { c.Current++ }

// Remaining is the number of cycles still available, never negative.
func (c CycleBudget) Remaining() int {
	r := c.Max - c.Current
	if r < 0 {
		return 0
	}
	return r
}

// IsLastCycle is true when Current == Max — the current cycle is the final
// one. Used by bash review.sh:271 to decide whether to spin a rework or
// save state for resume.
func (c CycleBudget) IsLastCycle() bool { return c.Current == c.Max && c.Max > 0 }

// IsExhausted is true when no more cycles can run. The bash equivalent is
// `[ "$REVIEW_CYCLE" -ge "${MAX_REVIEW_CYCLES:-3}" ]` after the post-pass
// branch realizes specialist blockers remain (review_helpers.sh:21).
func (c CycleBudget) IsExhausted() bool { return c.Max > 0 && c.Current >= c.Max }

// BumpFromUsage encapsulates review.sh:130-148 — "if the reviewer used >= 85%
// of its allocated turns, bump the limit by 25%, clamped to cap". Returns
// (newLimit, bumped). When used == 0 or limit == 0, returns (limit, false).
// When the calculated bump is <= limit (already at or above cap), returns
// (limit, false). cap defaults to 60 if 0 is passed (matches the bash
// `${REVIEWER_MAX_TURNS_CAP:-60}` parameter default).
//
// Note: the receiver is NOT mutated — the caller decides whether to apply
// the bump. The CycleBudget tracks cycle counts, not turn budgets; they are
// distinct quantities that the bash version conflated by stuffing both
// behind the same `REVIEW_CYCLE` global. The Go port keeps them separate.
func (c CycleBudget) BumpFromUsage(used, limit, cap int) (newLimit int, bumped bool) {
	if used == 0 || limit == 0 {
		return limit, false
	}
	if cap == 0 {
		cap = 60
	}
	usagePct := used * 100 / limit
	if usagePct < 85 {
		return limit, false
	}
	bumpedVal := limit * 125 / 100
	if bumpedVal > cap {
		bumpedVal = cap
	}
	if bumpedVal <= limit {
		return limit, false
	}
	return bumpedVal, true
}
