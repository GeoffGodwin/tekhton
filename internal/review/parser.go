// Package review ports the review-stage pure-logic helpers from
// stages/review.sh and stages/review_helpers.sh. m37.1 lands the parser,
// cycle-budget bookkeeping, and specialist-block helpers; the bash stage
// loop continues to drive things until m37.2 ports the orchestration.
//
// The package is a leaf: no imports from internal/orchestrate or
// internal/stagerunner, and no agent-invocation surface. Parser callers get a
// Report value back; the rest of the pipeline decides what to do with it.
package review

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

// Verdict is the four-token review verdict vocabulary. Bash callers compare
// against the raw strings; the Go consumers use these constants.
type Verdict string

const (
	VerdictApproved          Verdict = "APPROVED"
	VerdictApprovedWithNotes Verdict = "APPROVED_WITH_NOTES"
	VerdictChangesRequired   Verdict = "CHANGES_REQUIRED"
	VerdictReplanRequired    Verdict = "REPLAN_REQUIRED"
	VerdictUnknown           Verdict = ""
)

// ACPDecision is the per-ACP verdict the reviewer renders in the
// "## ACP Verdicts" section.
type ACPDecision string

const (
	ACPAccept ACPDecision = "ACCEPT"
	ACPReject ACPDecision = "REJECT"
	ACPModify ACPDecision = "MODIFY"
)

// ACPVerdict is one row of the "## ACP Verdicts" section.
type ACPVerdict struct {
	Name      string
	Decision  ACPDecision
	Rationale string
}

// Report is the structured form of a REVIEWER_REPORT.md.
type Report struct {
	Verdict           Verdict
	ComplexBlockers   []string
	SimpleBlockers    []string
	NonBlockingNotes  []string
	CoverageGaps      []string
	ACPVerdicts       []ACPVerdict
	DriftObservations []string
	// SpecialistSection is captured if "## Specialist Blockers" is present;
	// the bash helper appends that section to the report. Empty when absent.
	SpecialistSection string
	// RawBody is the byte-for-byte file contents, used by downstream
	// forensics (the dashboard subsystem emits this to JSON, the bash
	// pipeline echoes accepted ACPs from it).
	RawBody string
}

// ParseReviewerReport opens path and returns the parsed Report. Returns a
// wrapped open error when the file cannot be read; a successful read whose
// body is malformed (missing verdict, missing sections) returns a Report
// with zero-value fields and a nil error — the caller decides what to do
// with that.
func ParseReviewerReport(path string) (*Report, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("review: open report: %w", err)
	}
	r := parseBody(string(data))
	r.RawBody = string(data)
	return r, nil
}

// ParseReader is an io.Reader variant used by tests that build fixtures in
// memory. RawBody is populated from the bytes the reader yields.
func ParseReader(rd io.Reader) (*Report, error) {
	data, err := io.ReadAll(rd)
	if err != nil {
		return nil, fmt.Errorf("review: read report: %w", err)
	}
	r := parseBody(string(data))
	r.RawBody = string(data)
	return r, nil
}

// Section name → Report field mapping. The bash parser uses awk between
// `## Complex Blockers` and the next `## ` heading; the Go parser does the
// same via a state-machine line scanner. Headings here MUST match bash
// exactly — they are operator-visible.
const (
	secComplexBlockers    = "## Complex Blockers"
	secSimpleBlockers     = "## Simple Blockers"
	secNonBlockingNotes   = "## Non-Blocking Notes"
	secCoverageGaps       = "## Coverage Gaps"
	secACPVerdicts        = "## ACP Verdicts"
	secDriftObservations  = "## Drift Observations"
	secSpecialistBlockers = "## Specialist Blockers"
	secVerdict            = "## Verdict"
)

// noneSentinelRE mirrors bash `grep -qE "^\-?\s*None\s*$"`: optional leading
// dash, optional whitespace, literal "None", optional trailing whitespace.
// Case-sensitive — lower-case "none" does NOT match (the agent prompt insists
// on the exact word). The metrics subsystem keys off this exact predicate.
var noneSentinelRE = regexp.MustCompile(`^-?\s*None\s*$`)

