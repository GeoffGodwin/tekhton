package intake

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeProvider records every RunAgent() call and returns canned results.
type fakeProvider struct {
	calls    []*provider.Request
	report   string // body to write into INTAKE_REPORT.md before "agent" exit
	reportTo string // absolute path to write report into
	runErr   error
}

func (f *fakeProvider) Name() string { return "fake-intake" }

func (f *fakeProvider) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	f.calls = append(f.calls, req)
	if f.reportTo != "" && f.report != "" {
		_ = os.MkdirAll(filepath.Dir(f.reportTo), 0o755)
		_ = os.WriteFile(f.reportTo, []byte(f.report), 0o644)
	}
	if f.runErr != nil {
		return nil, f.runErr
	}
	return &provider.Result{
		Outcome: provider.OutcomeSuccess,
	}, nil
}

func withFakeAgent(t *testing.T) *fakeProvider {
	t.Helper()
	fp := &fakeProvider{}
	prev := SetProvider(fp)
	t.Cleanup(func() { SetProvider(prev) })
	return fp
}

// makeReq builds a minimal StageRequestV1 pointing at projectDir.
func makeReq(projectDir string) *proto.StageRequestV1 {
	home, _ := filepath.Abs(filepath.Join("..", "..", ".."))
	return &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		Task:       "intake-test",
		ResultFile: filepath.Join(projectDir, ".tekhton", "stage.result.json"),
		EnvOverrides: map[string]string{
			"PROJECT_DIR":  projectDir,
			"TEKHTON_HOME": home,
		},
	}
}

// scratchEnv resets sentinel + verdict env vars and snapshots prior values
// so the test cleanup restores them.
func scratchEnv(t *testing.T, keys ...string) {
	t.Helper()
	saved := make(map[string]string, len(keys))
	for _, k := range keys {
		if v, ok := os.LookupEnv(k); ok {
			saved[k] = v
		}
		_ = os.Unsetenv(k)
	}
	t.Cleanup(func() {
		for _, k := range keys {
			if v, ok := saved[k]; ok {
				_ = os.Setenv(k, v)
			} else {
				_ = os.Unsetenv(k)
			}
		}
	})
}

func setupProject(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".tekhton"), 0o755); err != nil {
		t.Fatalf("mkdir tekhton dir: %v", err)
	}
	return dir
}

// TestRunStage_DisabledSkips covers the INTAKE_AGENT_ENABLED=false branch.
func TestRunStage_DisabledSkips(t *testing.T) {
	dir := setupProject(t)
	withFakeAgent(t)
	scratchEnv(t, "INTAKE_AGENT_ENABLED", "INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")
	_ = os.Setenv("INTAKE_AGENT_ENABLED", "false")

	res, err := RunStage(context.Background(), makeReq(dir))
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "disabled" {
		t.Errorf("verdict/reason = %s/%s, want skip/disabled", res.Verdict, res.ExitReason)
	}
}

// TestRunStage_HumanModeSkipDoesNotEmitPass covers the AC asserting
// _INTAKE_PASS_EMIT is NOT set on the skip paths.
func TestRunStage_HumanModeSkipDoesNotEmitPass(t *testing.T) {
	dir := setupProject(t)
	withFakeAgent(t)
	scratchEnv(t, "HUMAN_MODE", "INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")
	_ = os.Setenv("HUMAN_MODE", "true")

	res, err := RunStage(context.Background(), makeReq(dir))
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "human_mode" {
		t.Errorf("verdict/reason = %s/%s, want skip/human_mode", res.Verdict, res.ExitReason)
	}
	if got := os.Getenv("INTAKE_VERDICT"); got != "PASS" {
		t.Errorf("INTAKE_VERDICT = %q, want PASS", got)
	}
	if got := os.Getenv("INTAKE_CONFIDENCE"); got != "100" {
		t.Errorf("INTAKE_CONFIDENCE = %q, want 100", got)
	}
	if got, ok := os.LookupEnv("_INTAKE_PASS_EMIT"); ok {
		t.Errorf("_INTAKE_PASS_EMIT must NOT be set on skip path, got %q", got)
	}
}

