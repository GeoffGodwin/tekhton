package review

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixtureCase is one row of the table-driven parser test. Each row keys on a
// fixture file under testdata/ and asserts the parsed Report's shape.
type fixtureCase struct {
	name             string // file basename without .md
	wantVerdict      Verdict
	wantComplex      int
	wantSimple       int
	wantNotesAtLeast int // notes count varies a bit; assert lower bound
	wantACPs         int
	wantApproved     bool
	wantSpecialist   bool // SpecialistSection non-empty
}

func TestParseReviewerReport_Fixtures(t *testing.T) {
	cases := []fixtureCase{
		{
			name:         "approved",
			wantVerdict:  VerdictApproved,
			wantComplex:  0,
			wantSimple:   0,
			wantApproved: true,
		},
		{
			name:             "approved_with_notes",
			wantVerdict:      VerdictApprovedWithNotes,
			wantComplex:      0,
			wantSimple:       0,
			wantNotesAtLeast: 3,
			wantApproved:     true,
		},
		{
			name:         "changes_complex_only",
			wantVerdict:  VerdictChangesRequired,
			wantComplex:  2,
			wantSimple:   0,
			wantApproved: false,
		},
		{
			name:         "changes_simple_only",
			wantVerdict:  VerdictChangesRequired,
			wantComplex:  0,
			wantSimple:   3,
			wantApproved: false,
		},
		{
			name:         "changes_mixed",
			wantVerdict:  VerdictChangesRequired,
			wantComplex:  2,
			wantSimple:   2,
			wantApproved: false,
		},
		{
			name:         "replan_required",
			wantVerdict:  VerdictReplanRequired,
			wantComplex:  1,
			wantSimple:   0,
			wantApproved: false,
		},
		{
			name:         "inline_verdict_fallback",
			wantVerdict:  VerdictApproved,
			wantComplex:  0,
			wantSimple:   0,
			wantApproved: true,
		},
		{
			name:         "acp_verdicts_present",
			wantVerdict:  VerdictApprovedWithNotes,
			wantComplex:  0,
			wantSimple:   0,
			wantACPs:     3,
			wantApproved: true,
		},
		{
			name:           "specialist_blockers_present",
			wantVerdict:    VerdictChangesRequired,
			wantComplex:    0,
			wantSimple:     0,
			wantSpecialist: true,
			wantApproved:   false,
		},
		{
			name:         "synthesized_at_max",
			wantVerdict:  VerdictApprovedWithNotes,
			wantApproved: true,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join("testdata", tc.name+".md")
			r, err := ParseReviewerReport(path)
			if err != nil {
				t.Fatalf("ParseReviewerReport(%s) error: %v", path, err)
			}
			if r.Verdict != tc.wantVerdict {
				t.Errorf("Verdict = %q, want %q", r.Verdict, tc.wantVerdict)
			}
			if tc.wantComplex != 0 || tc.name != "synthesized_at_max" {
				if got := r.HasComplexBlockers(); got != tc.wantComplex && tc.name != "synthesized_at_max" {
					t.Errorf("HasComplexBlockers() = %d, want %d", got, tc.wantComplex)
				}
			}
			if tc.wantSimple != 0 || tc.name != "synthesized_at_max" {
				if got := r.HasSimpleBlockers(); got != tc.wantSimple && tc.name != "synthesized_at_max" {
					t.Errorf("HasSimpleBlockers() = %d, want %d", got, tc.wantSimple)
				}
			}
			if got := r.IsApproved(); got != tc.wantApproved {
				t.Errorf("IsApproved() = %v, want %v", got, tc.wantApproved)
			}
			if tc.wantNotesAtLeast > 0 {
				if got := len(r.NonBlockingNotes); got < tc.wantNotesAtLeast {
					t.Errorf("len(NonBlockingNotes) = %d, want >= %d", got, tc.wantNotesAtLeast)
				}
			}
			if tc.wantACPs > 0 {
				if got := len(r.ACPVerdicts); got != tc.wantACPs {
					t.Errorf("len(ACPVerdicts) = %d, want %d", got, tc.wantACPs)
				}
			}
			if tc.wantSpecialist {
				if r.SpecialistSection == "" {
					t.Errorf("SpecialistSection is empty; expected non-empty")
				}
			}
		})
	}
}