// acpRowRE matches `- ACP: <name> <delim> <DECISION> <delim> <rationale>` —
// lenient on em-dash (—) vs hyphen (-) as delimiter, but REQUIRES whitespace
// around the delimiter so the regex does not split an in-name hyphen
// (e.g. "parser-leaf-discipline"). Decision token match is case-insensitive
// in the body and we normalize via strings.ToUpper before classification.
var acpRowRE = regexp.MustCompile(`^-\s*ACP:\s*(.+?)\s+[—-]\s+([A-Za-z]+)\s+[—-]\s+(.+?)\s*$`)

func parseBody(body string) *Report {
	r := &Report{}

	currentSection := ""
	accum := []string{}

	flush := func() {
		if currentSection == "" {
			return
		}
		switch currentSection {
		case secComplexBlockers:
			r.ComplexBlockers = bulletList(accum)
		case secSimpleBlockers:
			r.SimpleBlockers = bulletList(accum)
		case secNonBlockingNotes:
			r.NonBlockingNotes = bulletList(accum)
		case secCoverageGaps:
			r.CoverageGaps = bulletList(accum)
		case secACPVerdicts:
			r.ACPVerdicts = parseACPRows(accum)
		case secDriftObservations:
			r.DriftObservations = bulletList(accum)
		case secSpecialistBlockers:
			r.SpecialistSection = strings.TrimRight(strings.Join(accum, "\n"), "\n")
		case secVerdict:
			// Verdict heading-anchored extraction: the first non-blank line
			// after the heading. Bash uses `tail -1 | tr -d '[:space:]'`;
			// matched here by trimming + checking the first non-blank.
			r.Verdict = extractVerdictFromAccum(accum)
		}
		accum = accum[:0]
	}

	sc := bufio.NewScanner(strings.NewReader(body))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if isH2Heading(line) {
			flush()
			currentSection = canonicalHeading(line)
			continue
		}
		if currentSection != "" {
			accum = append(accum, line)
		}
	}
	flush()

	// Inline-fallback verdict extraction. The bash code triggers when the
	// heading-anchored extraction returns empty or the literal "##Verdict"
	// sentinel (a one-line "## Verdict APPROVED" pattern is collapsed by the
	// bash `tr -d '[:space:]'` to "##VerdictAPPROVED" — the bash code treats
	// "##Verdict" as the same failure mode). The Go heading-anchored path
	// gives us an empty Verdict in that case (because there are no body
	// lines under the heading). Treat empty as the fallback trigger.
	if r.Verdict == VerdictUnknown {
		r.Verdict = inlineVerdictFallback(body)
	}

	return r
}

// extractVerdictFromAccum picks the first non-blank line, then matches it
// against the four canonical tokens. Anything outside the four → unknown.
func extractVerdictFromAccum(lines []string) Verdict {
	for _, l := range lines {
		trimmed := strings.TrimSpace(l)
		if trimmed == "" {
			continue
		}
		// Bash uses `tr -d '[:space:]'` which strips ALL whitespace, but the
		// expected verdict tokens have no embedded whitespace. TrimSpace is
		// sufficient for the heading-anchored case.
		upper := strings.ToUpper(trimmed)
		switch Verdict(upper) {
		case VerdictApproved, VerdictApprovedWithNotes, VerdictChangesRequired, VerdictReplanRequired:
			return Verdict(upper)
		}
		// If the first non-blank line is something else (e.g. a bold-wrapped
		// "**APPROVED**" the inline-fallback will catch it), don't keep
		// scanning — the heading-anchored extraction only looks at the
		// line immediately after the heading per bash semantics.
		return VerdictUnknown
	}
	return VerdictUnknown
}

// inlineVerdictFallback scans the body for the four tokens in priority order
// (REPLAN_REQUIRED > APPROVED_WITH_NOTES > CHANGES_REQUIRED > APPROVED). The
// regex's alternation order IS the priority; FindString returns the first
// (leftmost) match, but we need priority over leftmost — so iterate by
// priority order and pick the first hit.
func inlineVerdictFallback(body string) Verdict {
	upperBody := strings.ToUpper(body)
	for _, tok := range []Verdict{VerdictReplanRequired, VerdictApprovedWithNotes, VerdictChangesRequired, VerdictApproved} {
		if strings.Contains(upperBody, string(tok)) {
			return tok
		}
	}
	return VerdictUnknown
}