// TestRunStage_SentinelCleanup verifies the SOLE-owner contract for
// .final_check_result and .commit_decision: pre-create both, run intake,
// assert both gone.
func TestRunStage_SentinelCleanup(t *testing.T) {
	dir := setupProject(t)
	withFakeAgent(t)
	scratchEnv(t, "INTAKE_AGENT_ENABLED", "_INTAKE_PASS_EMIT", "INTAKE_VERDICT", "INTAKE_CONFIDENCE")
	_ = os.Setenv("INTAKE_AGENT_ENABLED", "false")

	for _, name := range []string{".final_check_result", ".commit_decision"} {
		p := filepath.Join(dir, ".tekhton", name)
		if err := os.WriteFile(p, []byte("stale"), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	if _, err := RunStage(context.Background(), makeReq(dir)); err != nil {
		t.Fatalf("RunStage: %v", err)
	}

	for _, name := range []string{".final_check_result", ".commit_decision"} {
		p := filepath.Join(dir, ".tekhton", name)
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s should have been cleaned, stat err=%v", name, err)
		}
	}
}

// TestRunStage_CachedPass loads a PASS report from cache and asserts no
// agent invocation, _INTAKE_PASS_EMIT NOT set (cache path is its own
// exit reason — neither skip nor full dispatch).
func TestRunStage_CachedPass(t *testing.T) {
	dir := setupProject(t)
	fa := withFakeAgent(t)
	scratchEnv(t,
		"INTAKE_CACHED", "INTAKE_AGENT_ENABLED", "INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")
	_ = os.Setenv("INTAKE_CACHED", "true")

	report := "# Intake Report\n\n## Verdict\nPASS\n\n## Confidence\n80\n"
	reportFile := filepath.Join(dir, ".tekhton", "INTAKE_REPORT.md")
	if err := os.WriteFile(reportFile, []byte(report), 0o644); err != nil {
		t.Fatalf("write report: %v", err)
	}

	res, err := RunStage(context.Background(), makeReq(dir))
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if len(fa.calls) != 0 {
		t.Errorf("cached run should not call provider; got %d calls", len(fa.calls))
	}
	if res.Verdict != proto.VerdictPass || res.ExitReason != "cached_pass" {
		t.Errorf("verdict/reason = %s/%s, want pass/cached_pass", res.Verdict, res.ExitReason)
	}
	if got := os.Getenv("INTAKE_VERDICT"); got != "PASS" {
		t.Errorf("INTAKE_VERDICT = %q, want PASS", got)
	}
	if got := os.Getenv("INTAKE_CONFIDENCE"); got != "80" {
		t.Errorf("INTAKE_CONFIDENCE = %q, want 80", got)
	}
	// Cached pass uses cached_pass branch which sets exports but does NOT
	// emit the PASS flag — only the live dispatch path does.
	if _, ok := os.LookupEnv("_INTAKE_PASS_EMIT"); ok {
		t.Errorf("_INTAKE_PASS_EMIT must NOT be set on cached-pass path")
	}
}

// TestRunStage_LiveDispatchPassSetsEmitFlag covers the canonical PASS path:
// agent runs, writes PASS report, dispatcher sets _INTAKE_PASS_EMIT=true.
func TestRunStage_LiveDispatchPassSetsEmitFlag(t *testing.T) {
	dir := setupProject(t)
	scratchEnv(t,
		"INTAKE_AGENT_ENABLED", "MILESTONE_MODE", "TASK",
		"INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")
	// Use the TASK fallback path for content (MILESTONE_MODE off → content = task).
	_ = os.Setenv("TASK", "verify the build works end-to-end")

	reportFile := filepath.Join(dir, ".tekhton", "INTAKE_REPORT.md")

	fa := withFakeAgent(t)
	fa.report = "# Intake Report\n\n## Verdict\nPASS\n\n## Confidence\n90\n"
	fa.reportTo = reportFile

	req := makeReq(dir)
	// Override TEKHTON_HOME → use real prompts dir.
	req.EnvOverrides["TEKHTON_HOME"] = absRepoRoot(t)
	req.EnvOverrides["TEKHTON_SESSION_DIR"] = filepath.Join(dir, ".tekhton", "session")

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict = %s, want pass", res.Verdict)
	}
	if got := os.Getenv("INTAKE_VERDICT"); got != "PASS" {
		t.Errorf("INTAKE_VERDICT = %q, want PASS", got)
	}
	if got := os.Getenv("_INTAKE_PASS_EMIT"); got != "true" {
		t.Errorf("_INTAKE_PASS_EMIT = %q, want true (PASS dispatch must set the flag)", got)
	}
	if len(fa.calls) != 1 {
		t.Errorf("provider should be called once, got %d", len(fa.calls))
	}
}

