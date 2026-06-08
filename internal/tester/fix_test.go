package tester

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
	"github.com/geoffgodwin/tekhton/internal/test_baseline"
)

// --- Test seams --------------------------------------------------------

type fakeFixAgentRunner struct {
	gotReq *proto.AgentRequestV1
	result *proto.AgentResultV1
	err    error
	calls  int
}

func (f *fakeFixAgentRunner) Run(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	f.calls++
	f.gotReq = req
	return f.result, f.err
}

type fakeFixPromptRenderer struct {
	body    string
	err     error
	gotVars map[string]string
	calls   int
}

func (f *fakeFixPromptRenderer) Render(_, _ string, vars map[string]string) (string, error) {
	f.calls++
	f.gotVars = vars
	if f.err != nil {
		return "", f.err
	}
	if f.body == "" {
		return "test prompt body", nil
	}
	return f.body, nil
}

// seedBaselineForFix writes a TEST_BASELINE.json at projectDir/.claude that
// causes test_baseline.Has(milestone) to return true and Compare to return
// the verdict the test wants. m38.5 replaced the BaselineChecker seam
// with direct test_baseline.Has + test_baseline.Compare calls; this
// helper drives the short-circuit by seeding real on-disk state instead
// of a fake.
func seedBaselineForFix(t *testing.T, projectDir, milestone string, exitCode int, failureHash string, failureCount int) {
	t.Helper()
	claudeDir := filepath.Join(projectDir, ".claude")
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := []byte(`{
  "run_id": "test-run",
  "timestamp": "2026-06-07T00:00:00Z",
  "milestone": "` + milestone + `",
  "exit_code": ` + intToString(exitCode) + `,
  "output_hash": "abc",
  "failure_hash": "` + failureHash + `",
  "failure_count": ` + intToString(failureCount) + `
}
`)
	if err := os.WriteFile(filepath.Join(claudeDir, "TEST_BASELINE.json"), body, 0o644); err != nil {
		t.Fatal(err)
	}
}

type fakeTestDedup struct {
	canSkipReturn bool
	canSkipCalls  int
	recordCalls   int
}

func (f *fakeTestDedup) CanSkip() bool {
	f.canSkipCalls++
	return f.canSkipReturn
}

func (f *fakeTestDedup) RecordPass() { f.recordCalls++ }

type fakeFixTestRunner struct {
	exitCodes []int
	gotCmds   []string
	calls     int
	err       error
}

func (f *fakeFixTestRunner) Run(_ context.Context, _ string, testCmd string) (int, error) {
	idx := f.calls
	f.calls++
	f.gotCmds = append(f.gotCmds, testCmd)
	if f.err != nil {
		return 0, f.err
	}
	if idx >= len(f.exitCodes) {
		return 0, nil
	}
	return f.exitCodes[idx], nil
}

type captureLogger struct {
	lines []string
}

func (c *captureLogger) Logf(format string, args ...any) {
	c.lines = append(c.lines, strings.TrimSpace(format))
}

func installFixSeams(t *testing.T, agent FixAgentRunner, render FixPromptRenderer, dedup TestDedup, runner FixTestRunner, logger FixLogger) func() {
	t.Helper()
	prevA := SetFixAgentRunner(agent)
	prevP := SetFixPromptRenderer(render)
	prevD := SetFixTestDedup(dedup)
	prevR := SetFixTestRunner(runner)
	prevL := SetFixLogger(logger)
	return func() {
		SetFixAgentRunner(prevA)
		SetFixPromptRenderer(prevP)
		SetFixTestDedup(prevD)
		SetFixTestRunner(prevR)
		SetFixLogger(prevL)
	}
}

func newFixRequest(t *testing.T) *FixRequest {
	t.Helper()
	dir := t.TempDir()
	return &FixRequest{
		ProjectDir: dir,
		PromptsDir: "prompts",
		Task:       "fix tests",
		TestCmd:    "echo running tests",
		FailureLog: "FAIL test_thing\nassert 1 == 2\nERROR: thing broke\n",
		Options:    DefaultFixOptions(),
	}
}

