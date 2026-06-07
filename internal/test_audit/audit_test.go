package test_audit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/causal"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestDefaultOptions_MaxReworkCyclesIs1(t *testing.T) {
	// Regression-canary — the milestone's Watch For section pins
	// MaxReworkCycles=1 as load-bearing.
	if got := DefaultOptions().MaxReworkCycles; got != 1 {
		t.Fatalf("MaxReworkCycles default must be 1 (per milestone Watch For), got %d", got)
	}
}

func TestDefaultOptions_AllDetectorsOn(t *testing.T) {
	o := DefaultOptions()
	if !o.Enabled || !o.OrphanDetection || !o.WeakeningDetection || !o.RollingEnabled || !o.SymbolMapEnabled {
		t.Fatalf("default options should enable every detector toggle: %+v", o)
	}
	if o.SamplerK != 3 {
		t.Fatalf("default sampler K should be 3 (M89 contract), got %d", o.SamplerK)
	}
	if o.MaxTurns != 8 {
		t.Fatalf("default MaxTurns should be 8, got %d", o.MaxTurns)
	}
}

func TestRun_DisabledReturnsSkip(t *testing.T) {
	opts := Options{Enabled: false}
	req := &Request{
		ProjectDir: t.TempDir(),
		PromptsDir: promptsDir(t),
		Options:    opts,
	}
	// Need to pass an option that won't trigger withOptionDefaults to fill us
	// back to the canonical defaults — set a non-zero MaxTurns to mark
	// "explicit" intent.
	req.Options.MaxTurns = 4
	res, err := Run(context.Background(), req)
	if err != nil {
		t.Fatalf("disabled Run should not error, got %v", err)
	}
	if !res.Skipped || res.Verdict != VerdictPASS {
		t.Fatalf("disabled Run should skip with PASS, got %+v", res)
	}
}

func TestRun_NoTestFilesAndNoSampleSkips(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("REPO_MAP_CACHE_DIR", t.TempDir())

	prev := SetAgentRunner(&recordingAgent{})
	t.Cleanup(func() { SetAgentRunner(prev) })

	req := &Request{
		ProjectDir:       dir,
		PromptsDir:       promptsDir(t),
		TesterReportFile: filepath.Join(dir, "TESTER_REPORT.md"),
		CoderSummaryFile: filepath.Join(dir, "CODER_SUMMARY.md"),
		AuditReportFile:  filepath.Join(dir, "AUDIT.md"),
		Options:          Options{Enabled: true, MaxTurns: 4, MaxReworkCycles: 1},
	}
	res, err := Run(context.Background(), req)
	if err != nil {
		t.Fatalf("no-files Run should not error, got %v", err)
	}
	if !res.Skipped {
		t.Fatalf("no-files Run should report Skipped=true, got %+v", res)
	}
}

func TestRun_PASSPathInvokesAgentOnceAndRoutesOK(t *testing.T) {
	dir := setupGitRepo(t)
	t.Setenv("REPO_MAP_CACHE_DIR", t.TempDir())
	// Tester report with one ticked test file.
	tf := "tests/test_x.py"
	_ = os.MkdirAll(filepath.Join(dir, "tests"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, tf), []byte("# t"), 0o644)
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	testerReport := filepath.Join(dir, "TESTER_REPORT.md")
	_ = os.WriteFile(testerReport, []byte("- [x] `"+tf+"`\n"), 0o644)

	// Audit report with PASS.
	auditReport := filepath.Join(dir, "AUDIT.md")
	_ = os.WriteFile(auditReport, []byte("Verdict: PASS\n"), 0o644)

	rec := &recordingAgent{}
	prev := SetAgentRunner(rec)
	t.Cleanup(func() { SetAgentRunner(prev) })

	emitter := &recordingEmitter{}
	prevE := SetCausalEmitter(emitter)
	t.Cleanup(func() { SetCausalEmitter(prevE) })

	req := &Request{
		ProjectDir:       dir,
		PromptsDir:       promptsDir(t),
		TesterReportFile: testerReport,
		CoderSummaryFile: filepath.Join(dir, "CODER_SUMMARY.md"),
		AuditReportFile:  auditReport,
		Options: Options{
			Enabled:         true,
			MaxTurns:        4,
			MaxReworkCycles: 1,
			RollingEnabled:  false,
			ReviewerModel:   "claude-sonnet-4-6",
			ReviewerTools:   "Read",
			TesterModel:     "claude-sonnet-4-6",
			TesterTools:     "Read Write",
			TesterTurns:     50,
		},
	}
	res, err := Run(context.Background(), req)
	if err != nil {
		t.Fatalf("PASS path returned error: %v", err)
	}
	if res.Verdict != VerdictPASS {
		t.Fatalf("expected PASS verdict, got %v", res.Verdict)
	}
	if res.AgentCalls != 1 {
		t.Fatalf("PASS path should invoke agent exactly once, got %d", res.AgentCalls)
	}
	if rec.calls != 1 {
		t.Fatalf("recording-agent saw %d calls, expected 1", rec.calls)
	}
	if len(emitter.events) != 1 {
		t.Fatalf("expected 1 causal event, got %d", len(emitter.events))
	}
	if emitter.events[0].Type != "test_audit" {
		t.Fatalf("expected causal Type=test_audit, got %q", emitter.events[0].Type)
	}
	if !strings.Contains(emitter.events[0].Detail, "verdict=PASS") {
		t.Fatalf("expected Detail to contain verdict=PASS, got %q", emitter.events[0].Detail)
	}
}

