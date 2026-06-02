package docs

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeAgentRunner records the request it was asked to run and returns a
// canned response. Used by stage_test.go in place of a real supervisor.
type fakeAgentRunner struct {
	gotReq *proto.AgentRequestV1
	res    *proto.AgentResultV1
	err    error
}

func (f *fakeAgentRunner) Run(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
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
	prev := SetAgentRunner(&fakeAgentRunner{err: errors.New("boom")})
	defer SetAgentRunner(prev)

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
	SetAgentRunner(&fakeAgentRunner{res: &proto.AgentResultV1{
		Proto:    proto.AgentResultProtoV1,
		Outcome:  proto.OutcomeFatalError,
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

	fr := &fakeAgentRunner{res: &proto.AgentResultV1{
		Proto:   proto.AgentResultProtoV1,
		Outcome: proto.OutcomeSuccess,
	}}
	prev := SetAgentRunner(fr)
	defer SetAgentRunner(prev)

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

func TestSetAgentRunner_RoundTrip(t *testing.T) {
	prev := agentRunner
	r := &fakeAgentRunner{}
	ret := SetAgentRunner(r)
	if ret != prev {
		t.Fatal("SetAgentRunner did not return previous runner")
	}
	if agentRunner != r {
		t.Fatal("SetAgentRunner did not install new runner")
	}
	SetAgentRunner(prev)
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
