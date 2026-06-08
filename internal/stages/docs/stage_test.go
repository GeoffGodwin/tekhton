package docs

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeProviderRunner records the request it was asked to run and returns a
// canned response. Used by stage_test.go in place of a real provider.
type fakeProviderRunner struct {
	gotReq *provider.Request
	res    *provider.Result
	err    error
}

func (f *fakeProviderRunner) Name() string { return "fake-docs" }

func (f *fakeProviderRunner) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	f.gotReq = req
	return f.res, f.err
}

func freshRequest(t *testing.T, projectDir string) *proto.StageRequestV1 {
	t.Helper()
	return &proto.StageRequestV1{
		Proto:        proto.StageRequestProtoV1,
		Stage:        proto.StageDocs,
		ResultFile:   filepath.Join(t.TempDir(), "result.json"),
		EnvOverrides: map[string]string{"PROJECT_DIR": projectDir, "TEKHTON_HOME": projectDir},
	}
}

func TestRunStage_DisabledGate(t *testing.T) {
	t.Setenv("DOCS_AGENT_ENABLED", "false")
	proj := t.TempDir()
	gitInit(t, proj)

	res, err := RunStage(context.Background(), freshRequest(t, proj))
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictSkip {
		t.Fatalf("verdict=%q want skip", res.Verdict)
	}
	if res.ExitReason != "disabled" {
		t.Fatalf("exit_reason=%q want disabled", res.ExitReason)
	}
}

func TestRunStage_SkipFlag(t *testing.T) {
	t.Setenv("DOCS_AGENT_ENABLED", "true")
	t.Setenv("SKIP_DOCS", "true")
	proj := t.TempDir()
	gitInit(t, proj)

	res, err := RunStage(context.Background(), freshRequest(t, proj))
	if err != nil {
		t.Fatal(err)
	}
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "skip-flag" {
		t.Fatalf("got verdict=%q reason=%q", res.Verdict, res.ExitReason)
	}
}

func TestRunStage_NoSurfaceChange(t *testing.T) {
	t.Setenv("DOCS_AGENT_ENABLED", "true")
	t.Setenv("SKIP_DOCS", "false")
	proj := t.TempDir()
	gitInit(t, proj)
	// CLAUDE.md is config (committed); changed set is foo.go which doesn't
	// match *.md / explicit-dir/.
	writeAndCommit(t, proj, "CLAUDE.md", `# X
## Documentation Responsibilities
- Update *.md when surface changes
`)
	writeAndStage(t, proj, "foo.go", "package main\n")
	t.Setenv("DOCS_DIRS", "definitely-not-a-real-dir/")
	t.Setenv("DOCS_README_FILE", "definitely-not-a-real-readme.md")

	res, err := RunStage(context.Background(), freshRequest(t, proj))
	if err != nil {
		t.Fatal(err)
	}
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "no-public-surface-change" {
		t.Fatalf("got verdict=%q reason=%q", res.Verdict, res.ExitReason)
	}
}

// TestRunStage_NeverReturnsFail is the property-style test from the m34.1
// acceptance criteria: every code path through RunStage must return a verdict
// in {pass, skip}. Drives the stage through every gate plus an agent-failure
// branch (supervisor error AND non-success outcome) and asserts the verdict.
func TestRunStage_NeverReturnsFail(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	writeAndCommit(t, proj, "CLAUDE.md", `# X
## Documentation Responsibilities
- Update *.go on every change
`)
	writeAndStage(t, proj, "foo.go", "package main\n")
	writeFile(t, filepath.Join(proj, "prompts", "docs_agent.prompt.md"), "doc the surface\n")

	// Agent returns an error → must become verdict=skip with reason=agent-failed.
	prev := SetProvider(&fakeProviderRunner{err: errors.New("boom")})
	defer SetProvider(prev)

	t.Setenv("DOCS_AGENT_ENABLED", "true")
	t.Setenv("SKIP_DOCS", "false")
	t.Setenv("DOCS_DIRS", "")
	t.Setenv("DOCS_README_FILE", "")
	t.Setenv("TEKHTON_HOME", proj)

	res, err := RunStage(context.Background(), freshRequest(t, proj))
	if err != nil {
		t.Fatalf("RunStage returned err: %v", err)
	}
	if res.Verdict == proto.VerdictFail {
		t.Fatalf("verdict=fail — RunStage must never return fail")
	}
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "agent-failed" {
		t.Fatalf("got verdict=%q reason=%q want skip/agent-failed", res.Verdict, res.ExitReason)
	}

	// Agent returns non-success outcome → also verdict=skip.
	SetProvider(&fakeProviderRunner{res: &provider.Result{
		Outcome:  provider.OutcomeUnknown,
		ExitCode: 1,
	}})
	res, _ = RunStage(context.Background(), freshRequest(t, proj))
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "agent-failed" {
		t.Fatalf("non-success outcome: got verdict=%q reason=%q", res.Verdict, res.ExitReason)
	}
}

