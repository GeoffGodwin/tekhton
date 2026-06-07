package tdd

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// --- Test seams --------------------------------------------------------

// fakeAgentRunner records the request it received and returns the
// configured result/err. Used by every test in this file.
type fakeAgentRunner struct {
	gotReq *proto.AgentRequestV1
	result *proto.AgentResultV1
	err    error
	calls  int
}

func (f *fakeAgentRunner) Run(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	f.calls++
	f.gotReq = req
	return f.result, f.err
}

// fakePromptRenderer returns the configured body and records the vars.
type fakePromptRenderer struct {
	body    string
	err     error
	gotVars map[string]string
}

func (f *fakePromptRenderer) Render(_, _ string, vars map[string]string) (string, error) {
	f.gotVars = vars
	if f.err != nil {
		return "", f.err
	}
	if f.body == "" {
		return "test prompt body", nil
	}
	return f.body, nil
}

// fakeStateWriter records a single WriteHalt call so the UPSTREAM test
// can assert state was written before the error returned.
type fakeStateWriter struct {
	called     bool
	stage      string
	exitReason string
	resumeFlag string
	task       string
	notes      string
}

func (f *fakeStateWriter) WriteHalt(_ context.Context, stage, exitReason, resumeFlag, task, notes string) error {
	f.called = true
	f.stage = stage
	f.exitReason = exitReason
	f.resumeFlag = resumeFlag
	f.task = task
	f.notes = notes
	return nil
}

// installSeams swaps all three seams for the duration of the test.
func installSeams(t *testing.T, agent AgentRunner, render PromptRenderer, st StateWriter) func() {
	t.Helper()
	prevA := SetAgentRunner(agent)
	prevP := SetPromptRenderer(render)
	prevS := SetStateWriter(st)
	return func() {
		SetAgentRunner(prevA)
		SetPromptRenderer(prevP)
		SetStateWriter(prevS)
	}
}

// newRequest builds a typical Request rooted at a tmp dir.
func newRequest(t *testing.T) (*Request, string) {
	t.Helper()
	dir := t.TempDir()
	return &Request{
		ProjectDir:          dir,
		PromptsDir:          "prompts",
		Task:                "implement feature X",
		ArchitectureContent: "Arch content",
		Options: Options{
			PreflightFile: filepath.Join(dir, "TESTER_PREFLIGHT.md"),
			LogDir:        filepath.Join(dir, ".claude", "logs"),
			Timestamp:     "20260606-120000",
			AgentTools:    "Read Write",
		},
	}, dir
}

// writePreflightFixture copies the testdata preflight into the request's
// configured preflight location so the success path finds it on disk.
func writePreflightFixture(t *testing.T, dstPath string) {
	t.Helper()
	src, err := os.Open(filepath.Join("testdata", "TESTER_PREFLIGHT.md"))
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer src.Close()
	if err := os.MkdirAll(filepath.Dir(dstPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	dst, err := os.Create(dstPath)
	if err != nil {
		t.Fatalf("create dst: %v", err)
	}
	defer dst.Close()
	if _, err := io.Copy(dst, src); err != nil {
		t.Fatalf("copy: %v", err)
	}
}

// --- Regression-canary test --------------------------------------------

func TestRun_UpstreamReturnsNonNilError(t *testing.T) {
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:            proto.AgentResultProtoV1,
			ErrorCategory:    supervisor.CategoryUpstream,
			ErrorSubcategory: "rate_limit",
			ErrorMessage:     "Too many requests",
			ExitCode:         1,
			TurnsUsed:        1,
		},
	}
	render := &fakePromptRenderer{}
	st := &fakeStateWriter{}
	defer installSeams(t, agent, render, st)()

	req, _ := newRequest(t)
	_, err := Run(context.Background(), req)
	if err == nil {
		t.Fatal("UPSTREAM error must return non-nil error — regression at stages/tester_tdd.sh:85")
	}
	if !strings.Contains(err.Error(), "rate_limit") {
		t.Errorf("error should include subcategory; got %v", err)
	}
	if !st.called {
		t.Fatal("state.WriteHalt must be called before returning UPSTREAM error")
	}
	if st.stage != "tester" {
		t.Errorf("state stage = %q, want tester", st.stage)
	}
	if !strings.Contains(st.exitReason, "TDD pre-flight API error") {
		t.Errorf("state exitReason missing canonical message; got %q", st.exitReason)
	}
	if !strings.Contains(st.exitReason, "rate_limit") {
		t.Errorf("state exitReason should include subcategory; got %q", st.exitReason)
	}
}