// --- Regression-canary tests -------------------------------------------

func TestDefaultFixOptions_MaxDepthIs1(t *testing.T) {
	if got := DefaultFixOptions().MaxDepth; got != 1 {
		t.Fatalf("DefaultFixOptions().MaxDepth = %d, want 1 (regression-canary — going deeper led to runaway agent invocations)", got)
	}
}

func TestDefaultFixOptions_FieldDefaults(t *testing.T) {
	opts := DefaultFixOptions()
	if opts.OutputLimit != 4000 {
		t.Errorf("OutputLimit = %d, want 4000", opts.OutputLimit)
	}
	if opts.MaxTurns != 26 {
		t.Errorf("MaxTurns = %d, want 26", opts.MaxTurns)
	}
	if opts.Model != "claude-sonnet-4-6" {
		t.Errorf("Model = %q, want claude-sonnet-4-6", opts.Model)
	}
	if !opts.BaselineCheck {
		t.Errorf("BaselineCheck = false, want true")
	}
}

func TestRunInlineFix_BaselineShortCircuits(t *testing.T) {
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess},
	}
	render := &fakeFixPromptRenderer{}
	dedup := &fakeTestDedup{}
	runner := &fakeFixTestRunner{}
	restore := installFixSeams(t, agent, render, dedup, runner, &captureLogger{})
	defer restore()

	req := newFixRequest(t)
	req.Milestone = "m38.5"
	// m38.5: seed an on-disk baseline whose failure_hash matches the
	// hash test_baseline.Compare will compute against the truncated
	// output. Compare returns VerdictPreExisting → fix loop short-
	// circuits without invoking the agent.
	opts := withFixDefaults(req.Options)
	failureOutput := extractFailureOutput(req.FailureLog, opts.OutputLimit)
	truncated := SmartTruncateTestOutput(failureOutput, opts.OutputLimit)
	failureHash := test_baseline.FailureSignatureHashForTesting(truncated)
	seedBaselineForFix(t, req.ProjectDir, "m38.5", 1, failureHash, 5)

	res, err := RunInlineFix(context.Background(), req)
	if err != nil {
		t.Fatalf("RunInlineFix: %v", err)
	}
	if !res.BaselineSkipped {
		t.Errorf("BaselineSkipped = false, want true")
	}
	if agent.calls != 0 {
		t.Errorf("agent.calls = %d, want 0 (agent should not run on baseline skip)", agent.calls)
	}
}

func TestRunInlineFix_DedupPreservedOnSecondCall(t *testing.T) {
	// First fix call: TEST_CMD passes, dedup records pass.
	// Second fix call: dedup CanSkip returns true; TEST_CMD must NOT
	// be invoked. Total runner invocations across both calls: 1.
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess},
	}
	render := &fakeFixPromptRenderer{}
	// No baseline seeded — test_baseline.Has returns false, short-circuit
	// skipped, full fix flow runs.
	dedup := &fakeTestDedup{}
	runner := &fakeFixTestRunner{exitCodes: []int{0}}
	restore := installFixSeams(t, agent, render, dedup, runner, &captureLogger{})
	defer restore()

	req := newFixRequest(t)

	if _, err := RunInlineFix(context.Background(), req); err != nil {
		t.Fatalf("first RunInlineFix: %v", err)
	}
	if runner.calls != 1 {
		t.Fatalf("after first call: runner.calls = %d, want 1", runner.calls)
	}
	if dedup.recordCalls != 1 {
		t.Errorf("after first call: dedup.recordCalls = %d, want 1", dedup.recordCalls)
	}

	// Now flip dedup to "can skip"
	dedup.canSkipReturn = true

	res2, err := RunInlineFix(context.Background(), newFixRequest(t))
	if err != nil {
		t.Fatalf("second RunInlineFix: %v", err)
	}
	if runner.calls != 1 {
		t.Errorf("after second call: runner.calls = %d, want 1 (dedup preserved)", runner.calls)
	}
	if !res2.DedupSkipped {
		t.Errorf("second res.DedupSkipped = false, want true")
	}
	if !res2.ResolvedFailures {
		t.Errorf("second res.ResolvedFailures = false, want true")
	}
}