// bulletList parses accum into the section's bullet-row strings. Drops the
// "None" sentinel rows (so a section consisting of a single "- None" line
// yields an empty slice). Keeps each kept row's text WITHOUT the leading
// "- " marker — matches the metric subsystem's expected per-row payload.
func bulletList(accum []string) []string {
	out := []string{}
	for _, line := range accum {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if noneSentinelRE.MatchString(trimmed) {
			continue
		}
		if strings.HasPrefix(trimmed, "- ") {
			out = append(out, strings.TrimSpace(strings.TrimPrefix(trimmed, "- ")))
			continue
		}
		// Continuation lines under a previous bullet (rare but the bash
		// `grep -c "^- "` predicate ignores them). Track them as separate
		// strings so RawBody round-trip + dashboard rendering still works.
		out = append(out, trimmed)
	}
	return out
}

// parseACPRows pulls each "- ACP: name <delim> DECISION <delim> rationale"
// line into a structured ACPVerdict. Rows that don't match the expected
// shape are skipped (bash awk skipped them too — it printed lines matching
// /ACCEPT/ only, and a malformed row would have failed the regex match).
func parseACPRows(accum []string) []ACPVerdict {
	out := []ACPVerdict{}
	for _, line := range accum {
		m := acpRowRE.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		dec := ACPDecision(strings.ToUpper(strings.TrimSpace(m[2])))
		switch dec {
		case ACPAccept, ACPReject, ACPModify:
			// recognized decision
		default:
			continue
		}
		out = append(out, ACPVerdict{
			Name:      strings.TrimSpace(m[1]),
			Decision:  dec,
			Rationale: strings.TrimSpace(m[3]),
		})
	}
	return out
}

func isH2Heading(line string) bool {
	return strings.HasPrefix(line, "## ")
}

// canonicalHeading returns the section name we key off, trimmed of trailing
// whitespace. The match against the secXxx constants is exact-prefix so a
// heading like "## Complex Blockers" matches, while "## Complex Blockers (3)"
// also routes to secComplexBlockers — the bash awk uses `/^## Complex Blockers/`
// which is also a prefix match.
func canonicalHeading(line string) string {
	trimmed := strings.TrimRight(line, " \t")
	for _, h := range []string{
		secComplexBlockers, secSimpleBlockers, secNonBlockingNotes,
		secCoverageGaps, secACPVerdicts, secDriftObservations,
		secSpecialistBlockers, secVerdict,
	} {
		if strings.HasPrefix(trimmed, h) {
			return h
		}
	}
	return trimmed
}

// HasComplexBlockers mirrors the bash `HAS_COMPLEX=$(grep -c "^- " ...)`
// shape — returns the count rather than a bool so callers can render
// "complex: N" lines without re-counting.
func (r *Report) HasComplexBlockers() int { return len(r.ComplexBlockers) }

// HasSimpleBlockers mirrors the bash `HAS_SIMPLE` count.
func (r *Report) HasSimpleBlockers() int { return len(r.SimpleBlockers) }

// IsApproved is true for APPROVED and APPROVED_WITH_NOTES — the two verdicts
// the bash loop treats as "exit the rework loop, proceed to specialist /
// tester". Matches `if [[ "$VERDICT" = "APPROVED" || ... ]]` at review.sh:373.
func (r *Report) IsApproved() bool {
	return r.Verdict == VerdictApproved || r.Verdict == VerdictApprovedWithNotes
}

// AcceptedACPs returns the subset of ACPVerdicts whose Decision is ACCEPT —
// the slice the bash `awk '/^## ACP Verdicts/.../ACCEPT/{print}'` produces.
func (r *Report) AcceptedACPs() []ACPVerdict {
	out := []ACPVerdict{}
	for _, a := range r.ACPVerdicts {
		if a.Decision == ACPAccept {
			out = append(out, a)
		}
	}
	return out
}