func TestRun_UpstreamEmptySubcategoryFallsBackToUnknown(t *testing.T) {
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:         proto.AgentResultProtoV1,
			ErrorCategory: supervisor.CategoryUpstream,
			ErrorMessage:  "Server error",
			ExitCode:      1,
		},
	}
	render := &fakePromptRenderer{}
	st := &fakeStateWriter{}
	defer installSeams(t, agent, render, st)()

	req, _ := newRequest(t)
	_, err := Run(context.Background(), req)
	if err == nil {
		t.Fatal("UPSTREAM with no subcategory must still return non-nil error")
	}
	if !strings.Contains(st.exitReason, "unknown") {
		t.Errorf("missing subcategory must fall back to 'unknown'; got %q", st.exitReason)
	}
}

// --- Null-run non-fatal --------------------------------------------------

func TestRun_NullRunIsNonFatal(t *testing.T) {
	// Null-run signal: non-zero exit + turns <= DefaultNullRunThreshold(2)
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:     proto.AgentResultProtoV1,
			ExitCode:  1,
			TurnsUsed: 1,
		},
	}
	render := &fakePromptRenderer{}
	st := &fakeStateWriter{}
	defer installSeams(t, agent, render, st)()

	req, _ := newRequest(t)
	res, err := Run(context.Background(), req)
	if err != nil {
		t.Fatalf("null run must return nil error; got %v", err)
	}
	if res == nil {
		t.Fatal("null run must return a Result (with NullRun=true)")
	}
	if !res.NullRun {
		t.Error("Result.NullRun must be true for null-run agent result")
	}
	if st.called {
		t.Error("null-run path must NOT write halt state")
	}
}

// --- Success path: preflight exists, archive created, timing parsed ------

func TestRun_SuccessArchivesPreflightAndParsesTiming(t *testing.T) {
	req, _ := newRequest(t)
	writePreflightFixture(t, req.Options.PreflightFile)

	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:     proto.AgentResultProtoV1,
			ExitCode:  0,
			TurnsUsed: 5,
		},
	}
	render := &fakePromptRenderer{}
	st := &fakeStateWriter{}
	defer installSeams(t, agent, render, st)()

	res, err := Run(context.Background(), req)
	if err != nil {
		t.Fatalf("success path returned err: %v", err)
	}
	if !res.PreflightExists {
		t.Error("PreflightExists should be true when the file is on disk")
	}
	if res.NullRun {
		t.Error("Successful run must not flag NullRun")
	}

	// Archive: ${LogDir}/${Timestamp}_TESTER_PREFLIGHT.md
	wantArchive := filepath.Join(req.Options.LogDir,
		"20260606-120000_TESTER_PREFLIGHT.md")
	if res.ArchivePath != wantArchive {
		t.Errorf("archive path = %q, want %q", res.ArchivePath, wantArchive)
	}
	if _, err := os.Stat(wantArchive); err != nil {
		t.Errorf("archive file missing: %v", err)
	}

	// Timing parsed via tester.ParseTesterTiming in replace mode.
	if res.Timing.ExecCount != 1 {
		t.Errorf("Timing.ExecCount = %d, want 1", res.Timing.ExecCount)
	}
	if res.Timing.ExecApproxS != 3 {
		t.Errorf("Timing.ExecApproxS = %d, want 3", res.Timing.ExecApproxS)
	}
	if res.Timing.FilesWritten != 1 {
		t.Errorf("Timing.FilesWritten = %d, want 1", res.Timing.FilesWritten)
	}
	if res.Turns != 5 {
		t.Errorf("Turns = %d, want 5", res.Turns)
	}
}

