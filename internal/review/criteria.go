package review

import (
	"fmt"
	"regexp"
	"strings"
)

// CriterionDecision is the per-acceptance-criterion verdict the reviewer
// renders in the "## Acceptance Criteria Verdicts" section (S3).
type CriterionDecision string

const (
	CriterionMet          CriterionDecision = "MET"
	CriterionNotMet       CriterionDecision = "NOT_MET"
	CriterionUnverifiable CriterionDecision = "UNVERIFIABLE"
)

// CriterionVerdict is one row of the "## Acceptance Criteria Verdicts" section:
//
//   - <criterion text> — MET|NOT_MET|UNVERIFIABLE — <evidence>
//
// Evidence is optional. The delimiter tolerates em-dash or hyphen with
// surrounding whitespace (matching the ACP row convention).
type CriterionVerdict struct {
	Criterion string
	Decision  CriterionDecision
	Evidence  string
}

// criterionRowRE: "- <criterion> <delim> <DECISION> [<delim> <evidence>]".
// Decision tokens carry an underscore (NOT_MET) so the token class includes it.
// Case-insensitive; evidence group is optional.
var criterionRowRE = regexp.MustCompile(
	`(?i)^-\s*(.+?)\s+[—-]\s+(MET|NOT_MET|UNVERIFIABLE)\b\s*(?:[—-]\s*(.*?))?\s*$`)

// parseCriterionRows extracts CriterionVerdict rows from the section body.
// Non-matching lines (and the "None" sentinel) are skipped.
func parseCriterionRows(lines []string) []CriterionVerdict {
	var out []CriterionVerdict
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if t == "" || noneSentinelRE.MatchString(t) {
			continue
		}
		m := criterionRowRE.FindStringSubmatch(t)
		if m == nil {
			continue
		}
		out = append(out, CriterionVerdict{
			Criterion: strings.TrimSpace(m[1]),
			Decision:  CriterionDecision(strings.ToUpper(strings.TrimSpace(m[2]))),
			Evidence:  strings.TrimSpace(m[3]),
		})
	}
	return out
}

// UnmetCriteria returns the criteria the reviewer marked NOT_MET. UNVERIFIABLE
// is intentionally NOT treated as a failure here — the reviewer is telling us
// it could not confirm, which is a softer signal than an explicit miss.
func (r *Report) UnmetCriteria() []CriterionVerdict {
	var out []CriterionVerdict
	for _, c := range r.CriteriaVerdicts {
		if c.Decision == CriterionNotMet {
			out = append(out, c)
		}
	}
	return out
}

// EnforceUnmetCriteria is the S3 milestone-purpose gate: a NOT_MET acceptance
// criterion means the milestone's stated purpose is not satisfied, regardless
// of what the reviewer wrote in Verdict/Blockers. Each unmet criterion is
// folded into a Complex Blocker (so the existing senior-rework routing fires)
// and an APPROVED verdict is downgraded to CHANGES_REQUIRED. Returns the count
// of unmet criteria enforced (0 = no-op).
func (r *Report) EnforceUnmetCriteria() int {
	unmet := r.UnmetCriteria()
	if len(unmet) == 0 {
		return 0
	}
	for _, c := range unmet {
		msg := "Acceptance criterion not met: " + c.Criterion
		if c.Evidence != "" {
			msg += " (" + c.Evidence + ")"
		}
		r.ComplexBlockers = append(r.ComplexBlockers, msg)
	}
	if r.IsApproved() {
		r.Verdict = VerdictChangesRequired
	}
	return len(unmet)
}

// CriteriaSummary renders a one-line MET/NOT_MET/UNVERIFIABLE tally for logs.
func (r *Report) CriteriaSummary() string {
	var met, notMet, unver int
	for _, c := range r.CriteriaVerdicts {
		switch c.Decision {
		case CriterionMet:
			met++
		case CriterionNotMet:
			notMet++
		case CriterionUnverifiable:
			unver++
		}
	}
	return fmt.Sprintf("%d met, %d not-met, %d unverifiable", met, notMet, unver)
}
