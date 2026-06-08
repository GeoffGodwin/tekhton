package tester

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	innertester "github.com/geoffgodwin/tekhton/internal/tester"
	"github.com/geoffgodwin/tekhton/internal/tester/tdd"
	testaudit "github.com/geoffgodwin/tekhton/internal/test_audit"
)

// fakeMainAgent records every Run() call. By default Run returns a
// success result with TurnsUsed=5 so the null-run gate stays open.
// Tests override Result to drive UPSTREAM, null-run, etc.
type fakeMainAgent struct {
	Result *proto.AgentResultV1
	Err    error
	calls  int
}

func (f *fakeMainAgent) Run(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	f.calls++
	if f.Err != nil {
		return nil, f.Err
	}
	if f.Result != nil {
		return f.Result, nil
	}
	return &proto.AgentResultV1{
		Proto:     proto.AgentResultProtoV1,
		Outcome:   proto.OutcomeSuccess,
		ExitCode:  0,
		TurnsUsed: 5,
	}, nil
}

// fakeTDD records dispatch + drives error / result branches.
type fakeTDD struct {
	Result *tdd.Result
	Err    error
	called bool
}

func (f *fakeTDD) Run(_ context.Context, _ *tdd.Request) (*tdd.Result, error) {
	f.called = true
	if f.Err != nil {
		return nil, f.Err
	}
	if f.Result != nil {
		return f.Result, nil
	}
	return &tdd.Result{PreflightExists: true, Turns: 5}, nil
}

// fakeFix records inline-fix dispatch.
type fakeFix struct {
	Result *innertester.FixResult
	Err    error
	called bool
}

func (f *fakeFix) Run(_ context.Context, _ *innertester.FixRequest) (*innertester.FixResult, error) {
	f.called = true
	if f.Err != nil {
		return nil, f.Err
	}
	if f.Result != nil {
		return f.Result, nil
	}
	return &innertester.FixResult{}, nil
}

// fakeContinuation records continuation-loop dispatch.
type fakeContinuation struct {
	Result *innertester.ContinuationResult
	Err    error
	called bool
}

func (f *fakeContinuation) Run(_ context.Context, _ *innertester.ContinuationRequest) (*innertester.ContinuationResult, error) {
	f.called = true
	if f.Err != nil {
		return nil, f.Err
	}
	if f.Result != nil {
		return f.Result, nil
	}
	return &innertester.ContinuationResult{}, nil
}

// fakeAudit records test-audit dispatch.
type fakeAudit struct {
	Result *testaudit.AuditResult
	Err    error
	called bool
}

func (f *fakeAudit) Run(_ context.Context, _ *testaudit.Request) (*testaudit.AuditResult, error) {
	f.called = true
	if f.Err != nil {
		return nil, f.Err
	}
	if f.Result != nil {
		return f.Result, nil
	}
	return &testaudit.AuditResult{AgentCalls: 1}, nil
}

// fakeStateHaltWriter records writes so tests can assert resume context
// was persisted. Optional — tests that don't install it use the package
// no-op default.
type fakeStateHaltWriter struct {
	stage      string
	exitReason string
	resumeFlag string
	task       string
	notes      string
	called     bool
}

func (f *fakeStateHaltWriter) Write(_ context.Context, stage, exitReason, resumeFlag, task, notes string) error {
	f.called = true
	f.stage = stage
	f.exitReason = exitReason
	f.resumeFlag = resumeFlag
	f.task = task
	f.notes = notes
	return nil
}

// fakeGitDiff implements innertester.GitDiffRunner. Used by the
// no-report-but-tests fixture to make ValidateOutput see plant test
// files without invoking real git.
type fakeGitDiff struct {
	files []string
}

func (f *fakeGitDiff) NameOnlyAgainstHEAD(_ context.Context, _ string) ([]string, error) {
	return f.files, nil
}

// fakeCommitGate implements innertester.CommitGateTripper.
type fakeCommitGate struct {
	tripped bool
	reason  string
}

func (f *fakeCommitGate) TripCommitGate(_ context.Context, _, _, reason string) error {
	f.tripped = true
	f.reason = reason
	return nil
}