func TestRun_SuccessWithoutPreflightFile(t *testing.T) {
	// Agent succeeded (non-null) but produced no preflight artifact.
	// Bash semantics: warn and continue. Go semantics: return Result
	// with PreflightExists=false and NullRun=false.
	req, _ := newRequest(t)
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:     proto.AgentResultProtoV1,
			ExitCode:  0,
			TurnsUsed: 5,
		},
	}
	defer installSeams(t, agent, &fakePromptRenderer{}, &fakeStateWriter{})()

	res, err := Run(context.Background(), req)
	if err != nil {
		t.Fatalf("missing preflight should not return err; got %v", err)
	}
	if res.PreflightExists {
		t.Error("PreflightExists must be false when file missing")
	}
	if res.ArchivePath != "" {
		t.Error("ArchivePath must be empty when no preflight to archive")
	}
}

// --- Defaults & options --------------------------------------------------

func TestRun_DefaultMaxTurnsIsTen(t *testing.T) {
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:     proto.AgentResultProtoV1,
			ExitCode:  0,
			TurnsUsed: 5,
		},
	}
	defer installSeams(t, agent, &fakePromptRenderer{}, &fakeStateWriter{})()

	req, _ := newRequest(t)
	req.Options.MaxTurns = 0 // not set — should pick up DefaultMaxTurns
	if _, err := Run(context.Background(), req); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if agent.gotReq == nil {
		t.Fatal("agent.Run was not invoked")
	}
	if agent.gotReq.MaxTurns != DefaultMaxTurns {
		t.Errorf("MaxTurns = %d, want %d (TESTER_WRITE_FAILING_MAX_TURNS default)",
			agent.gotReq.MaxTurns, DefaultMaxTurns)
	}
}

func TestRun_OptionsRespectOverrides(t *testing.T) {
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:     proto.AgentResultProtoV1,
			ExitCode:  0,
			TurnsUsed: 5,
		},
	}
	defer installSeams(t, agent, &fakePromptRenderer{}, &fakeStateWriter{})()

	req, _ := newRequest(t)
	req.Options.MaxTurns = 25
	req.Options.Model = "custom-model"
	req.Options.AgentTools = "Read"

	if _, err := Run(context.Background(), req); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if agent.gotReq.MaxTurns != 25 {
		t.Errorf("MaxTurns override not honored: %d", agent.gotReq.MaxTurns)
	}
	if agent.gotReq.Model != "custom-model" {
		t.Errorf("Model override not honored: %q", agent.gotReq.Model)
	}
	if agent.gotReq.AllowedTools != "Read" {
		t.Errorf("AllowedTools override not honored: %q", agent.gotReq.AllowedTools)
	}
}

// --- Prompt-render error -------------------------------------------------

func TestRun_PromptRenderErrorReturnsError(t *testing.T) {
	render := &fakePromptRenderer{err: errors.New("boom")}
	defer installSeams(t, &fakeAgentRunner{}, render, &fakeStateWriter{})()

	req, _ := newRequest(t)
	_, err := Run(context.Background(), req)
	if err == nil {
		t.Fatal("prompt render error must propagate as non-nil")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("error should wrap render err; got %v", err)
	}
}

// --- Agent invocation error ---------------------------------------------

func TestRun_AgentInvocationErrorReturnsError(t *testing.T) {
	agent := &fakeAgentRunner{err: errors.New("supervisor down")}
	defer installSeams(t, agent, &fakePromptRenderer{}, &fakeStateWriter{})()

	req, _ := newRequest(t)
	_, err := Run(context.Background(), req)
	if err == nil {
		t.Fatal("agent invocation err must propagate")
	}
	if !strings.Contains(err.Error(), "supervisor down") {
		t.Errorf("error should wrap agent err; got %v", err)
	}
}

// --- Nil request ---------------------------------------------------------

func TestRun_NilRequestReturnsError(t *testing.T) {
	_, err := Run(context.Background(), nil)
	if err == nil {
		t.Fatal("nil request must return error")
	}
}