func TestRunInlineFix_DedupCanSkipCalledBeforeTestRunner(t *testing.T) {
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess},
	}
	render := &fakeFixPromptRenderer{}
	dedup := &fakeTestDedup{canSkipReturn: true}
	runner := &fakeFixTestRunner{}
	restore := installFixSeams(t, agent, render, dedup, runner, &captureLogger{})
	defer restore()

	req := newFixRequest(t)
	res, err := RunInlineFix(context.Background(), req)
	if err != nil {
		t.Fatalf("RunInlineFix: %v", err)
	}
	if !res.DedupSkipped {
		t.Errorf("DedupSkipped = false, want true")
	}
	if runner.calls != 0 {
		t.Errorf("runner.calls = %d, want 0 (CanSkip should short-circuit before runner)", runner.calls)
	}
	if dedup.canSkipCalls != 1 {
		t.Errorf("dedup.canSkipCalls = %d, want 1", dedup.canSkipCalls)
	}
}

func TestRunInlineFix_UpstreamErrorPropagates(t *testing.T) {
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{
			Proto:            proto.AgentResultProtoV1,
			Outcome:          proto.OutcomeFatalError,
			ErrorCategory:    supervisor.CategoryUpstream,
			ErrorSubcategory: "api_rate_limit",
			ErrorMessage:     "429 from API",
		},
	}
	restore := installFixSeams(t, agent, &fakeFixPromptRenderer{}, &fakeTestDedup{}, &fakeFixTestRunner{}, &captureLogger{})
	defer restore()

	_, err := RunInlineFix(context.Background(), newFixRequest(t))
	if err == nil {
		t.Fatal("expected non-nil error for UPSTREAM category")
	}
	if !strings.Contains(err.Error(), "api_rate_limit") {
		t.Errorf("error %q does not include subcategory", err.Error())
	}
}

func TestRunInlineFix_AgentInvocationErrorReturnsError(t *testing.T) {
	agent := &fakeFixAgentRunner{err: errors.New("supervisor crashed")}
	restore := installFixSeams(t, agent, &fakeFixPromptRenderer{}, &fakeTestDedup{}, &fakeFixTestRunner{}, &captureLogger{})
	defer restore()

	_, err := RunInlineFix(context.Background(), newFixRequest(t))
	if err == nil {
		t.Fatal("expected non-nil error for agent invocation failure")
	}
}

func TestRunInlineFix_PromptRenderErrorReturnsError(t *testing.T) {
	render := &fakeFixPromptRenderer{err: errors.New("template missing")}
	restore := installFixSeams(t, &fakeFixAgentRunner{}, render, &fakeTestDedup{}, &fakeFixTestRunner{}, &captureLogger{})
	defer restore()

	_, err := RunInlineFix(context.Background(), newFixRequest(t))
	if err == nil {
		t.Fatal("expected non-nil error for prompt render failure")
	}
}

func TestRunInlineFix_NilRequestReturnsError(t *testing.T) {
	_, err := RunInlineFix(context.Background(), nil)
	if err == nil {
		t.Fatal("expected non-nil error for nil request")
	}
}