// TestRunStage_ContentHashSkipsRerun verifies the content-hash short-circuit.
func TestRunStage_ContentHashSkipsRerun(t *testing.T) {
	dir := setupProject(t)
	sessionDir := filepath.Join(dir, ".tekhton", "session")
	scratchEnv(t,
		"INTAKE_AGENT_ENABLED", "MILESTONE_MODE", "TASK",
		"INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")
	_ = os.Setenv("TASK", "the same task body")

	// Pre-write the hash file so the stage sees content as unchanged.
	if err := os.MkdirAll(sessionDir, 0o755); err != nil {
		t.Fatalf("mkdir session: %v", err)
	}

	// Manually compute the hash the way intake.Helpers.ContentHash does.
	h := newHelpers(loadConfig(makeReqWithSession(dir, sessionDir)))
	hash := h.ContentHash("the same task body")
	if err := os.WriteFile(filepath.Join(sessionDir, "intake_content_hash"),
		[]byte(hash+"\n"), 0o644); err != nil {
		t.Fatalf("seed hash: %v", err)
	}

	fa := withFakeAgent(t)
	res, err := RunStage(context.Background(), makeReqWithSession(dir, sessionDir))
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if len(fa.calls) != 0 {
		t.Errorf("content-hash skip should not call provider; got %d", len(fa.calls))
	}
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "unchanged" {
		t.Errorf("verdict/reason = %s/%s, want skip/unchanged", res.Verdict, res.ExitReason)
	}
}

func makeReqWithSession(projectDir, sessionDir string) *proto.StageRequestV1 {
	req := makeReq(projectDir)
	req.EnvOverrides["TEKHTON_SESSION_DIR"] = sessionDir
	return req
}

// TestRunStage_NoContent verifies the empty-task short-circuit.
func TestRunStage_NoContent(t *testing.T) {
	dir := setupProject(t)
	scratchEnv(t,
		"INTAKE_AGENT_ENABLED", "MILESTONE_MODE", "TASK",
		"INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")
	_ = os.Unsetenv("TASK")

	fa := withFakeAgent(t)
	req := makeReq(dir)
	req.Task = "" // make sure task body is empty
	delete(req.EnvOverrides, "TASK")

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "no_content" {
		t.Errorf("verdict/reason = %s/%s, want skip/no_content", res.Verdict, res.ExitReason)
	}
	if len(fa.calls) != 0 {
		t.Errorf("no_content should not call provider; got %d", len(fa.calls))
	}
}

func absRepoRoot(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("abs repo root: %v", err)
	}
	return p
}

// TestVerdictExitReasonMapping pins the verdict→exit_reason map.
func TestVerdictExitReasonMapping(t *testing.T) {
	cases := []struct {
		verdict string
		want    string
	}{
		{"PASS", "pass"},
		{"TWEAKED", "tweaked"},
		{"SPLIT_RECOMMENDED", "split_recommended"},
		{"NEEDS_CLARITY", "needs_clarity"},
		{"UNKNOWN", "complete"},
	}
	for _, c := range cases {
		if got := verdictExitReason(c.verdict); got != c.want {
			t.Errorf("verdictExitReason(%q) = %q, want %q", c.verdict, got, c.want)
		}
	}
}

// TestSetVerdictEnv covers both branches of the env exporter.
func TestSetVerdictEnv(t *testing.T) {
	scratchEnv(t, "INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")

	setVerdictEnv("PASS", "90", true)
	if got := os.Getenv("_INTAKE_PASS_EMIT"); got != "true" {
		t.Errorf("emit=true should set _INTAKE_PASS_EMIT=true, got %q", got)
	}

	setVerdictEnv("PASS", "90", false)
	if _, ok := os.LookupEnv("_INTAKE_PASS_EMIT"); ok {
		t.Error("emit=false should unset _INTAKE_PASS_EMIT")
	}
	if got := os.Getenv("INTAKE_VERDICT"); got != "PASS" {
		t.Errorf("INTAKE_VERDICT = %q, want PASS", got)
	}
}

// TestRunStage_HumanModeReturnsSkipVerdict asserts the human-mode path
// returns verdict=skip (matches Skip not Pass) so downstream selectors
// can short-circuit cleanly.
func TestRunStage_HumanModeReturnsSkipVerdict(t *testing.T) {
	dir := setupProject(t)
	withFakeAgent(t)
	scratchEnv(t, "HUMAN_MODE", "INTAKE_VERDICT", "INTAKE_CONFIDENCE", "_INTAKE_PASS_EMIT")
	_ = os.Setenv("HUMAN_MODE", "true")

	res, err := RunStage(context.Background(), makeReq(dir))
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if !strings.HasPrefix(string(res.Verdict), "skip") {
		t.Errorf("HUMAN_MODE skip verdict = %q, want skip", res.Verdict)
	}
}
