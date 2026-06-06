package review

import "strings"

// SpecialistDecision is the outcome of the post-loop specialist branch in
// stages/review_helpers.sh — Passthrough means no specialist blockers were
// found, Rework means blockers exist and cycles remain (the bash calls
// `_route_specialist_rework`), Exhausted means blockers exist but no cycles
// remain (the bash version writes state with exit reason "specialist_blockers"
// and exits 1).
type SpecialistDecision int

const (
	SpecialistPassthrough SpecialistDecision = iota
	SpecialistRework
	SpecialistExhausted
)

// HasSpecialistBlockers mirrors bash `has_specialist_blockers` — true when
// the SPECIALIST_BLOCKERS env value contains at least one non-whitespace,
// non-"None" line. Empty string, all-whitespace, all-"none" → false.
// Match is case-insensitive on the "None" sentinel to be lenient against
// downstream specialists that might emit lower-case.
func HasSpecialistBlockers(env string) bool {
	for _, line := range strings.Split(env, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.EqualFold(trimmed, "none") {
			continue
		}
		// Also accept "- None" / "-None" sentinel rows the reviewer might
		// emit if the specialist returns its blockers in the same shape as
		// the main reviewer's Complex Blockers section.
		stripped := strings.TrimSpace(strings.TrimPrefix(trimmed, "-"))
		if strings.EqualFold(stripped, "none") {
			continue
		}
		return true
	}
	return false
}

// FormatSpecialistSection returns the block bash _route_specialist_rework
// appends to REVIEWER_REPORT.md. The bash sequence at review_helpers.sh:11-17:
//
//	{
//	    echo ""
//	    echo "## Specialist Blockers"
//	    echo "$SPECIALIST_BLOCKERS"
//	} >> "${REVIEWER_REPORT_FILE}"
//
// Produces, in bytes, "\n## Specialist Blockers\n<env>\n". When env already
// ends in a newline, we don't double it.
func FormatSpecialistSection(env string) string {
	var b strings.Builder
	b.WriteString("\n## Specialist Blockers\n")
	b.WriteString(env)
	if !strings.HasSuffix(env, "\n") {
		b.WriteString("\n")
	}
	return b.String()
}

// RouteSpecialistRework returns whether the post-loop specialist branch
// should spin a rework, exhaust, or pass through. The caller invokes the
// senior coder + reviewer pass — this helper only classifies.
//
// Branches mirror bash review_helpers.sh:
//   - no blockers          → Passthrough (skip _route_specialist_rework body)
//   - blockers + exhausted → Exhausted (bash writes pipeline state and exits)
//   - blockers + cycles    → Rework    (bash spins coder + reviewer)
func RouteSpecialistRework(env string, budget CycleBudget) SpecialistDecision {
	if !HasSpecialistBlockers(env) {
		return SpecialistPassthrough
	}
	if budget.IsExhausted() {
		return SpecialistExhausted
	}
	return SpecialistRework
}
