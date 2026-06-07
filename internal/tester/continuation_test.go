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
)

// --- Test seams --------------------------------------------------------

type fakeContAgentRunner struct {
	results []*proto.AgentResultV1
	errs    []error
	calls   int
	gotReqs []*proto.AgentRequestV1
}

func (f *fakeContAgentRunner) Run(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	idx := f.calls
	f.calls++
	f.gotReqs = append(f.gotReqs, req)
	if idx < len(f.errs) && f.errs[idx] != nil {
		return nil, f.errs[idx]
	}
	if idx < len(f.results) {
		return f.results[idx], nil
	}
	return &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess, TurnsUsed: 10}, nil
}

type fakeContPromptRenderer struct {
	body    string
	err     error
	calls   int
	gotVars []map[string]string
}

func (f *fakeContPromptRenderer) Render(_, _ string, vars map[string]string) (string, error) {
	f.calls++
	copied := map[string]string{}
	for k, v := range vars {
		copied[k] = v
	}
	f.gotVars = append(f.gotVars, copied)
	if f.err != nil {
		return "", f.err
	}
	if f.body == "" {
		return "continuation body", nil
	}
	return f.body, nil
}

type fakeContGitDiff struct {
	changed int
	calls   int
}

func (f *fakeContGitDiff) FilesChanged(_ string) int {
	f.calls++
	return f.changed
}

type fakeContRemainingReader struct {
	values []int
	calls  int
}

func (f *fakeContRemainingReader) Read(_ string) int {
	idx := f.calls
	f.calls++
	if idx >= len(f.values) {
		if len(f.values) == 0 {
			return 0
		}
		return f.values[len(f.values)-1]
	}
	return f.values[idx]
}

type fakeContAuditRunner struct {
	calls    int
	duration int
	turns    int
	err      error
}

func (f *fakeContAuditRunner) Run(_ context.Context, _ string) (int, int, error) {
	f.calls++
	return f.duration, f.turns, f.err
}

type fakeContStateHalt struct {
	called     bool
	stage      string
	exitReason string
	resumeFlag string
	task       string
	notes      string
}

func (f *fakeContStateHalt) Write(_ context.Context, stage, exitReason, resumeFlag, task, notes string) error {
	f.called = true
	f.stage = stage
	f.exitReason = exitReason
	f.resumeFlag = resumeFlag
	f.task = task
	f.notes = notes
	return nil
}

type fakeContContextBuilder struct {
	gotStage      string
	gotAttempt    int
	gotMax        int
	gotCumulative int
	gotNextBudget int
	body          string
	calls         int
}

func (f *fakeContContextBuilder) Build(stage string, attempt, maxAttempts, cumulative, nextBudget int) string {
	f.gotStage = stage
	f.gotAttempt = attempt
	f.gotMax = maxAttempts
	f.gotCumulative = cumulative
	f.gotNextBudget = nextBudget
	f.calls++
	if f.body == "" {
		return "default ctx"
	}
	return f.body
}

func installContSeams(t *testing.T, agent ContinuationAgentRunner, render ContinuationPromptRenderer, diff GitDiffReporter, rem RemainingReader, audit TestAuditRunner, halt StateHaltWriter, builder ContinuationContextBuilder, logger ContinuationLogger) func() {
	t.Helper()
	prevA := SetContinuationAgentRunner(agent)
	prevP := SetContinuationPromptRenderer(render)
	prevG := SetContinuationGitDiff(diff)
	prevR := SetContinuationRemainingReader(rem)
	prevAu := SetContinuationTestAuditRunner(audit)
	prevH := SetContinuationStateHaltWriter(halt)
	prevB := SetContinuationContextBuilder(builder)
	prevL := SetContinuationLogger(logger)
	return func() {
		SetContinuationAgentRunner(prevA)
		SetContinuationPromptRenderer(prevP)
		SetContinuationGitDiff(prevG)
		SetContinuationRemainingReader(prevR)
		SetContinuationTestAuditRunner(prevAu)
		SetContinuationStateHaltWriter(prevH)
		SetContinuationContextBuilder(prevB)
		SetContinuationLogger(prevL)
	}
}