func TestRunInlineFix_TestCmdEmptyBreaksAfterOneAttempt(t *testing.T) {
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess},
	}
	restore := installFixSeams(t, agent, &fakeFixPromptRenderer{}, &fakeTestDedup{}, &fakeFixTestRunner{}, &captureLogger{})
	defer restore()

	req := newFixRequest(t)
	req.TestCmd = ""
	req.Options.MaxDepth = 3 // even with higher depth, empty TEST_CMD breaks
	res, err := RunInlineFix(context.Background(), req)
	if err != nil {
		t.Fatalf("RunInlineFix: %v", err)
	}
	if res.AttemptCount != 1 {
		t.Errorf("AttemptCount = %d, want 1 (loop should break after first attempt)", res.AttemptCount)
	}
}

func TestRunInlineFix_PromptVarsIncludeTestFiles(t *testing.T) {
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess},
	}
	render := &fakeFixPromptRenderer{}
	restore := installFixSeams(t, agent, render, &fakeTestDedup{}, &fakeFixTestRunner{exitCodes: []int{0}}, &captureLogger{})
	defer restore()

	req := newFixRequest(t)
	req.FailureLog = "FAIL: tests/billing.test.ts:42 assertion failed\n  expected 200\n  got 500\nERROR src/main.spec.js:10\n"

	if _, err := RunInlineFix(context.Background(), req); err != nil {
		t.Fatalf("RunInlineFix: %v", err)
	}
	got := render.gotVars["TESTER_FIX_TEST_FILES"]
	if !strings.Contains(got, "tests/billing.test.ts") || !strings.Contains(got, "src/main.spec.js") {
		t.Errorf("TESTER_FIX_TEST_FILES = %q, want it to include billing.test.ts and main.spec.js", got)
	}
}

func TestRunInlineFix_PromptVarsReadCoderSummary(t *testing.T) {
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess},
	}
	render := &fakeFixPromptRenderer{}
	restore := installFixSeams(t, agent, render, &fakeTestDedup{}, &fakeFixTestRunner{exitCodes: []int{0}}, &captureLogger{})
	defer restore()

	req := newFixRequest(t)
	summaryDir := filepath.Join(req.ProjectDir, ".tekhton")
	if err := os.MkdirAll(summaryDir, 0o755); err != nil {
		t.Fatal(err)
	}
	summary := `## Files Modified
- ` + "`src/billing.go`" + ` — fix bug
- ` + "`src/users.go`" + ` (NEW)

## Status
COMPLETE
`
	if err := os.WriteFile(filepath.Join(summaryDir, "CODER_SUMMARY.md"), []byte(summary), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := RunInlineFix(context.Background(), req); err != nil {
		t.Fatalf("RunInlineFix: %v", err)
	}
	got := render.gotVars["TESTER_FIX_SOURCE_FILES"]
	if !strings.Contains(got, "src/billing.go") || !strings.Contains(got, "src/users.go") {
		t.Errorf("TESTER_FIX_SOURCE_FILES = %q, want both files", got)
	}
}

// --- helper coverage ---------------------------------------------------

func TestWithFixDefaults_FillsZeroFields(t *testing.T) {
	o := withFixDefaults(FixOptions{})
	if o.MaxDepth != DefaultFixMaxDepth ||
		o.OutputLimit != DefaultFixOutputLimit ||
		o.MaxTurns != DefaultFixMaxTurns ||
		o.Model != DefaultFixCoderModel ||
		o.AgentTools != DefaultFixAgentTools ||
		o.SummaryFile != DefaultFixSummaryFile ||
		o.ReportFile != DefaultFixReportFile ||
		o.PromptName != "tester_fix" {
		t.Errorf("withFixDefaults: %+v", o)
	}
}

func TestWithFixDefaults_RespectsOverrides(t *testing.T) {
	in := FixOptions{
		MaxDepth: 5, OutputLimit: 100, MaxTurns: 11, Model: "haiku-5",
		AgentTools: "Read", SummaryFile: "S", ReportFile: "R", PromptName: "P",
	}
	out := withFixDefaults(in)
	if out.MaxDepth != 5 || out.OutputLimit != 100 || out.MaxTurns != 11 ||
		out.Model != "haiku-5" || out.AgentTools != "Read" ||
		out.SummaryFile != "S" || out.ReportFile != "R" || out.PromptName != "P" {
		t.Errorf("overrides not preserved: got %+v", out)
	}
}