func TestRun_NeedsWorkReworkLoopHitsCap(t *testing.T) {
	dir := setupGitRepo(t)
	t.Setenv("REPO_MAP_CACHE_DIR", t.TempDir())
	tf := "tests/test_x.py"
	_ = os.MkdirAll(filepath.Join(dir, "tests"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, tf), []byte("# t"), 0o644)
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	testerReport := filepath.Join(dir, "TESTER_REPORT.md")
	_ = os.WriteFile(testerReport, []byte("- [x] `"+tf+"`\n"), 0o644)
	auditReport := filepath.Join(dir, "AUDIT.md")
	_ = os.WriteFile(auditReport, []byte("Verdict: NEEDS_WORK\n"), 0o644)

	rec := &recordingAgent{}
	prev := SetAgentRunner(rec)
	t.Cleanup(func() { SetAgentRunner(prev) })

	req := &Request{
		ProjectDir:       dir,
		PromptsDir:       promptsDir(t),
		TesterReportFile: testerReport,
		CoderSummaryFile: filepath.Join(dir, "CODER_SUMMARY.md"),
		AuditReportFile:  auditReport,
		Options: Options{
			Enabled:         true,
			MaxTurns:        4,
			MaxReworkCycles: 1,
			RollingEnabled:  false,
			ReviewerModel:   "claude-sonnet-4-6",
			TesterModel:     "claude-sonnet-4-6",
			ReviewerTools:   "Read",
			TesterTools:     "Read Write",
			TesterTurns:     50,
		},
	}
	res, err := Run(context.Background(), req)
	if err != nil {
		t.Fatalf("rework loop should not error, got %v", err)
	}
	if res.Verdict != VerdictNEEDS_WORK {
		t.Fatalf("expected NEEDS_WORK after exhaustion, got %v", res.Verdict)
	}
	// Three agent invocations: initial audit + rework + re-audit.
	if res.AgentCalls != 3 {
		t.Fatalf("expected 3 agent calls (audit + rework + re-audit), got %d", res.AgentCalls)
	}
	if res.ReworkCycles != 1 {
		t.Fatalf("expected 1 rework cycle (cap), got %d", res.ReworkCycles)
	}
}

func TestRunStandalone_NoTestFilesSkips(t *testing.T) {
	dir := t.TempDir()
	req := &Request{
		ProjectDir: dir,
		PromptsDir: promptsDir(t),
	}
	res, err := RunStandalone(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStandalone should not error, got %v", err)
	}
	if !res.Skipped {
		t.Fatalf("RunStandalone should skip when no test files, got %+v", res)
	}
}

func TestRunStandalone_InvokesAgentAndParsesVerdict(t *testing.T) {
	dir := setupGitRepo(t)
	tf := "tests/test_a.py"
	_ = os.MkdirAll(filepath.Join(dir, "tests"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, tf), []byte("# t"), 0o644)
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	auditReport := filepath.Join(dir, "AUDIT.md")
	_ = os.WriteFile(auditReport, []byte("Verdict: PASS\n"), 0o644)

	rec := &recordingAgent{}
	prev := SetAgentRunner(rec)
	t.Cleanup(func() { SetAgentRunner(prev) })

	req := &Request{
		ProjectDir:      dir,
		PromptsDir:      promptsDir(t),
		AuditReportFile: auditReport,
		Options: Options{
			Enabled:       true,
			MaxTurns:      4,
			ReviewerModel: "claude-sonnet-4-6",
			ReviewerTools: "Read",
		},
	}
	res, err := RunStandalone(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStandalone errored: %v", err)
	}
	if res.AgentCalls != 1 || res.Verdict != VerdictPASS {
		t.Fatalf("expected 1 agent call + PASS, got calls=%d verdict=%v", res.AgentCalls, res.Verdict)
	}
}

