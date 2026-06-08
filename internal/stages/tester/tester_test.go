package tester

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
	innertester "github.com/geoffgodwin/tekhton/internal/tester"
	"github.com/geoffgodwin/tekhton/internal/tester/tdd"
)

// TestRunStage_Fixtures is the m38.6 parity test. It exercises all ten
// routing branches the milestone calls out: clean, partial-run,
// compilation errors, test failures (fix enabled / disabled), TDD
// write-failing, TDD UPSTREAM, MAIN UPSTREAM, null-run, and
// no-report-but-tests. Each subtest installs its own seams and asserts
// the verdict + metadata that observable downstream consumers
// (orchestrator, runners) read.
func TestRunStage_Fixtures(t *testing.T) {
	tests := []struct {
		name string
		run  func(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error)
	}{
		{"clean-pass", testCleanPass},
		{"partial-run", testPartialRun},
		{"compilation-errors", testCompilationErrors},
		{"test-failures-fix-enabled", testTestFailuresFixEnabled},
		{"test-failures-fix-disabled", testTestFailuresFixDisabled},
		{"tdd-write-failing", testTDDWriteFailing},
		{"tdd-upstream-error", testTDDUpstreamError},
		{"upstream-error", testUpstreamError},
		{"null-run", testNullRun},
		{"no-report-but-tests", testNoReportButTests},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			dir, req := setupTesterProject(t)
			_, _ = tc.run(t, dir, req)
		})
	}
}

// --- Per-fixture cases -------------------------------------------------------

func testCleanPass(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	writeReport(t, dir, "## Planned Tests\n- [x] one\n- [x] two\n")
	writeLog(t, dir, "all good\n")

	agent := &fakeMainAgent{}
	audit := &fakeAudit{}
	restore := installFixtureSeams(t, fixtureSeams{main: agent, audit: audit})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("want pass, got %q", res.Verdict)
	}
	if res.ExitReason != "clean" {
		t.Fatalf("want exit_reason=clean, got %q", res.ExitReason)
	}
	if !audit.called {
		t.Fatalf("expected audit.Run to be called on clean exit")
	}
	if res.Metadata[metaAuditRan] != "true" {
		t.Fatalf("missing audit_ran metadata: %+v", res.Metadata)
	}
	return res, err
}

func testPartialRun(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	writeReport(t, dir, "## Planned Tests\n- [ ] one\n- [ ] two\n")
	writeLog(t, dir, "ok\n")

	agent := &fakeMainAgent{}
	cont := &fakeContinuation{
		Result: &innertester.ContinuationResult{Continued: true, AttemptsUsed: 1, RemainingTests: 0},
	}
	audit := &fakeAudit{}
	restore := installFixtureSeams(t, fixtureSeams{main: agent, continuation: cont, audit: audit})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cont.called {
		t.Fatalf("expected continuation runner to be called")
	}
	if !audit.called {
		t.Fatalf("expected audit to run after clean continuation")
	}
	if res.Metadata[metaContinuationOK] != "true" {
		t.Fatalf("missing continuation_ok metadata: %+v", res.Metadata)
	}
	return res, err
}

func testCompilationErrors(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	writeReport(t, dir, "## Planned Tests\n- [x] `foo.test.ts`\n")
	writeLog(t, dir, "Compilation failed for testPath=foo.test.ts: SyntaxError\n")

	agent := &fakeMainAgent{}
	fix := &fakeFix{}
	cont := &fakeContinuation{}
	audit := &fakeAudit{}
	restore := installFixtureSeams(t, fixtureSeams{
		main: agent, fix: fix, continuation: cont, audit: audit,
	})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if fix.called {
		t.Fatalf("fix runner must NOT be called on compilation errors")
	}
	if cont.called {
		t.Fatalf("continuation must NOT be called on compilation errors")
	}
	if audit.called {
		t.Fatalf("audit must NOT be called on compilation errors")
	}
	if res.ExitReason != "compilation_errors" {
		t.Fatalf("want compilation_errors, got %q", res.ExitReason)
	}
	if res.Verdict != proto.VerdictRework {
		t.Fatalf("want rework, got %q", res.Verdict)
	}
	return res, err
}

func testTestFailuresFixEnabled(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	writeReport(t, dir, "## Planned Tests\n- [x] one\n")
	writeLog(t, dir, "  -1: AssertionError\n")
	t.Setenv("TESTER_FIX_ENABLED", "true")
	t.Setenv("TESTER_FIX_MAX_DEPTH", "1")

	agent := &fakeMainAgent{}
	fix := &fakeFix{
		Result: &innertester.FixResult{AttemptCount: 1, ResolvedFailures: true},
	}
	restore := installFixtureSeams(t, fixtureSeams{main: agent, fix: fix})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !fix.called {
		t.Fatalf("expected RunInlineFix to be called when TesterFixEnabled+MaxDepth>0")
	}
	if res.Metadata[metaResolvedFailures] != "true" {
		t.Fatalf("missing resolved_failures metadata: %+v", res.Metadata)
	}
	return res, err
}