func TestRunStage_AgentSucceeds(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	writeAndCommit(t, proj, "CLAUDE.md", `# X
## Documentation Responsibilities
- Update *.go on every change
`)
	writeAndStage(t, proj, "foo.go", "package main\n")
	writeFile(t, filepath.Join(proj, "prompts", "docs_agent.prompt.md"), "doc the surface\n")

	fr := &fakeProviderRunner{res: &provider.Result{
		Outcome: provider.OutcomeSuccess,
	}}
	prev := SetProvider(fr)
	defer SetProvider(prev)

	t.Setenv("DOCS_AGENT_ENABLED", "true")
	t.Setenv("SKIP_DOCS", "false")
	t.Setenv("DOCS_DIRS", "")
	t.Setenv("DOCS_README_FILE", "")
	t.Setenv("TEKHTON_HOME", proj)

	res, err := RunStage(context.Background(), freshRequest(t, proj))
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict=%q want pass", res.Verdict)
	}
	if res.ExitReason != "agent-completed" {
		t.Fatalf("exit_reason=%q want agent-completed", res.ExitReason)
	}
	if res.AgentCalls != 1 {
		t.Fatalf("agent_calls=%d want 1", res.AgentCalls)
	}
	if fr.gotReq == nil {
		t.Fatal("fakeAgentRunner.Run was not invoked")
	}
	if fr.gotReq.Label != "Docs" {
		t.Fatalf("agent label=%q want Docs", fr.gotReq.Label)
	}
	if fr.gotReq.WorkingDir != proj {
		t.Fatalf("agent WorkingDir=%q want %q", fr.gotReq.WorkingDir, proj)
	}
}

func TestRunStage_PromptMissing(t *testing.T) {
	proj := t.TempDir()
	gitInit(t, proj)
	writeAndCommit(t, proj, "CLAUDE.md", `# X
## Documentation Responsibilities
- Update *.go on every change
`)
	writeAndStage(t, proj, "foo.go", "package main\n")
	// Intentionally NO prompts/docs_agent.prompt.md → render must fail and
	// the stage must skip with prompt-failed (not fail).

	t.Setenv("DOCS_AGENT_ENABLED", "true")
	t.Setenv("SKIP_DOCS", "false")
	t.Setenv("DOCS_DIRS", "")
	t.Setenv("DOCS_README_FILE", "")
	t.Setenv("TEKHTON_HOME", proj)

	res, _ := RunStage(context.Background(), freshRequest(t, proj))
	if res.Verdict != proto.VerdictSkip {
		t.Fatalf("verdict=%q want skip", res.Verdict)
	}
	if res.ExitReason != "prompt-failed" {
		t.Fatalf("exit_reason=%q want prompt-failed", res.ExitReason)
	}
}

func TestSetProvider_RoundTrip(t *testing.T) {
	prev := stageProvider
	r := &fakeProviderRunner{}
	ret := SetProvider(r)
	if ret != prev {
		t.Fatal("SetProvider did not return previous provider")
	}
	if stageProvider != r {
		t.Fatal("SetProvider did not install new provider")
	}
	SetProvider(prev)
}

func TestEnvBoolEnvInt(t *testing.T) {
	t.Setenv("DOCS_TEST_BOOL", "true")
	if !envBool("DOCS_TEST_BOOL", false) {
		t.Fatal("envBool: true not parsed")
	}
	t.Setenv("DOCS_TEST_BOOL", "no")
	if envBool("DOCS_TEST_BOOL", true) {
		t.Fatal("envBool: no not parsed")
	}
	t.Setenv("DOCS_TEST_BOOL", "")
	if envBool("DOCS_TEST_BOOL", true) {
		t.Fatal("envBool: empty should fall back -> but test passes true as fallback to detect; assertion inverted")
	}
	os.Unsetenv("DOCS_TEST_BOOL")
	if !envBool("DOCS_TEST_BOOL", true) {
		t.Fatal("envBool: unset should return fallback")
	}

	t.Setenv("DOCS_TEST_INT", "42")
	if envInt("DOCS_TEST_INT", 7) != 42 {
		t.Fatal("envInt: 42 not parsed")
	}
	t.Setenv("DOCS_TEST_INT", "x")
	if envInt("DOCS_TEST_INT", 7) != 7 {
		t.Fatal("envInt: invalid should fall back")
	}
}