func newContRequest(t *testing.T) *ContinuationRequest {
	t.Helper()
	dir := t.TempDir()
	reportDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(reportDir, 0o755); err != nil {
		t.Fatal(err)
	}
	return &ContinuationRequest{
		ProjectDir:       dir,
		PromptsDir:       "prompts",
		Task:             "implement tests",
		ResumeFlag:       "--start-at tester",
		InitialRemaining: 3,
		InitialTurnsUsed: 50,
		RunningTiming:    ZeroTiming(),
		Options:          DefaultContinuationOptions(),
	}
}

// --- Regression-canary tests -------------------------------------------

func TestDefaultContinuationOptions_MaxAttemptsIs3(t *testing.T) {
	if got := DefaultContinuationOptions().MaxAttempts; got != 3 {
		t.Fatalf("DefaultContinuationOptions().MaxAttempts = %d, want 3 (regression-canary)", got)
	}
}

func TestDefaultContinuationOptions_FieldDefaults(t *testing.T) {
	opts := DefaultContinuationOptions()
	if !opts.Enabled {
		t.Errorf("Enabled = false, want true")
	}
	if opts.NextTurnBudget != 50 {
		t.Errorf("NextTurnBudget = %d, want 50", opts.NextTurnBudget)
	}
	if opts.Model != "claude-sonnet-4-6" {
		t.Errorf("Model = %q, want claude-sonnet-4-6", opts.Model)
	}
}

