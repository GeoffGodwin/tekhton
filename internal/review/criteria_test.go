package review

import (
	"strings"
	"testing"
)

const reportWithCriteria = `## Verdict
APPROVED

## Complex Blockers
- None

## Simple Blockers
- None

## Acceptance Criteria Verdicts
- ProfileFor("qwen-local") returns conservative defaults — MET — profile_test.go:12
- internal/provider/profile.go exists — NOT_MET — file absent from diff
- live smoke clamp logs the line — UNVERIFIABLE — needs a running endpoint
`

// TestParse_CriteriaVerdicts — the section parses into typed rows.
func TestParse_CriteriaVerdicts(t *testing.T) {
	r, err := ParseReader(strings.NewReader(reportWithCriteria))
	if err != nil {
		t.Fatal(err)
	}
	if len(r.CriteriaVerdicts) != 3 {
		t.Fatalf("want 3 criteria verdicts, got %d: %+v", len(r.CriteriaVerdicts), r.CriteriaVerdicts)
	}
	want := []CriterionDecision{CriterionMet, CriterionNotMet, CriterionUnverifiable}
	for i, w := range want {
		if r.CriteriaVerdicts[i].Decision != w {
			t.Errorf("verdict[%d]: want %s, got %s", i, w, r.CriteriaVerdicts[i].Decision)
		}
	}
	if r.CriteriaVerdicts[1].Evidence != "file absent from diff" {
		t.Errorf("evidence not parsed: %q", r.CriteriaVerdicts[1].Evidence)
	}
}

// TestUnmetCriteria — only NOT_MET counts (UNVERIFIABLE is not a failure).
func TestUnmetCriteria(t *testing.T) {
	r, _ := ParseReader(strings.NewReader(reportWithCriteria))
	unmet := r.UnmetCriteria()
	if len(unmet) != 1 {
		t.Fatalf("want 1 unmet, got %d", len(unmet))
	}
	if !strings.Contains(unmet[0].Criterion, "profile.go exists") {
		t.Errorf("wrong unmet criterion: %q", unmet[0].Criterion)
	}
}

// TestEnforceUnmetCriteria_ForcesRework — a NOT_MET criterion under an APPROVED
// verdict downgrades the verdict and adds a Complex Blocker.
func TestEnforceUnmetCriteria_ForcesRework(t *testing.T) {
	r, _ := ParseReader(strings.NewReader(reportWithCriteria))
	if !r.IsApproved() {
		t.Fatalf("precondition: report should start APPROVED, got %s", r.Verdict)
	}
	complexBefore := r.HasComplexBlockers()

	n := r.EnforceUnmetCriteria()
	if n != 1 {
		t.Errorf("EnforceUnmetCriteria: want 1, got %d", n)
	}
	if r.IsApproved() {
		t.Error("verdict should be downgraded from APPROVED after an unmet criterion")
	}
	if r.Verdict != VerdictChangesRequired {
		t.Errorf("verdict: want CHANGES_REQUIRED, got %s", r.Verdict)
	}
	if r.HasComplexBlockers() != complexBefore+1 {
		t.Errorf("expected one new Complex Blocker; before=%d after=%d", complexBefore, r.HasComplexBlockers())
	}
	if !strings.Contains(r.ComplexBlockers[len(r.ComplexBlockers)-1], "profile.go exists") {
		t.Errorf("complex blocker should name the unmet criterion: %v", r.ComplexBlockers)
	}
}

// TestEnforceUnmetCriteria_AllMet_NoOp — no NOT_MET → verdict unchanged.
func TestEnforceUnmetCriteria_AllMet_NoOp(t *testing.T) {
	body := "## Verdict\nAPPROVED\n\n## Acceptance Criteria Verdicts\n- thing one — MET — ok\n- thing two — MET — ok\n"
	r, _ := ParseReader(strings.NewReader(body))
	if n := r.EnforceUnmetCriteria(); n != 0 {
		t.Errorf("all-MET should enforce 0, got %d", n)
	}
	if !r.IsApproved() {
		t.Error("all-MET must remain APPROVED")
	}
}