// --- Prompt variables ----------------------------------------------------

func TestRun_PromptVarsIncludeArchitectureRepoMapMilestone(t *testing.T) {
	render := &fakePromptRenderer{}
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:     proto.AgentResultProtoV1,
			ExitCode:  0,
			TurnsUsed: 5,
		},
	}
	defer installSeams(t, agent, render, &fakeStateWriter{})()

	req, _ := newRequest(t)
	req.ArchitectureContent = "ARCH_BODY"
	req.RepoMapContent = "REPO_BODY"
	req.MilestoneBlock = "MILESTONE_BODY"
	if _, err := Run(context.Background(), req); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if render.gotVars["ARCHITECTURE_CONTENT"] != "ARCH_BODY" {
		t.Errorf("ARCHITECTURE_CONTENT not threaded: %q", render.gotVars["ARCHITECTURE_CONTENT"])
	}
	if render.gotVars["REPO_MAP_CONTENT"] != "REPO_BODY" {
		t.Errorf("REPO_MAP_CONTENT not threaded: %q", render.gotVars["REPO_MAP_CONTENT"])
	}
	if render.gotVars["MILESTONE_BLOCK"] != "MILESTONE_BODY" {
		t.Errorf("MILESTONE_BLOCK not threaded: %q", render.gotVars["MILESTONE_BLOCK"])
	}
	if render.gotVars["TASK"] != "implement feature X" {
		t.Errorf("TASK not threaded: %q", render.gotVars["TASK"])
	}
}

func TestRun_EmptyArchitectureContentFallsBackToNotice(t *testing.T) {
	render := &fakePromptRenderer{}
	agent := &fakeAgentRunner{
		result: &proto.AgentResultV1{
			Proto:     proto.AgentResultProtoV1,
			ExitCode:  0,
			TurnsUsed: 5,
		},
	}
	defer installSeams(t, agent, render, &fakeStateWriter{})()

	req, _ := newRequest(t)
	req.ArchitectureContent = ""
	if _, err := Run(context.Background(), req); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !strings.Contains(render.gotVars["ARCHITECTURE_CONTENT"], "not found") {
		t.Errorf("missing architecture should fall back to notice; got %q",
			render.gotVars["ARCHITECTURE_CONTENT"])
	}
}

// --- Resume flag construction -------------------------------------------

func TestBuildResumeFlag_DefaultIsStartAtTest(t *testing.T) {
	got := buildResumeFlag("test", &Request{})
	if got != "--start-at test" {
		t.Errorf("default resume flag = %q, want --start-at test", got)
	}
}

func TestBuildResumeFlag_HumanModeAddsHumanFlag(t *testing.T) {
	got := buildResumeFlag("test", &Request{HumanMode: true})
	if got != "--human --start-at test" {
		t.Errorf("human resume flag = %q", got)
	}
}

func TestBuildResumeFlag_HumanModeWithTag(t *testing.T) {
	got := buildResumeFlag("test", &Request{HumanMode: true, HumanNotesTag: "BUG"})
	if got != "--human BUG --start-at test" {
		t.Errorf("human+tag resume flag = %q", got)
	}
}

func TestBuildResumeFlag_MilestoneMode(t *testing.T) {
	got := buildResumeFlag("test", &Request{MilestoneMode: true})
	if got != "--milestone --start-at test" {
		t.Errorf("milestone resume flag = %q", got)
	}
}

// --- Default seam coverage ----------------------------------------------