func TestExtractFailureOutput_PicksFailureLinesAndCapsLimit(t *testing.T) {
	input := strings.Repeat("ok line\n", 100) + "FAIL one\nassert\n"
	got := extractFailureOutput(input, 4000)
	if !strings.Contains(got, "FAIL one") {
		t.Errorf("missing FAIL line; got %q", got)
	}
}

func TestExtractFailureOutput_EmptyInputReturnsEmpty(t *testing.T) {
	if got := extractFailureOutput("", 4000); got != "" {
		t.Errorf("empty input returned %q", got)
	}
}

func TestExtractFailureOutput_NoMarkersFallsBackToTail100(t *testing.T) {
	var b strings.Builder
	for i := 1; i <= 200; i++ {
		b.WriteString("benign ")
		b.WriteString(intToString(i))
		b.WriteByte('\n')
	}
	got := extractFailureOutput(b.String(), 4000)
	if got == "" {
		t.Fatal("fallback returned empty")
	}
	if !strings.Contains(got, "benign 200") {
		t.Errorf("fallback should preserve tail; got tail %q", got[max0(len(got)-50):])
	}
}

func TestExtractTestFilePaths_DedupAndSort(t *testing.T) {
	in := "fail in src/x.test.go and src/x.test.go and tests/a.spec.js"
	got := extractTestFilePaths(in)
	want := []string{"src/x.test.go", "tests/a.spec.js"}
	if !equalStrSlice(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestSetFixSeams_NilDoesNotReplace(t *testing.T) {
	// Smoke test — passing nil should not panic and should not replace
	// the existing seam.
	prev := SetFixAgentRunner(nil)
	if prev == nil {
		t.Errorf("expected previous runner to be non-nil")
	}
	SetFixAgentRunner(prev) // restore
	SetFixLogger(nil)
	// re-set to no-op explicitly to leave state stable
	SetFixLogger(&captureLogger{})
}

func TestExecFixTestRunner_EmptyCmdReturnsZero(t *testing.T) {
	r := execFixTestRunner{}
	code, err := r.Run(context.Background(), t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if code != 0 {
		t.Errorf("got %d, want 0", code)
	}
}

func TestExecFixTestRunner_ReportsExitCode(t *testing.T) {
	r := execFixTestRunner{}
	code, err := r.Run(context.Background(), t.TempDir(), "exit 7")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if code != 7 {
		t.Errorf("got %d, want 7", code)
	}
}

func TestNoopSeams_ReturnSafeDefaults(t *testing.T) {
	d := noopTestDedup{}
	if d.CanSkip() {
		t.Errorf("dedup CanSkip unexpected true")
	}
	d.RecordPass()
	(noopFixLogger{}).Logf("test")
}

func TestRunInlineFix_RecordsRunningAttemptCount(t *testing.T) {
	agent := &fakeFixAgentRunner{
		result: &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess},
	}
	restore := installFixSeams(t, agent, &fakeFixPromptRenderer{}, &fakeTestDedup{}, &fakeFixTestRunner{exitCodes: []int{1, 0}}, &captureLogger{})
	defer restore()
	req := newFixRequest(t)
	req.Options.MaxDepth = 2
	res, err := RunInlineFix(context.Background(), req)
	if err != nil {
		t.Fatalf("RunInlineFix: %v", err)
	}
	if res.AttemptCount != 2 {
		t.Errorf("AttemptCount = %d, want 2", res.AttemptCount)
	}
	if !res.ResolvedFailures {
		t.Errorf("ResolvedFailures = false, want true (second attempt passes)")
	}
}

// --- utilities ---------------------------------------------------------

func equalStrSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func max0(n int) int {
	if n < 0 {
		return 0
	}
	return n
}