func TestParseReviewerReport_RawBody_RoundTrip(t *testing.T) {
	for _, name := range []string{"approved", "changes_mixed", "synthesized_at_max"} {
		path := filepath.Join("testdata", name+".md")
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read fixture %s: %v", path, err)
		}
		r, err := ParseReviewerReport(path)
		if err != nil {
			t.Fatalf("ParseReviewerReport(%s): %v", path, err)
		}
		if r.RawBody != string(raw) {
			t.Errorf("RawBody for %s did not round-trip byte-for-byte (got %d bytes, file is %d)",
				name, len(r.RawBody), len(raw))
		}
	}
}

func TestParseReviewerReport_AcceptedACPs(t *testing.T) {
	r, err := ParseReviewerReport(filepath.Join("testdata", "acp_verdicts_present.md"))
	if err != nil {
		t.Fatalf("ParseReviewerReport: %v", err)
	}
	accepted := r.AcceptedACPs()
	if len(accepted) != 1 {
		t.Fatalf("len(AcceptedACPs) = %d, want 1", len(accepted))
	}
	if accepted[0].Name != "parser-leaf-discipline" {
		t.Errorf("AcceptedACPs[0].Name = %q, want %q", accepted[0].Name, "parser-leaf-discipline")
	}
	if accepted[0].Decision != ACPAccept {
		t.Errorf("AcceptedACPs[0].Decision = %q, want %q", accepted[0].Decision, ACPAccept)
	}
}

func TestParseReviewerReport_ACPVerdictsOrder(t *testing.T) {
	r, err := ParseReviewerReport(filepath.Join("testdata", "acp_verdicts_present.md"))
	if err != nil {
		t.Fatalf("ParseReviewerReport: %v", err)
	}
	if len(r.ACPVerdicts) != 3 {
		t.Fatalf("len(ACPVerdicts) = %d, want 3", len(r.ACPVerdicts))
	}
	wantDecisions := []ACPDecision{ACPAccept, ACPReject, ACPModify}
	for i, want := range wantDecisions {
		if r.ACPVerdicts[i].Decision != want {
			t.Errorf("ACPVerdicts[%d].Decision = %q, want %q", i, r.ACPVerdicts[i].Decision, want)
		}
	}
}

func TestParseReviewerReport_OpenError(t *testing.T) {
	_, err := ParseReviewerReport(filepath.Join("testdata", "does_not_exist.md"))
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
	}
	if !strings.Contains(err.Error(), "review: open report") {
		t.Errorf("error message = %q, want prefix %q", err.Error(), "review: open report")
	}
}

func TestParseReader_InMemoryBody(t *testing.T) {
	body := strings.Join([]string{
		"# Reviewer Report",
		"",
		"## Verdict",
		"CHANGES_REQUIRED",
		"",
		"## Complex Blockers",
		"- one thing",
		"- two thing",
		"",
		"## Simple Blockers",
		"- None",
		"",
	}, "\n")
	r, err := ParseReader(strings.NewReader(body))
	if err != nil {
		t.Fatalf("ParseReader: %v", err)
	}
	if r.Verdict != VerdictChangesRequired {
		t.Errorf("Verdict = %q, want %q", r.Verdict, VerdictChangesRequired)
	}
	if r.HasComplexBlockers() != 2 {
		t.Errorf("HasComplexBlockers() = %d, want 2", r.HasComplexBlockers())
	}
	if r.HasSimpleBlockers() != 0 {
		t.Errorf("HasSimpleBlockers() = %d, want 0 (the 'None' sentinel should drop the row)", r.HasSimpleBlockers())
	}
	if r.RawBody != body {
		t.Errorf("RawBody did not round-trip (got %d bytes, body is %d)", len(r.RawBody), len(body))
	}
}

