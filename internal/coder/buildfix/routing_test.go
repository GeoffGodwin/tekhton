package buildfix

import (
	"strings"
	"testing"
)

// makeRoutingInput synthesizes a raw error stream with the requested counts
// of code-matching, noncode-matching, and unknown (but diagnostic) lines.
// The fixtures below depend on the m17 internal/errors pattern registry —
// the strings used here are deliberately chosen so a single registry
// pattern matches each line.
func makeRoutingInput(codeLines, noncodeLines, unknownLines int) string {
	var b strings.Builder
	for i := 0; i < codeLines; i++ {
		// Matches `error TS[0-9]+:` (category: code)
		b.WriteString("foo.ts(12,3): error TS1234: code line ")
		b.WriteString(itoa(i))
		b.WriteString("\n")
	}
	for i := 0; i < noncodeLines; i++ {
		// Matches `ECONNREFUSED.*5432` (category: service_dep — noncode)
		b.WriteString("net::ECONNREFUSED 127.0.0.1:5432 noncode line ")
		b.WriteString(itoa(i))
		b.WriteString("\n")
	}
	for i := 0; i < unknownLines; i++ {
		// Diagnostic-but-unmatched: contains "failure" so failureTermRE
		// keeps it past the noise filter, but matches no pattern.
		b.WriteString("unknown opaque failure marker ")
		b.WriteString(itoa(i))
		b.WriteString("\n")
	}
	return b.String()
}

// TestClassify_FixtureMatrix is the milestone Goal-2 acceptance criterion:
// the eight-row 4-token matrix table test. Every row asserts both the
// routing decision and (via makeRoutingInput) the line classifier's
// underlying counts, so any drift between the fixture intent and the m17
// registry surfaces as a test failure rather than silent miscategorization.
func TestClassify_FixtureMatrix(t *testing.T) {
	cases := []struct {
		name    string
		code    int
		noncode int
		unknown int
		want    Decision
	}{
		{"all code → code_dominant", 10, 0, 0, DecisionCodeDominant},
		{"all noncode → noncode_dominant", 0, 10, 0, DecisionNoncodeDominant},
		{"mixed 50/50 → mixed_uncertain", 5, 5, 0, DecisionMixedUncertain},
		{"mostly unknown (1 code + 9 unknown) → unknown_only", 1, 0, 9, DecisionUnknownOnly},
		{"noncode at 70% threshold → noncode_dominant", 3, 7, 0, DecisionNoncodeDominant},
		{"noncode at 69% (just under) → mixed_uncertain", 4, 7, 0, DecisionMixedUncertain},
		{"code-only with noise (80% code) → code_dominant", 8, 0, 2, DecisionCodeDominant},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			input := makeRoutingInput(c.code, c.noncode, c.unknown)

			// Self-check: the input must classify to the requested counts.
			// A red here means a fixture string drifted away from the m17
			// registry, not that Classify is wrong.
			gotCode, gotNon, gotUnk := classifyLineCounts(input)
			if gotCode != c.code || gotNon != c.noncode || gotUnk != c.unknown {
				t.Fatalf("fixture self-check: classifyLineCounts=%d/%d/%d, want %d/%d/%d",
					gotCode, gotNon, gotUnk, c.code, c.noncode, c.unknown)
			}

			got := Classify(input)
			if got != c.want {
				t.Fatalf("Classify(...)=%q, want %q", got, c.want)
			}
		})
	}
}

// TestClassify_EmptyInputFallback pins the m39.3 Watch For semantic:
// empty input → code_dominant (NOT unknown_only). The bash caller
// initializes `decision="code_dominant"` before consulting the classifier,
// so the Go wrapper must preserve that default rather than returning the
// upstream m17 "no signal" verdict.
func TestClassify_EmptyInputFallback(t *testing.T) {
	if got := Classify(""); got != DecisionCodeDominant {
		t.Fatalf("Classify(\"\") = %q, want %q", got, DecisionCodeDominant)
	}
}

// TestClassify_NoSignalFallback pins the same default for input that
// contains only non-diagnostic noise (no failure terms, all noise-pattern
// matches). The m39.3 loop must still proceed in this case rather than
// save_exit-ing the operator.
func TestClassify_NoSignalFallback(t *testing.T) {
	// `[1/8] starting` matches a noise-pattern, has no failure term, so
	// IsNonDiagnosticLine returns true → total diagnostic count = 0.
	noise := "[1/8] starting\n[2/8] running\n"
	if got := Classify(noise); got != DecisionCodeDominant {
		t.Fatalf("Classify(noise) = %q, want %q", got, DecisionCodeDominant)
	}
}