func testTestFailuresFixDisabled(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	writeReport(t, dir, "## Planned Tests\n- [x] one\n")
	writeLog(t, dir, "  -1: AssertionError\n")
	t.Setenv("TESTER_FIX_ENABLED", "false")
	t.Setenv("TESTER_FIX_MAX_DEPTH", "1")

	agent := &fakeMainAgent{}
	fix := &fakeFix{}
	restore := installFixtureSeams(t, fixtureSeams{main: agent, fix: fix})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if fix.called {
		t.Fatalf("RunInlineFix must NOT be called when TesterFixEnabled=false")
	}
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("want fail when fix disabled, got %q", res.Verdict)
	}
	return res, err
}

func testTDDWriteFailing(t *testing.T, _ string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	t.Setenv("TESTER_MODE", "write_failing")

	agent := &fakeMainAgent{}
	tddR := &fakeTDD{Result: &tdd.Result{PreflightExists: true, Turns: 5}}
	restore := installFixtureSeams(t, fixtureSeams{main: agent, tdd: tddR})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !tddR.called {
		t.Fatalf("expected tdd.Run to be dispatched")
	}
	if agent.calls != 0 {
		t.Fatalf("MAIN agent must NOT be called in TDD branch (got %d calls)", agent.calls)
	}
	if res.ExitReason != "tdd_preflight" {
		t.Fatalf("want tdd_preflight, got %q", res.ExitReason)
	}
	return res, err
}

func testTDDUpstreamError(t *testing.T, _ string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	t.Setenv("TESTER_MODE", "write_failing")

	tddR := &fakeTDD{Err: errors.New("tdd: upstream rate_limit")}
	restore := installFixtureSeams(t, fixtureSeams{tdd: tddR})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err == nil {
		t.Fatalf("expected non-nil error from TDD UPSTREAM (regression-canary)")
	}
	if res == nil || res.Verdict != proto.VerdictFail {
		t.Fatalf("want verdict=fail, got %+v", res)
	}
	return res, err
}

func testUpstreamError(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	writeReport(t, dir, "## Planned Tests\n- [x] one\n")
	writeLog(t, dir, "ok\n")

	agent := &fakeMainAgent{
		Result: &proto.AgentResultV1{
			Outcome:          proto.OutcomeTransientError,
			ExitCode:         1,
			ErrorCategory:    supervisor.CategoryUpstream,
			ErrorSubcategory: "rate_limit",
			ErrorMessage:     "API quota exhausted",
		},
	}
	restore := installFixtureSeams(t, fixtureSeams{main: agent})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("MAIN UPSTREAM must return nil error (recoverable), got %v", err)
	}
	if res.Metadata[metaSkipFinalChecks] != "true" {
		t.Fatalf("MAIN UPSTREAM must set skip_final_checks=true: %+v", res.Metadata)
	}
	if res.ExitReason != "upstream_error" {
		t.Fatalf("want exit_reason=upstream_error, got %q", res.ExitReason)
	}
	return res, err
}

func testNullRun(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	writeReport(t, dir, "")
	writeLog(t, dir, "")

	// Null-run = 0 turns used + non-success outcome.
	agent := &fakeMainAgent{
		Result: &proto.AgentResultV1{
			Outcome:   proto.OutcomeTurnExhausted,
			ExitCode:  1,
			TurnsUsed: 0,
		},
	}
	restore := installFixtureSeams(t, fixtureSeams{main: agent})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("null-run must return nil error (recoverable), got %v", err)
	}
	if res.Metadata[metaSkipFinalChecks] != "true" {
		t.Fatalf("null-run must set skip_final_checks=true: %+v", res.Metadata)
	}
	if res.ExitReason != "null_run" {
		t.Fatalf("want null_run, got %q", res.ExitReason)
	}
	return res, err
}

func testNoReportButTests(t *testing.T, dir string, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	t.Helper()
	// Do NOT write a tester report. Plant a "test file" in the project
	// tree and stub the git-diff seam in internal/tester.
	if err := os.WriteFile(filepath.Join(dir, "foo.test.ts"), []byte("test()"), 0o644); err != nil {
		t.Fatalf("write test file: %v", err)
	}
	writeLog(t, dir, "ok\n")

	// Install fake GitDiff so ValidateOutput sees foo.test.ts.
	innertester.SetGitDiffRunner(&fakeGitDiff{files: []string{"foo.test.ts"}})
	defer innertester.SetGitDiffRunner(&fakeGitDiff{}) // restore-ish (sets non-nil)

	// Install fake commit gate so the test asserts the trip happened.
	gate := &fakeCommitGate{}
	innertester.SetCommitGateTripper(gate)
	defer innertester.SetCommitGateTripper(gate)

	agent := &fakeMainAgent{}
	restore := installFixtureSeams(t, fixtureSeams{main: agent})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !gate.tripped {
		t.Fatalf("expected commit gate to be tripped (#46 regression canary)")
	}
	if res.ExitReason != "no_report_but_tests_created" {
		t.Fatalf("want no_report_but_tests_created, got %q", res.ExitReason)
	}
	return res, err
}
