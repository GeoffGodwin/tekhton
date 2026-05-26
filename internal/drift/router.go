package drift

import (
	"regexp"
	"strings"
)

// Disposition is the blocking/non-blocking verdict the Router emits.
type Disposition int

const (
	// DispositionBlocking artifacts get routed to HUMAN_ACTION_REQUIRED.md.
	// They demand human review before the next pipeline run is safe.
	DispositionBlocking Disposition = iota
	// DispositionNonBlocking artifacts get routed to NON_BLOCKING_LOG.md.
	// They are observations to be picked up by a later cleanup sweep.
	DispositionNonBlocking
)

// String for log readability.
func (d Disposition) String() string {
	switch d {
	case DispositionBlocking:
		return "blocking"
	case DispositionNonBlocking:
		return "non_blocking"
	default:
		return "unknown"
	}
}

// Artifact is one drift item up for routing — the smallest input the
// classifier needs.
type Artifact struct {
	// Header is the first line of the artifact (or a stamped summary
	// header the producer chose). The CI-failure sentinel is matched
	// against this field, not Body.
	Header string
	// Body is the remaining text of the artifact. Heuristic-pattern
	// matching scans Body for reviewer-style language tokens.
	Body string
}

// ciFailureSentinel matches "[FAIL]" or "[fail]" tokens — the explicit
// signal the m21-closeout drift entry flagged the bash heuristic for
// missing. The Go router takes this token as authoritative: any
// artifact whose Header contains it is Blocking, regardless of any
// reviewer-style language in Body that might otherwise drag it into
// the non-blocking bucket.
var ciFailureSentinel = regexp.MustCompile(`\[(?i:fail)\]`)

// nonBlockingPatterns is the heuristic chain inherited from the bash
// process_drift_artifacts function. Lines that match these (and which
// do NOT carry the CI-failure sentinel) classify as NonBlocking.
//
// The pattern set is intentionally short — overspecified regexes
// cause exactly the kind of false-negative the m21 closeout exposed.
// New tokens should be added with a paired regression test.
var nonBlockingPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\bnon[-_ ]blocking\b`),
	regexp.MustCompile(`(?i)\bobservation\b`),
	regexp.MustCompile(`(?i)\bdrift\b`),
	regexp.MustCompile(`(?i)\bnit\b`),
	regexp.MustCompile(`(?i)\bnitpick\b`),
}

// Route classifies a drift artifact into Blocking or NonBlocking.
//
// The m21 closeout drift entry described a CI test failure whose
// reviewer-style language tokens (the artifact mentioned "observation"
// in passing) caused the bash heuristic to misclassify it. The Go
// router rules the explicit CI-failure sentinel ahead of any
// heuristic — if the artifact carries [FAIL], it is Blocking, full
// stop. Otherwise the heuristic chain decides.
//
// The safe default is Blocking — if neither path matches, we err on
// the side of escalating to human review rather than burying the
// artifact in the non-blocking sweep.
func Route(a *Artifact) Disposition {
	if a == nil {
		return DispositionBlocking
	}
	if hasCIFailureSentinel(a) {
		return DispositionBlocking
	}
	if matchesNonBlockingPattern(a) {
		return DispositionNonBlocking
	}
	return DispositionBlocking
}

// hasCIFailureSentinel reports whether the artifact's Header contains
// the [FAIL] sentinel. Header-only scan is deliberate — the bash
// heuristic was too eager to drag Body content into the decision, and
// the m21 closeout fixture is the load-bearing example.
func hasCIFailureSentinel(a *Artifact) bool {
	return ciFailureSentinel.MatchString(a.Header)
}

// matchesNonBlockingPattern reports whether the artifact's Body
// (or Header — both are scanned) carries a reviewer-style non-
// blocking token. We accept either to keep the heuristic close to
// the bash behavior for pure observations (which the closeout
// fixture, deliberately, was not).
func matchesNonBlockingPattern(a *Artifact) bool {
	text := strings.Join([]string{a.Header, a.Body}, "\n")
	for _, p := range nonBlockingPatterns {
		if p.MatchString(text) {
			return true
		}
	}
	return false
}
