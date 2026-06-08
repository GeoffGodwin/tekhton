package buildfix

import (
	"strings"

	tekerrors "github.com/geoffgodwin/tekhton/internal/errors"
)

// Classify is the M127 4-token routing decision wrapped for the m39.3
// continuation loop. It counts diagnostic lines via the m17 classifier
// (internal/errors), applies the m39.3 threshold scheme, and returns one
// of the four frozen Decision tokens.
//
// Decision rules (order matters):
//
//  1. noncode ratio ≥ 70% of total diagnostic lines → noncode_dominant
//  2. code ratio    ≥ 70% of total diagnostic lines → code_dominant
//  3. both code AND noncode lines present           → mixed_uncertain
//  4. unknown ratio ≥ 50% of total diagnostic lines → unknown_only
//  5. otherwise (empty / no signal / fall-through)  → code_dominant
//
// The empty-input → code_dominant fallback is the load-bearing m39.3
// semantic. Bash `stages/coder_buildfix.sh` initializes the decision
// variable to "code_dominant" before consulting `classify_routing_decision`
// — the Go port embeds that default here so the loop continues when the
// classifier produces no signal rather than save_exit-ing the operator.
func Classify(rawErrors string) Decision {
	if rawErrors == "" {
		return DecisionCodeDominant
	}

	codeCount, noncodeCount, unknownCount := classifyLineCounts(rawErrors)
	totalDiagnostic := codeCount + noncodeCount + unknownCount
	if totalDiagnostic == 0 {
		return DecisionCodeDominant
	}

	// Integer-percentage thresholds (×100 / total). Matches the
	// internal/errors percentile-threshold pattern.
	if noncodeCount*100/totalDiagnostic >= 70 {
		return DecisionNoncodeDominant
	}
	if codeCount*100/totalDiagnostic >= 70 {
		return DecisionCodeDominant
	}
	if codeCount > 0 && noncodeCount > 0 {
		return DecisionMixedUncertain
	}
	if unknownCount*100/totalDiagnostic >= 50 {
		return DecisionUnknownOnly
	}
	return DecisionCodeDominant
}

// classifyLineCounts walks rawErrors line-by-line and returns (code,
// noncode, unknown) counts using the m17 pattern registry. The noise
// filter (internal/errors.IsNonDiagnosticLine) is applied first so log
// chatter and progress bars do not skew the routing decision.
func classifyLineCounts(rawErrors string) (codeCount, noncodeCount, unknownCount int) {
	patterns := tekerrors.Patterns()
	for _, line := range strings.Split(rawErrors, "\n") {
		if tekerrors.IsNonDiagnosticLine(line) {
			continue
		}
		matched := false
		for _, p := range patterns {
			if p.Regex.MatchString(line) {
				if p.Category == "code" {
					codeCount++
				} else {
					noncodeCount++
				}
				matched = true
				break
			}
		}
		if !matched {
			unknownCount++
		}
	}
	return codeCount, noncodeCount, unknownCount
}