func TestInlineVerdictFallback_Priority(t *testing.T) {
	// A body that contains both APPROVED and CHANGES_REQUIRED tokens but no
	// "## Verdict" heading — the bash priority order is REPLAN_REQUIRED >
	// APPROVED_WITH_NOTES > CHANGES_REQUIRED > APPROVED, so this must
	// classify as CHANGES_REQUIRED (the higher-priority match), NOT
	// APPROVED (even though "APPROVED" appears first in the body).
	body := `# Reviewer Report

## Summary
The reviewer says the code is mostly APPROVED but there are some lingering
items that mean the verdict really is CHANGES_REQUIRED for this cycle.
`
	r, err := ParseReader(strings.NewReader(body))
	if err != nil {
		t.Fatalf("ParseReader: %v", err)
	}
	if r.Verdict != VerdictChangesRequired {
		t.Errorf("Verdict = %q, want %q (priority order)", r.Verdict, VerdictChangesRequired)
	}
}

func TestInlineVerdictFallback_ReplanWins(t *testing.T) {
	// A body that contains APPROVED, CHANGES_REQUIRED, and REPLAN_REQUIRED —
	// REPLAN_REQUIRED has the highest priority and must win.
	body := `# Reviewer Report

Some APPROVED here, some CHANGES_REQUIRED there, but ultimately
REPLAN_REQUIRED because the scope has drifted.
`
	r, err := ParseReader(strings.NewReader(body))
	if err != nil {
		t.Fatalf("ParseReader: %v", err)
	}
	if r.Verdict != VerdictReplanRequired {
		t.Errorf("Verdict = %q, want %q (REPLAN_REQUIRED is top priority)", r.Verdict, VerdictReplanRequired)
	}
}

func TestParseACPRows_LenientOnDashes(t *testing.T) {
	// Mix em-dash and hyphen delimiters — both must parse.
	body := strings.Join([]string{
		"## Verdict",
		"APPROVED",
		"",
		"## ACP Verdicts",
		"- ACP: em-dash-case — ACCEPT — uses em-dashes",
		"- ACP: hyphen-case - ACCEPT - uses hyphens",
		"- ACP: malformed-row no decision here",
		"- ACP: unknown-decision - WAFFLE - bogus decision token",
	}, "\n") + "\n"
	r, err := ParseReader(strings.NewReader(body))
	if err != nil {
		t.Fatalf("ParseReader: %v", err)
	}
	if len(r.ACPVerdicts) != 2 {
		t.Fatalf("len(ACPVerdicts) = %d, want 2 (malformed and unknown rows dropped)", len(r.ACPVerdicts))
	}
}

func TestNoneSentinelRE_CaseSensitive(t *testing.T) {
	// The bash regex `^\-?\s*None\s*$` is case-sensitive — lower-case "none"
	// should NOT match. With "- none" as the only line, bulletList won't drop
	// it as the sentinel, and the bash `grep -c "^- "` would count 1.
	body := strings.Join([]string{
		"## Complex Blockers",
		"- none",
		"",
		"## Simple Blockers",
		"- None",
	}, "\n") + "\n"
	r, err := ParseReader(strings.NewReader(body))
	if err != nil {
		t.Fatalf("ParseReader: %v", err)
	}
	if r.HasComplexBlockers() != 1 {
		t.Errorf("HasComplexBlockers() = %d, want 1 (lower-case 'none' is not the sentinel)", r.HasComplexBlockers())
	}
	if r.HasSimpleBlockers() != 0 {
		t.Errorf("HasSimpleBlockers() = %d, want 0 ('None' is the sentinel)", r.HasSimpleBlockers())
	}
}

func TestNoneSentinel_OptionalDashAndWhitespace(t *testing.T) {
	// The bash regex accepts an optional leading dash and optional surrounding
	// whitespace. All these forms should be treated as sentinel.
	for _, sentinel := range []string{
		"None",
		"- None",
		"-None",
		" - None ",
		"  None  ",
	} {
		body := "## Complex Blockers\n" + sentinel + "\n"
		r, err := ParseReader(strings.NewReader(body))
		if err != nil {
			t.Fatalf("ParseReader for sentinel %q: %v", sentinel, err)
		}
		if r.HasComplexBlockers() != 0 {
			t.Errorf("sentinel %q: HasComplexBlockers() = %d, want 0", sentinel, r.HasComplexBlockers())
		}
	}
}
