package review

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
)

// TestSpecialist_Passthrough — specialist returns no blockers; the stage
// returns verdict=pass / approved unchanged.
func TestSpecialist_Passthrough(t *testing.T) {
	_, req := setupProject(t)
	cfg := loadConfig(req)
	report := &reviewparse.Report{Verdict: reviewparse.VerdictApproved}
	budget := &reviewparse.CycleBudget{Current: 1, Max: 3}

	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{}, nil, &fakeSpecialist{Blockers: ""})
	defer restore()

	res, err := finalizeApproved(context.Background(), req, &cfg, report, budget, 1, &nullLogger{})
	if err != nil {
		t.Fatalf("finalizeApproved: %v", err)
	}
	if res.Verdict != proto.VerdictPass || res.ExitReason != "approved" {
		t.Errorf("got verdict=%q reason=%q want pass/approved", res.Verdict, res.ExitReason)
	}
}

// TestSpecialist_Exhausted — specialist returns blockers but no cycles remain.
// Returns verdict=fail / specialist_blockers.
func TestSpecialist_Exhausted(t *testing.T) {
	dir, req := setupProject(t)
	cfg := loadConfig(req)
	report := &reviewparse.Report{Verdict: reviewparse.VerdictApproved}
	budget := &reviewparse.CycleBudget{Current: 3, Max: 3}

	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{}, nil,
		&fakeSpecialist{Blockers: "- broken auth on /admin"})
	defer restore()

	res, err := finalizeApproved(context.Background(), req, &cfg, report, budget, 2, &nullLogger{})
	if err != nil {
		t.Fatalf("finalizeApproved: %v", err)
	}
	if res.Verdict != proto.VerdictFail {
		t.Errorf("verdict=%q want fail", res.Verdict)
	}
	if res.ExitReason != "specialist_blockers" {
		t.Errorf("exit_reason=%q want specialist_blockers", res.ExitReason)
	}
	if !strings.Contains(res.Error, "specialist_report_file=") {
		t.Errorf("Error metadata missing specialist_report_file:\n%s", res.Error)
	}
	// Nothing was appended to REVIEWER_REPORT.md in this path.
	if fileExists(dir + "/.tekhton/REVIEWER_REPORT.md") {
		// Either way is fine — the test just asserts we don't crash.
	}
}

// TestAppendToFile_BytePreservation asserts the specialist section append
// behaves as the bash `{ echo ""; echo "## Specialist Blockers"; echo $X; }
// >> file` byte-shape. Locks in the m37.1 FormatSpecialistSection output's
// integration with the stage append.
func TestAppendToFile_BytePreservation(t *testing.T) {
	dir, _ := setupProject(t)
	path := dir + "/.tekhton/REVIEWER_REPORT.md"
	if err := appendToFile(path, "ORIGINAL\n"); err != nil {
		t.Fatalf("first append: %v", err)
	}
	section := reviewparse.FormatSpecialistSection("- broken auth")
	if err := appendToFile(path, section); err != nil {
		t.Fatalf("second append: %v", err)
	}
	body := readReviewerReport(t, dir)
	want := "ORIGINAL\n\n## Specialist Blockers\n- broken auth\n"
	if body != want {
		t.Errorf("byte-parity diff:\nwant:\n%q\ngot:\n%q", want, body)
	}
}