func TestRunContinuations_DisabledSkipsLoop(t *testing.T) {
	agent := &fakeContAgentRunner{}
	restore := installContSeams(t, agent, &fakeContPromptRenderer{}, &fakeContGitDiff{changed: 5}, &fakeContRemainingReader{}, &fakeContAuditRunner{}, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()

	req := newContRequest(t)
	req.Options.Enabled = false
	res, err := RunContinuations(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if res.AttemptsUsed != 0 {
		t.Errorf("AttemptsUsed = %d, want 0", res.AttemptsUsed)
	}
	if agent.calls != 0 {
		t.Errorf("agent.calls = %d, want 0", agent.calls)
	}
}

func TestRunContinuations_GitDiffGateSkipsLoop(t *testing.T) {
	agent := &fakeContAgentRunner{}
	diff := &fakeContGitDiff{changed: 0} // zero changes
	restore := installContSeams(t, agent, &fakeContPromptRenderer{}, diff, &fakeContRemainingReader{}, &fakeContAuditRunner{}, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()

	req := newContRequest(t)
	res, err := RunContinuations(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if res.Continued {
		t.Errorf("Continued = true, want false")
	}
	if agent.calls != 0 {
		t.Errorf("agent.calls = %d, want 0 (git-diff gate should skip the loop)", agent.calls)
	}
	if diff.calls != 1 {
		t.Errorf("diff.calls = %d, want 1", diff.calls)
	}
}

func TestRunContinuations_UpstreamIsRecoverable(t *testing.T) {
	agent := &fakeContAgentRunner{
		results: []*proto.AgentResultV1{
			{
				Proto:            proto.AgentResultProtoV1,
				Outcome:          proto.OutcomeFatalError,
				ErrorCategory:    supervisor.CategoryUpstream,
				ErrorSubcategory: "api_overloaded",
				ErrorMessage:     "503 from API",
				TurnsUsed:        3,
			},
		},
	}
	halt := &fakeContStateHalt{}
	restore := installContSeams(t, agent, &fakeContPromptRenderer{}, &fakeContGitDiff{changed: 2}, &fakeContRemainingReader{values: []int{3}}, &fakeContAuditRunner{}, halt, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()

	res, err := RunContinuations(context.Background(), newContRequest(t))
	if err != nil {
		t.Fatalf("expected nil error for recoverable UPSTREAM, got %v", err)
	}
	if !res.UpstreamErrored {
		t.Errorf("UpstreamErrored = false, want true")
	}
	if !res.SkipFinalChecks {
		t.Errorf("SkipFinalChecks = false, want true")
	}
	if !halt.called {
		t.Errorf("StateHaltWriter not called")
	}
	if halt.stage != "tester" {
		t.Errorf("halt.stage = %q, want tester", halt.stage)
	}
	if halt.exitReason != "upstream_error" {
		t.Errorf("halt.exitReason = %q, want upstream_error", halt.exitReason)
	}
}

func TestRunContinuations_SuccessRunsTestAudit(t *testing.T) {
	agent := &fakeContAgentRunner{
		results: []*proto.AgentResultV1{
			{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess, TurnsUsed: 30},
		},
	}
	audit := &fakeContAuditRunner{}
	rem := &fakeContRemainingReader{values: []int{0}}
	restore := installContSeams(t, agent, &fakeContPromptRenderer{}, &fakeContGitDiff{changed: 2}, rem, audit, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()

	res, err := RunContinuations(context.Background(), newContRequest(t))
	if err != nil {
		t.Fatalf("RunContinuations: %v", err)
	}
	if !res.Continued {
		t.Errorf("Continued = false, want true")
	}
	if res.RemainingTests != 0 {
		t.Errorf("RemainingTests = %d, want 0", res.RemainingTests)
	}
	if audit.calls != 1 {
		t.Errorf("audit.calls = %d, want 1", audit.calls)
	}
}

func TestRunContinuations_AccumulatesTimingPerIteration(t *testing.T) {
	// Two iterations; report file has FilesWritten=2, after second
	// continuation accumulate adds 2 more → 4.
	dir := t.TempDir()
	reportPath := filepath.Join(dir, ".tekhton", "TESTER_REPORT.md")
	if err := os.MkdirAll(filepath.Dir(reportPath), 0o755); err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile(filepath.Join("testdata", "continuation", "tester_report_with_remaining.md"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(reportPath, fixture, 0o644); err != nil {
		t.Fatal(err)
	}

	agent := &fakeContAgentRunner{
		results: []*proto.AgentResultV1{
			{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess, TurnsUsed: 20},
			{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess, TurnsUsed: 25},
		},
	}
	rem := &fakeContRemainingReader{values: []int{2, 0}}
	restore := installContSeams(t, agent, &fakeContPromptRenderer{}, &fakeContGitDiff{changed: 5}, rem, &fakeContAuditRunner{}, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()

	req := newContRequest(t)
	req.ProjectDir = dir
	res, err := RunContinuations(context.Background(), req)
	if err != nil {
		t.Fatalf("RunContinuations: %v", err)
	}
	if res.AttemptsUsed != 2 {
		t.Errorf("AttemptsUsed = %d, want 2", res.AttemptsUsed)
	}
	// FilesWritten=2 from fixture, accumulated over 2 iters = 4.
	if res.Timing.FilesWritten != 4 {
		t.Errorf("Timing.FilesWritten = %d, want 4 (accumulated)", res.Timing.FilesWritten)
	}
	// Cumulative turns: initial 50 + 20 + 25 = 95.
	if res.CumulativeTurns != 95 {
		t.Errorf("CumulativeTurns = %d, want 95", res.CumulativeTurns)
	}
}

func TestRunContinuations_StopsAtMaxAttempts(t *testing.T) {
	agent := &fakeContAgentRunner{
		results: []*proto.AgentResultV1{
			{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeTurnExhausted, TurnsUsed: 50},
			{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeTurnExhausted, TurnsUsed: 50},
			{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeTurnExhausted, TurnsUsed: 50},
			{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeTurnExhausted, TurnsUsed: 50},
		},
	}
	// REMAINING stays positive throughout, forcing the loop to exhaust.
	rem := &fakeContRemainingReader{values: []int{3, 2, 1, 1, 1, 1}}
	restore := installContSeams(t, agent, &fakeContPromptRenderer{}, &fakeContGitDiff{changed: 5}, rem, &fakeContAuditRunner{}, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()

	res, err := RunContinuations(context.Background(), newContRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	if res.AttemptsUsed != 3 {
		t.Errorf("AttemptsUsed = %d, want 3 (max)", res.AttemptsUsed)
	}
	if agent.calls != 3 {
		t.Errorf("agent.calls = %d, want 3", agent.calls)
	}
	if res.Continued {
		t.Errorf("Continued = true, want false (REMAINING > 0)")
	}
}

func TestRunContinuations_NilRequestReturnsError(t *testing.T) {
	if _, err := RunContinuations(context.Background(), nil); err == nil {
		t.Fatal("expected non-nil error for nil request")
	}
}

func TestRunContinuations_RenderErrorPropagates(t *testing.T) {
	render := &fakeContPromptRenderer{err: errors.New("template missing")}
	restore := installContSeams(t, &fakeContAgentRunner{}, render, &fakeContGitDiff{changed: 2}, &fakeContRemainingReader{values: []int{2}}, &fakeContAuditRunner{}, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()
	if _, err := RunContinuations(context.Background(), newContRequest(t)); err == nil {
		t.Fatal("expected non-nil error for renderer failure")
	}
}

func TestRunContinuations_AgentInvocationErrorPropagates(t *testing.T) {
	agent := &fakeContAgentRunner{errs: []error{errors.New("supervisor crashed")}}
	restore := installContSeams(t, agent, &fakeContPromptRenderer{}, &fakeContGitDiff{changed: 2}, &fakeContRemainingReader{values: []int{2}}, &fakeContAuditRunner{}, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()
	if _, err := RunContinuations(context.Background(), newContRequest(t)); err == nil {
		t.Fatal("expected non-nil error for agent failure")
	}
}

func TestRunContinuations_PromptVarsIncludeContinuationContext(t *testing.T) {
	render := &fakeContPromptRenderer{}
	builder := &fakeContContextBuilder{body: "CTX-BLOCK"}
	rem := &fakeContRemainingReader{values: []int{0}}
	restore := installContSeams(t, &fakeContAgentRunner{}, render, &fakeContGitDiff{changed: 2}, rem, &fakeContAuditRunner{}, &fakeContStateHalt{}, builder, &captureLogger{})
	defer restore()

	_, err := RunContinuations(context.Background(), newContRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(render.gotVars) == 0 {
		t.Fatal("renderer not called")
	}
	got := render.gotVars[0]["CONTINUATION_CONTEXT"]
	if got != "CTX-BLOCK" {
		t.Errorf("CONTINUATION_CONTEXT = %q, want CTX-BLOCK", got)
	}
	if builder.gotStage != "tester" {
		t.Errorf("builder.gotStage = %q, want tester", builder.gotStage)
	}
}

func TestRunContinuations_TaskFlowsIntoPromptVars(t *testing.T) {
	render := &fakeContPromptRenderer{}
	restore := installContSeams(t, &fakeContAgentRunner{}, render, &fakeContGitDiff{changed: 2}, &fakeContRemainingReader{values: []int{0}}, &fakeContAuditRunner{}, &fakeContStateHalt{}, &fakeContContextBuilder{}, &captureLogger{})
	defer restore()

	req := newContRequest(t)
	req.Task = "specific task"
	if _, err := RunContinuations(context.Background(), req); err != nil {
		t.Fatal(err)
	}
	if got := render.gotVars[0]["TASK"]; got != "specific task" {
		t.Errorf("TASK = %q, want 'specific task'", got)
	}
}

// --- RunAndRecordTestAudit ---------------------------------------------

func TestRunAndRecordTestAudit_DelegatesToSeam(t *testing.T) {
	audit := &fakeContAuditRunner{duration: 5, turns: 2}
	prev := SetContinuationTestAuditRunner(audit)
	defer SetContinuationTestAuditRunner(prev)

	d, turns, err := RunAndRecordTestAudit(context.Background(), "/some/dir")
	if err != nil {
		t.Fatal(err)
	}
	if d != 5 || turns != 2 {
		t.Errorf("got (%d,%d), want (5,2)", d, turns)
	}
	if audit.calls != 1 {
		t.Errorf("audit.calls = %d, want 1", audit.calls)
	}
}

// --- Helper / coverage tests -------------------------------------------

func TestWithContinuationDefaults_FillsZeros(t *testing.T) {
	o := withContinuationDefaults(ContinuationOptions{})
	if o.MaxAttempts != 3 || o.NextTurnBudget != 50 || o.Model == "" ||
		o.AgentTools == "" || o.ReportFile == "" || o.PromptName == "" {
		t.Errorf("unfilled: %+v", o)
	}
}

func TestResolveContinuationPath_Branches(t *testing.T) {
	if got := resolveContinuationPath("", "rel/path"); got != "rel/path" {
		t.Errorf("empty projectDir: got %q", got)
	}
	if got := resolveContinuationPath("/proj", "/abs/path"); got != "/abs/path" {
		t.Errorf("abs path: got %q", got)
	}
	if got := resolveContinuationPath("/proj", "rel"); got != filepath.Join("/proj", "rel") {
		t.Errorf("rel resolve: got %q", got)
	}
	if got := resolveContinuationPath("/proj", ""); got != "" {
		t.Errorf("empty path: got %q", got)
	}
}

func TestDefaultContextBuilder_RendersTesterAndCoderLabels(t *testing.T) {
	b := defaultContextBuilder{}
	out := b.Build("tester", 1, 3, 50, 50)
	if !strings.Contains(out, "Tester") {
		t.Errorf("expected Tester label; got %q", out)
	}
	if !strings.Contains(out, "1/3") {
		t.Errorf("expected attempt counter; got %q", out)
	}
	if !strings.Contains(b.Build("coder", 2, 4, 60, 30), "Coder") {
		t.Errorf("expected Coder label")
	}
}

func TestFileRemainingReader_ReadsCount(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "report.md")
	body := "- [x] done\n- [ ] todo1\n- [ ] todo2\nNo bullet\n- [ ] todo3\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := (fileRemainingReader{}).Read(path); got != 3 {
		t.Errorf("got %d, want 3", got)
	}
	if got := (fileRemainingReader{}).Read(""); got != 0 {
		t.Errorf("empty path: got %d, want 0", got)
	}
	if got := (fileRemainingReader{}).Read(filepath.Join(dir, "nonexistent.md")); got != 0 {
		t.Errorf("missing: got %d, want 0", got)
	}
}

func TestExecGitDiffReporter_CleanDirReturnsZero(t *testing.T) {
	dir := t.TempDir()
	// Init a git repo and commit a file so working tree is clean.
	mustRunGit(t, dir, "init", "-q")
	mustRunGit(t, dir, "config", "user.email", "test@example.com")
	mustRunGit(t, dir, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustRunGit(t, dir, "add", ".")
	mustRunGit(t, dir, "commit", "-q", "-m", "init")
	if got := (execGitDiffReporter{}).FilesChanged(dir); got != 0 {
		t.Errorf("clean tree returned %d, want 0", got)
	}
}

func TestExecGitDiffReporter_DirtyDirReportsChange(t *testing.T) {
	dir := t.TempDir()
	mustRunGit(t, dir, "init", "-q")
	mustRunGit(t, dir, "config", "user.email", "test@example.com")
	mustRunGit(t, dir, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustRunGit(t, dir, "add", ".")
	mustRunGit(t, dir, "commit", "-q", "-m", "init")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("changed"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := (execGitDiffReporter{}).FilesChanged(dir); got != 1 {
		t.Errorf("dirty tree: got %d, want 1", got)
	}
}

func TestExecGitDiffReporter_NonGitDirReturnsZero(t *testing.T) {
	// A directory that has never had `git init` run in it. Both
	// gitWorktreeDirty probes fail (git exits non-zero), so FilesChanged
	// falls through to return 0 — the continuation loop is correctly skipped.
	// This exercises the "git absent or not a repo" edge case noted in the
	// m38.3 reviewer report.
	dir := t.TempDir()
	if got := (execGitDiffReporter{}).FilesChanged(dir); got != 0 {
		t.Errorf("non-git dir: FilesChanged returned %d, want 0", got)
	}
}

func TestNoopContinuationSeams_Safe(t *testing.T) {
	// m38.4: noopTestAuditRunner was removed when the default seam flipped
	// to nativeTestAuditRunner. Empty projectDir still short-circuits.
	if _, _, err := (nativeTestAuditRunner{}).Run(context.Background(), ""); err != nil {
		t.Errorf("audit err: %v", err)
	}
	if err := (noopStateHaltWriter{}).Write(context.Background(), "", "", "", "", ""); err != nil {
		t.Errorf("halt err: %v", err)
	}
	if _, err := (noopContinuationAgent{}).Run(context.Background(), nil); err != nil {
		t.Errorf("agent err: %v", err)
	}
	if _, err := (noopContinuationRenderer{}).Render("", "", nil); err != nil {
		t.Errorf("render err: %v", err)
	}
	(noopContinuationLogger{}).Logf("hi")
}

func TestSetContinuationSeams_NilDoesNotReplace(t *testing.T) {
	prev := SetContinuationAgentRunner(nil)
	if prev == nil {
		t.Errorf("prev nil")
	}
	SetContinuationAgentRunner(prev)
	SetContinuationLogger(nil) // nil logger restores no-op
	SetContinuationLogger(&captureLogger{})
}

// --- helpers -----------------------------------------------------------

func mustRunGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	if _, err := runGit(dir, args...); err != nil {
		t.Skipf("git not available or repo init failed: %v", err)
	}
}