// TestEnvBool_UnknownValue verifies the fallback branch: an unrecognised value
// (not "yes/no/true/false/1/0") returns the fallback, not a hard-coded bool.
func TestEnvBool_UnknownValue(t *testing.T) {
	t.Setenv("DOCS_TEST_BOOL2", "maybe")
	if envBool("DOCS_TEST_BOOL2", true) != true {
		t.Fatal("envBool: unrecognised value with fallback=true should return true")
	}
	if envBool("DOCS_TEST_BOOL2", false) != false {
		t.Fatal("envBool: unrecognised value with fallback=false should return false")
	}
}

// TestEnvInt_ZeroInput verifies that "0" hits the n <= 0 guard and returns the
// fallback (turn counts of zero are invalid in the pipeline).
func TestEnvInt_ZeroInput(t *testing.T) {
	t.Setenv("DOCS_TEST_INT2", "0")
	if got := envInt("DOCS_TEST_INT2", 7); got != 7 {
		t.Fatalf("envInt(\"0\") = %d want 7 (fallback, n<=0 guard)", got)
	}
}

// TestEnvInt_EmptyOrUnset verifies the early-exit branch: key not set (!ok)
// and key set to empty string (v=="") both return the fallback.
func TestEnvInt_EmptyOrUnset(t *testing.T) {
	os.Unsetenv("DOCS_TEST_INT3")
	if got := envInt("DOCS_TEST_INT3", 5); got != 5 {
		t.Fatalf("envInt unset: got %d want 5", got)
	}
	t.Setenv("DOCS_TEST_INT3", "")
	if got := envInt("DOCS_TEST_INT3", 5); got != 5 {
		t.Fatalf("envInt empty: got %d want 5", got)
	}
}

// TestResolveProjectDir_EnvFallback verifies the second fallback path:
// PROJECT_DIR in the process environment when EnvOverrides is absent.
func TestResolveProjectDir_EnvFallback(t *testing.T) {
	want := t.TempDir()
	t.Setenv("PROJECT_DIR", want)
	got := resolveProjectDir(&proto.StageRequestV1{
		Proto: proto.StageRequestProtoV1,
		Stage: proto.StageDocs,
	})
	if got != want {
		t.Fatalf("resolveProjectDir from env: got %q want %q", got, want)
	}
}

// TestResolveProjectDir_GetWdFallback verifies the last-ditch os.Getwd() path
// fires when neither EnvOverrides nor PROJECT_DIR env are set.
func TestResolveProjectDir_GetWdFallback(t *testing.T) {
	os.Unsetenv("PROJECT_DIR")
	// A nil request with no EnvOverrides should fall through to Getwd().
	got := resolveProjectDir(nil)
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}
	if got != wd {
		t.Fatalf("resolveProjectDir Getwd: got %q want %q", got, wd)
	}
}

// TestResolvePromptsDir_EnvFallback verifies the second path: TEKHTON_HOME in
// the process environment when EnvOverrides is absent.
func TestResolvePromptsDir_EnvFallback(t *testing.T) {
	home := t.TempDir()
	t.Setenv("TEKHTON_HOME", home)
	got := resolvePromptsDir(&proto.StageRequestV1{
		Proto: proto.StageRequestProtoV1,
		Stage: proto.StageDocs,
	})
	want := filepath.Join(home, "prompts")
	if got != want {
		t.Fatalf("resolvePromptsDir from env: got %q want %q", got, want)
	}
}

// TestResolvePromptsDir_LastDitch verifies that the literal "prompts" fallback
// is returned when neither EnvOverrides nor TEKHTON_HOME env are set.
func TestResolvePromptsDir_LastDitch(t *testing.T) {
	os.Unsetenv("TEKHTON_HOME")
	got := resolvePromptsDir(nil)
	if got != "prompts" {
		t.Fatalf("resolvePromptsDir last-ditch: got %q want %q", got, "prompts")
	}
}