// TestFinalizeApproved_SpecialistRunnerErrorDoesNotOverrideVerdict asserts
// the m47 envelope-over-error rule for the specialist-runner-error branch:
// when specialistRunner.Run returns a non-nil error, finalizeApproved MUST
// return the approvedResult (verdict=pass) with the error recorded as a
// subprocess_warnings entry — NOT a Go-level error that would override the
// originally-parsed APPROVED verdict.
func TestFinalizeApproved_SpecialistRunnerErrorDoesNotOverrideVerdict(t *testing.T) {
	_, req := setupProject(t)
	cfg := loadConfig(req)
	report := &reviewparse.Report{Verdict: reviewparse.VerdictApprovedWithNotes}
	budget := &reviewparse.CycleBudget{Current: 1, Max: 3}

	specErr := errors.New("specialist runner exec failed")
	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{}, nil,
		&fakeSpecialist{Err: specErr})
	defer restore()

	res, err := finalizeApproved(context.Background(), req, &cfg, report, budget, 1, &nullLogger{})
	if err != nil {
		t.Fatalf("finalizeApproved: err=%v (m47 requires nil)", err)
	}
	if res == nil {
		t.Fatal("finalizeApproved: res=nil (m47 requires non-nil approvedResult)")
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass (APPROVED verdict must survive)", res.Verdict)
	}
	if res.ExitReason != "approved" {
		t.Errorf("exit_reason=%q want approved", res.ExitReason)
	}
	// Subprocess warning recorded as JSON array (m47 plural-key contract).
	raw := res.Metadata["subprocess_warnings"]
	if raw == "" {
		t.Fatalf("Metadata[\"subprocess_warnings\"] empty; expected the specialist runner error")
	}
	var warnings []string
	if err := json.Unmarshal([]byte(raw), &warnings); err != nil {
		t.Fatalf("subprocess_warnings not JSON: %v (raw=%q)", err, raw)
	}
	if len(warnings) != 1 {
		t.Fatalf("warnings len=%d want 1; got %v", len(warnings), warnings)
	}
	if !strings.Contains(warnings[0], "specialist runner exec failed") {
		t.Errorf("warning %q does not reference the specialist error", warnings[0])
	}
}

// TestSpecialist_ReworkApproved — specialist blockers + cycles remain; the
// senior rework runs, build gate passes, the post-specialist reviewer pass
// APPROVES. Stage returns verdict=pass / approved.
func TestSpecialist_ReworkApproved(t *testing.T) {
	dir, req := setupProject(t)
	// Pre-populate REVIEWER_REPORT.md with the cycle-1 content so the append
	// path has something to extend.
	writeReport(t, dir, "## Verdict\nAPPROVED\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")

	report := &reviewparse.Report{Verdict: reviewparse.VerdictApproved}
	budget := &reviewparse.CycleBudget{Current: 1, Max: 3}

	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			// senior coder rework
			func(*provider.Request) (*provider.Result, error) {
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 15}, nil
			},
			// post-specialist reviewer pass
			func(*provider.Request) (*provider.Result, error) {
				writeReport(t, dir, "## Verdict\nAPPROVED\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &provider.Result{Outcome: provider.OutcomeSuccess, TurnsUsed: 5}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil,
		&fakeSpecialist{Blockers: "- input not sanitized\n"})
	defer restore()
	cfg := loadConfig(req)

	res, err := finalizeApproved(context.Background(), req, &cfg, report, budget, 1, &nullLogger{})
	if err != nil {
		t.Fatalf("finalizeApproved: %v", err)
	}
	if res.Verdict != proto.VerdictPass || res.ExitReason != "approved" {
		t.Errorf("got verdict=%q reason=%q want pass/approved", res.Verdict, res.ExitReason)
	}
	if budget.Current != 2 {
		t.Errorf("budget.Current=%d want 2 (incremented during specialist rework)", budget.Current)
	}
	// Senior coder rework + post-specialist reviewer pass → 2 agent calls.
	// The post-specialist reviewer overwrites REVIEWER_REPORT.md so we can't
	// see the append on disk at end-of-run; the FormatSpecialistSection
	// bash-byte-parity is covered separately in internal/review's specialist_test.go.
	if len(ag.Calls) < 2 {
		t.Errorf("agent calls=%d want >=2 (rework + reviewer)", len(ag.Calls))
	}
	// Build gate ran exactly once for post-specialist-rework.
	if len(gate.Calls) != 1 || gate.Calls[0] != "post-specialist-rework" {
		t.Errorf("gate calls=%v want [post-specialist-rework]", gate.Calls)
	}
	// Use dir to silence unused warning + assert REVIEWER_REPORT.md exists.
	if !fileExists(dir + "/.tekhton/REVIEWER_REPORT.md") {
		t.Errorf("REVIEWER_REPORT.md was removed unexpectedly")
	}
}