func TestDefaultPromptRenderer_DelegatesToPromptPackage(t *testing.T) {
	// Drive the default renderer through a tmpdir prompts dir so we
	// don't pollute the project's prompts/ folder.
	dir := t.TempDir()
	p := filepath.Join(dir, "fakeprompt.prompt.md")
	if err := os.WriteFile(p, []byte("hello {{TASK}}\n"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	body, err := defaultPromptRenderer{}.Render(dir, "fakeprompt", map[string]string{"TASK": "world"})
	if err != nil {
		t.Fatalf("default renderer error: %v", err)
	}
	if !strings.Contains(body, "world") {
		t.Errorf("default renderer did not substitute TASK; got %q", body)
	}
}

func TestDefaultStateWriter_WritesPipelineState(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("PIPELINE_STATE_FILE", ".tekhton/STATE.json")

	w := defaultStateWriter{}
	err := w.WriteHalt(context.Background(), "tester", "TDD pre-flight API error: rate_limit",
		"--start-at test", "the task", "notes here")
	if err != nil {
		t.Fatalf("WriteHalt: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(dir, ".tekhton", "STATE.json"))
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	s := string(data)
	for _, want := range []string{"tester", "rate_limit", "--start-at test", "the task", "notes here"} {
		if !strings.Contains(s, want) {
			t.Errorf("state file missing %q; body=%s", want, s)
		}
	}
}

func TestResolveProjectPath_Branches(t *testing.T) {
	cases := []struct {
		name, dir, path, want string
	}{
		{"empty path returns empty", "/proj", "", ""},
		{"absolute path returned unchanged", "/proj", "/abs/path", "/abs/path"},
		{"empty dir returns path unchanged", "", "rel/path", "rel/path"},
		{"joins dir + relative", "/proj", "rel/path", "/proj/rel/path"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveProjectPath(tc.dir, tc.path); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestPathExists_EmptyAndDir(t *testing.T) {
	if pathExists("") {
		t.Error("empty path must report false")
	}
	dir := t.TempDir()
	if pathExists(dir) {
		t.Error("directory must report false (regular-file only)")
	}
}

func TestIsNullRun_NilAndZeroTurnsAndPositive(t *testing.T) {
	if !isNullRun(nil) {
		t.Error("nil result must be null run")
	}
	if !isNullRun(&proto.AgentResultV1{ExitCode: 1, TurnsUsed: 0}) {
		t.Error("zero turns + non-zero exit must be null run")
	}
	if isNullRun(&proto.AgentResultV1{ExitCode: 0, TurnsUsed: 10}) {
		t.Error("clean exit with real work must not be null run")
	}
}

func TestWithDefaults_FillsZeroFields(t *testing.T) {
	got := withDefaults(Options{})
	if got.MaxTurns != DefaultMaxTurns ||
		got.Model != DefaultModel ||
		got.PreflightFile != DefaultPreflightFile ||
		got.LogDir != DefaultLogDir {
		t.Errorf("zero options not filled with defaults: %+v", got)
	}
}

// --- File length / surface guards (m38.6-deferral evidence) -------------

func TestPackage_BashFileStillExists(t *testing.T) {
	// Sanity guard from the milestone Watch For block: the bash file
	// MUST stay on disk through m38.5 (M38.6 deletes it). Asserting
	// from here costs nothing and catches premature deletion.
	if _, err := os.Stat("../../../stages/tester_tdd.sh"); err != nil {
		t.Fatalf("stages/tester_tdd.sh must still exist pre-m38.6: %v", err)
	}
}

func TestPackage_FixAndContinuationExist(t *testing.T) {
	// M38.3 lands fix.go and continuation.go. Both must exist at m38.3
	// close. This guard replaces the m38.2 "must not exist" assertion
	// inverted at the m38.3 close.
	for _, f := range []string{
		"../fix.go",
		"../continuation.go",
	} {
		if _, err := os.Stat(f); err != nil {
			t.Errorf("%s must exist at m38.3 close: %v", f, err)
		}
	}
}

func TestPackage_NoExecCommandInTddGo(t *testing.T) {
	// Acceptance-criteria canary: archivePreflight must use io.Copy, not a
	// shell-out. If exec.Command ever appears in tdd.go this test fires.
	data, err := os.ReadFile("tdd.go")
	if err != nil {
		t.Fatalf("read tdd.go: %v", err)
	}
	if strings.Contains(string(data), "exec.Command") {
		t.Error("tdd.go must not use exec.Command — archivePreflight must use io.Copy (no shell-out)")
	}
}