// fixtureSeams bundles the seam fakes a single test installs. Optional
// fields stay nil; installFixtureSeams restores defaults on cleanup.
type fixtureSeams struct {
	main         MainAgentRunner
	tdd          TDDRunner
	fix          FixRunner
	continuation ContinuationRunner
	audit        AuditRunner
	state        StateHaltWriter
}

func installFixtureSeams(t *testing.T, s fixtureSeams) func() {
	t.Helper()
	var prevs []func()
	if s.main != nil {
		prev := SetMainAgentRunner(s.main)
		prevs = append(prevs, func() { SetMainAgentRunner(prev) })
	}
	if s.tdd != nil {
		prev := SetTDDRunner(s.tdd)
		prevs = append(prevs, func() { SetTDDRunner(prev) })
	}
	if s.fix != nil {
		prev := SetFixRunner(s.fix)
		prevs = append(prevs, func() { SetFixRunner(prev) })
	}
	if s.continuation != nil {
		prev := SetContinuationRunner(s.continuation)
		prevs = append(prevs, func() { SetContinuationRunner(prev) })
	}
	if s.audit != nil {
		prev := SetAuditRunner(s.audit)
		prevs = append(prevs, func() { SetAuditRunner(prev) })
	}
	if s.state != nil {
		prev := SetStateHaltWriter(s.state)
		prevs = append(prevs, func() { SetStateHaltWriter(prev) })
	}
	return func() {
		for i := len(prevs) - 1; i >= 0; i-- {
			prevs[i]()
		}
	}
}

// --- shared fixture builders -------------------------------------------------

// setupTesterProject creates a temp project dir with a sensible default
// env that keeps every code path off process state. Tests then layer in
// per-fixture content (TESTER_REPORT.md, LOG_FILE) and override env vars
// as needed via t.Setenv.
func setupTesterProject(t *testing.T) (string, *proto.StageRequestV1) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".tekhton"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Setenv("TEKHTON_DIR", ".tekhton")
	t.Setenv("MILESTONE_MODE", "false")
	t.Setenv("TESTER_FIX_ENABLED", "false")
	t.Setenv("TESTER_FIX_MAX_DEPTH", "1")
	t.Setenv("TESTER_MAX_TURNS", "50")
	t.Setenv("LOG_FILE", filepath.Join(dir, "tester.log"))
	t.Setenv("TESTER_REPORT_FILE", filepath.Join(dir, ".tekhton", "TESTER_REPORT.md"))
	t.Setenv("CODER_SUMMARY_FILE", filepath.Join(dir, ".tekhton", "CODER_SUMMARY.md"))
	t.Setenv("CLAUDE_TESTER_MODEL", "test-model")
	t.Setenv("TESTER_MODE", "verify_passing")
	t.Setenv("START_AT", "coder")
	t.Setenv("PROMPTS_DIR", filepath.Join(repoRootForTest(t), "prompts"))

	req := &proto.StageRequestV1{
		Proto: proto.StageRequestProtoV1,
		Stage: proto.StageTester,
		Task:  "test task",
		EnvOverrides: map[string]string{
			"PROJECT_DIR":          dir,
			"TEKHTON_HOME":         repoRootForTest(t),
			"PIPELINE_STAGE_POS":   "3",
			"PIPELINE_STAGE_COUNT": "4",
		},
		ResultFile: filepath.Join(dir, "result.json"),
	}
	return dir, req
}

// writeReport drops content at .tekhton/TESTER_REPORT.md. An empty
// content string leaves the file absent (tests for null-run / missing
// report use this).
func writeReport(t *testing.T, dir, content string) {
	t.Helper()
	if content == "" {
		return
	}
	p := filepath.Join(dir, ".tekhton", "TESTER_REPORT.md")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write report: %v", err)
	}
}

// writeLog drops content at the LOG_FILE path. An empty content string
// leaves the file absent.
func writeLog(t *testing.T, dir, content string) {
	t.Helper()
	if content == "" {
		return
	}
	p := filepath.Join(dir, "tester.log")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write log: %v", err)
	}
}

// repoRootForTest walks up to the tekhton repo root (the directory
// containing go.mod). Used by the test fixtures so prompt rendering can
// resolve prompts/tester.prompt.md.
func repoRootForTest(t *testing.T) string {
	t.Helper()
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("repo root not found")
		}
		dir = parent
	}
}