func TestWithOptionDefaults_FillsZeroFields(t *testing.T) {
	merged := resolveDefaults(Options{Enabled: true, MaxTurns: 4})
	if merged.ReviewerModel == "" {
		t.Fatal("ReviewerModel should be filled from defaults")
	}
	if merged.MaxReworkCycles != 1 {
		t.Fatalf("MaxReworkCycles should default to 1, got %d", merged.MaxReworkCycles)
	}
	if merged.SamplerK != 3 {
		t.Fatalf("SamplerK should default to 3, got %d", merged.SamplerK)
	}
}

func TestWithOptionDefaults_EmptyOptionsYieldsFullDefaults(t *testing.T) {
	merged := resolveDefaults(Options{})
	want := DefaultOptions()
	if merged.MaxTurns != want.MaxTurns {
		t.Fatalf("MaxTurns mismatch: %d vs %d", merged.MaxTurns, want.MaxTurns)
	}
	if merged.ReviewerModel != want.ReviewerModel {
		t.Fatalf("ReviewerModel mismatch: %q vs %q", merged.ReviewerModel, want.ReviewerModel)
	}
}

func TestResolveProjectFile(t *testing.T) {
	got := resolveProjectFile("/proj", "", "AUDIT.md")
	if got != "/proj/AUDIT.md" {
		t.Fatalf("expected /proj/AUDIT.md, got %q", got)
	}
	got = resolveProjectFile("/proj", "custom.md", "AUDIT.md")
	if got != "/proj/custom.md" {
		t.Fatalf("expected /proj/custom.md, got %q", got)
	}
	got = resolveProjectFile("/proj", "/abs/path.md", "AUDIT.md")
	if got != "/abs/path.md" {
		t.Fatalf("expected absolute path, got %q", got)
	}
}

// promptsDir returns the path to the repo-level prompts/ directory so
// tests can render real templates (the orchestrator depends on
// test_audit.prompt.md existing).
func promptsDir(t *testing.T) string {
	t.Helper()
	// Walk up from the test file's working dir to the repo root.
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	cur := wd
	for i := 0; i < 6; i++ {
		candidate := filepath.Join(cur, "prompts", "test_audit.prompt.md")
		if _, err := os.Stat(candidate); err == nil {
			return filepath.Dir(candidate)
		}
		next := filepath.Dir(cur)
		if next == cur {
			break
		}
		cur = next
	}
	t.Fatalf("could not locate prompts/ relative to %s", wd)
	return ""
}

// recordingAgent is a fake AgentRunner that records call counts and
// returns success.
type recordingAgent struct {
	mu    sync.Mutex
	calls int
	err   error
}

func (r *recordingAgent) Run(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls++
	if r.err != nil {
		return nil, r.err
	}
	return &proto.AgentResultV1{
		Proto:   proto.AgentResultProtoV1,
		Outcome: proto.OutcomeSuccess,
	}, nil
}

// recordingEmitter captures causal event emissions for assertions.
type recordingEmitter struct {
	mu     sync.Mutex
	events []causal.EmitInput
}

func (r *recordingEmitter) Emit(in causal.EmitInput) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, in)
	return "evt", nil
}

// failingAgent returns an error on first invocation — used to verify the
// rework loop surfaces agent errors rather than swallowing them.
type failingAgent struct{ err error }

func (f failingAgent) Run(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	return nil, f.err
}

func TestRun_AgentErrorSurfaces(t *testing.T) {
	dir := setupGitRepo(t)
	t.Setenv("REPO_MAP_CACHE_DIR", t.TempDir())
	tf := "tests/test_x.py"
	_ = os.MkdirAll(filepath.Join(dir, "tests"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, tf), []byte("# t"), 0o644)
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	testerReport := filepath.Join(dir, "TESTER_REPORT.md")
	_ = os.WriteFile(testerReport, []byte("- [x] `"+tf+"`\n"), 0o644)
	auditReport := filepath.Join(dir, "AUDIT.md")
	_ = os.WriteFile(auditReport, []byte("Verdict: PASS\n"), 0o644)

	want := errors.New("boom")
	prev := SetAgentRunner(failingAgent{err: want})
	t.Cleanup(func() { SetAgentRunner(prev) })

	req := &Request{
		ProjectDir:       dir,
		PromptsDir:       promptsDir(t),
		TesterReportFile: testerReport,
		CoderSummaryFile: filepath.Join(dir, "CODER_SUMMARY.md"),
		AuditReportFile:  auditReport,
		Options:          Options{Enabled: true, MaxTurns: 4, MaxReworkCycles: 1, RollingEnabled: false},
	}
	_, err := Run(context.Background(), req)
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("expected agent error to surface, got %v", err)
	}
}
