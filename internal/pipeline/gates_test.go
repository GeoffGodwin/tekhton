package pipeline

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestBuildGateNilSafe(t *testing.T) {
	var g *BuildGate
	v, err := g.Run(context.Background(), 0)
	if err != nil {
		t.Fatalf("nil gate: unexpected error %v", err)
	}
	if v != proto.VerdictPass {
		t.Fatalf("nil gate: verdict %q want pass", v)
	}
}

func TestBuildGateEmptyCmds(t *testing.T) {
	g := &BuildGate{Runner: &fakeGateRunner{}}
	v, err := g.Run(context.Background(), 0)
	if err != nil {
		t.Fatalf("empty cmds: %v", err)
	}
	if v != proto.VerdictPass {
		t.Fatalf("empty cmds: verdict %q want pass", v)
	}
}

func TestBuildGateAnalyzeFails(t *testing.T) {
	g := &BuildGate{
		AnalyzeCmd: "false",
		Runner:     &fakeGateRunner{exits: []int{1}},
	}
	v, err := g.Run(context.Background(), 0)
	if err != nil {
		t.Fatalf("analyze fail: %v", err)
	}
	if v != proto.VerdictFail {
		t.Fatalf("analyze fail: verdict %q want fail", v)
	}
}

func TestBuildGateCompileFails(t *testing.T) {
	g := &BuildGate{
		AnalyzeCmd: "true",
		CompileCmd: "false",
		Runner:     &fakeGateRunner{exits: []int{0, 1}},
	}
	v, err := g.Run(context.Background(), 0)
	if err != nil {
		t.Fatalf("compile fail: %v", err)
	}
	if v != proto.VerdictFail {
		t.Fatalf("compile fail: verdict %q want fail", v)
	}
}

func TestBuildGateBothPass(t *testing.T) {
	g := &BuildGate{
		AnalyzeCmd: "true",
		CompileCmd: "true",
		Runner:     &fakeGateRunner{exits: []int{0, 0}},
	}
	v, err := g.Run(context.Background(), 0)
	if err != nil {
		t.Fatalf("both pass: %v", err)
	}
	if v != proto.VerdictPass {
		t.Fatalf("both pass: verdict %q want pass", v)
	}
}

type errRunner struct{ err error }

func (e *errRunner) Run(_ context.Context, _ string, _ time.Duration) ([]byte, int, error) {
	return nil, -1, e.err
}

func TestBuildGateRunnerError(t *testing.T) {
	g := &BuildGate{
		AnalyzeCmd: "x",
		Runner:     &errRunner{err: errors.New("boom")},
	}
	v, err := g.Run(context.Background(), 0)
	if err == nil {
		t.Fatalf("expected error from runner failure")
	}
	if v != proto.VerdictFail {
		t.Fatalf("verdict: got %q want fail", v)
	}
}

func TestCompletionGateNilSafe(t *testing.T) {
	var g *CompletionGate
	v, err := g.Run(context.Background())
	if err != nil {
		t.Fatalf("nil gate: %v", err)
	}
	if v != proto.VerdictPass {
		t.Fatalf("nil gate: verdict %q want pass", v)
	}
}

func TestCompletionGatePass(t *testing.T) {
	g := &CompletionGate{TestCmd: "true", Runner: &fakeGateRunner{exits: []int{0}}}
	v, err := g.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if v != proto.VerdictPass {
		t.Fatalf("verdict: %q want pass", v)
	}
}

func TestCompletionGateFail(t *testing.T) {
	g := &CompletionGate{TestCmd: "false", Runner: &fakeGateRunner{exits: []int{1}}}
	v, err := g.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if v != proto.VerdictFail {
		t.Fatalf("verdict: %q want fail", v)
	}
}

func TestCompletionGatePassOnPreexisting(t *testing.T) {
	g := &CompletionGate{
		TestCmd:           "false",
		Runner:            &fakeGateRunner{exits: []int{1}},
		PassOnPreexisting: true,
		IsPreexistingFailure: func([]byte, int) bool {
			return true
		},
	}
	v, err := g.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if v != proto.VerdictPass {
		t.Fatalf("verdict: %q want pass (baseline-pass)", v)
	}
}

func TestCompletionGatePreexistingButNotAll(t *testing.T) {
	g := &CompletionGate{
		TestCmd:           "false",
		Runner:            &fakeGateRunner{exits: []int{1}},
		PassOnPreexisting: true,
		IsPreexistingFailure: func([]byte, int) bool {
			return false
		},
	}
	v, _ := g.Run(context.Background())
	if v != proto.VerdictFail {
		t.Fatalf("verdict: %q want fail (new failure exists)", v)
	}
}

func TestCompletionGateEmptyCmd(t *testing.T) {
	g := &CompletionGate{}
	v, err := g.Run(context.Background())
	if err != nil {
		t.Fatalf("empty cmd: %v", err)
	}
	if v != proto.VerdictPass {
		t.Fatalf("empty cmd: verdict %q want pass", v)
	}
}

func TestExecRunnerEmptyCmd(t *testing.T) {
	out, code, err := ExecRunner{}.Run(context.Background(), "", 0)
	if err != nil {
		t.Fatalf("empty cmd: %v", err)
	}
	if len(out) != 0 || code != 0 {
		t.Fatalf("empty cmd: out=%q code=%d", string(out), code)
	}
}

func TestExecRunnerSuccess(t *testing.T) {
	out, code, err := ExecRunner{}.Run(context.Background(), "echo hi", 0)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if code != 0 {
		t.Fatalf("code: %d want 0", code)
	}
	if len(out) == 0 {
		t.Fatalf("output empty")
	}
}

func TestExecRunnerTimeout(t *testing.T) {
	_, _, err := ExecRunner{}.Run(context.Background(), "sleep 5", 50*time.Millisecond)
	if err == nil {
		t.Fatalf("expected timeout error")
	}
	if !errors.Is(err, ErrGateTimeout) {
		t.Fatalf("error not ErrGateTimeout: %v", err)
	}
}

func TestExecRunnerFail(t *testing.T) {
	_, code, err := ExecRunner{}.Run(context.Background(), "exit 7", 0)
	if err != nil {
		t.Fatalf("non-zero exit should not be an error: %v", err)
	}
	if code != 7 {
		t.Fatalf("code: %d want 7", code)
	}
}
