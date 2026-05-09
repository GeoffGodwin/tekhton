package pipeline

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeAdapter scripts stage outcomes for tests. Callers set Sequence to a
// list of (stage, verdict, next_action) triples; Run returns them in order.
type fakeAdapter struct {
	sequence []fakeOutcome
	calls    []*proto.StageRequestV1
	errAfter int
	err      error
}

type fakeOutcome struct {
	stage      string
	verdict    string
	nextAction string
	exitReason string
	agentCalls int
}

func (f *fakeAdapter) Run(_ context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	f.calls = append(f.calls, req)
	if f.errAfter > 0 && len(f.calls) > f.errAfter {
		return nil, f.err
	}
	if len(f.calls) > len(f.sequence) {
		return nil, errors.New("fakeAdapter: sequence exhausted")
	}
	o := f.sequence[len(f.calls)-1]
	if o.stage != req.Stage {
		return nil, &mismatchErr{expected: o.stage, got: req.Stage}
	}
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       o.stage,
		Verdict:     o.verdict,
		ExitReason:  o.exitReason,
		AgentCalls:  o.agentCalls,
		NextAction:  o.nextAction,
		DurationSec: 1,
	}, nil
}

type mismatchErr struct{ expected, got string }

func (m *mismatchErr) Error() string {
	return "expected " + m.expected + " got " + m.got
}

// fakeGateRunner returns a fixed exit code per call. Used to drive the build
// gate without spawning subprocesses.
type fakeGateRunner struct {
	exits []int
	calls int
}

func (f *fakeGateRunner) Run(_ context.Context, _ string, _ time.Duration) ([]byte, int, error) {
	if f.calls >= len(f.exits) {
		return nil, 0, nil
	}
	exit := f.exits[f.calls]
	f.calls++
	return nil, exit, nil
}

func newReq(order ...string) *proto.PipelineAttemptRequestV1 {
	return &proto.PipelineAttemptRequestV1{
		Proto:       proto.PipelineAttemptRequestProtoV1,
		Task:        "x",
		Order:       order,
		ReviewCycle: 1,
		ProjectDir:  "/tmp",
	}
}

func TestRunnerHappyPath(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageIntake, verdict: proto.VerdictPass, agentCalls: 1},
			{stage: proto.StageCoder, verdict: proto.VerdictPass, agentCalls: 2},
			{stage: proto.StageReview, verdict: proto.VerdictPass, agentCalls: 1},
			{stage: proto.StageTester, verdict: proto.VerdictPass, agentCalls: 1},
		},
	}
	r, err := New(adapter, Options{ResultDir: t.TempDir()})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	res, err := r.RunAttempt(context.Background(), newReq(
		proto.StageIntake, proto.StageCoder, proto.StageReview, proto.StageTester,
	))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSuccess {
		t.Fatalf("outcome: got %q want success", res.Outcome)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict: got %q want pass", res.Verdict)
	}
	if len(res.Stages) != 4 {
		t.Fatalf("stages count: got %d want 4", len(res.Stages))
	}
	if res.AgentCalls != 5 {
		t.Fatalf("agent_calls: got %d want 5", res.AgentCalls)
	}
}

func TestRunnerSecurityBlock(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageIntake, verdict: proto.VerdictPass},
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
			{stage: proto.StageSecurity, verdict: proto.VerdictBlock, exitReason: "HIGH severity finding"},
		},
	}
	r, _ := New(adapter, Options{ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(
		proto.StageIntake, proto.StageCoder, proto.StageSecurity, proto.StageReview,
	))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictBlock {
		t.Fatalf("verdict: got %q want block", res.Verdict)
	}
	if res.BlockingStage != proto.StageSecurity {
		t.Fatalf("blocking_stage: got %q want security", res.BlockingStage)
	}
	if len(res.Stages) != 3 {
		t.Fatalf("stages: got %d want 3 (review must not run)", len(res.Stages))
	}
}

func TestRunnerReviewRework(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
			{stage: proto.StageReview, verdict: proto.VerdictRework, nextAction: "rework"},
		},
	}
	r, _ := New(adapter, Options{ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(
		proto.StageCoder, proto.StageReview, proto.StageTester,
	))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictRework {
		t.Fatalf("verdict: got %q want rework", res.Verdict)
	}
	if res.Outcome != proto.AttemptOutcomeFailureRetry {
		t.Fatalf("outcome: got %q want failure_retry", res.Outcome)
	}
	if res.BlockingStage != proto.StageReview {
		t.Fatalf("blocking_stage: got %q want review", res.BlockingStage)
	}
}

func TestRunnerBuildGatePassFirstTry(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
			{stage: proto.StageReview, verdict: proto.VerdictPass},
		},
	}
	gate := &BuildGate{
		AnalyzeCmd: "echo ok",
		Runner:     &fakeGateRunner{exits: []int{0}},
	}
	r, _ := New(adapter, Options{Gate: gate, ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(proto.StageCoder, proto.StageReview))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict: got %q want pass", res.Verdict)
	}
	// Coder ran once because gate passed.
	coderCount := 0
	for _, s := range res.Stages {
		if s.Stage == proto.StageCoder {
			coderCount++
		}
	}
	if coderCount != 1 {
		t.Fatalf("coder ran %d times, want 1", coderCount)
	}
}

func TestRunnerBuildGateRetryThenPass(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
			{stage: proto.StageReview, verdict: proto.VerdictPass},
		},
	}
	gate := &BuildGate{
		AnalyzeCmd: "echo go",
		Runner:     &fakeGateRunner{exits: []int{1, 0}}, // first attempt fails, second passes
	}
	req := newReq(proto.StageCoder, proto.StageReview)
	req.MaxBuildRetries = 1
	r, _ := New(adapter, Options{Gate: gate, ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), req)
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict: got %q want pass; res=%+v", res.Verdict, res)
	}
	coderCount := 0
	for _, s := range res.Stages {
		if s.Stage == proto.StageCoder {
			coderCount++
		}
	}
	if coderCount != 2 {
		t.Fatalf("coder ran %d times, want 2", coderCount)
	}
}

func TestRunnerBuildGateExhausted(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
		},
	}
	gate := &BuildGate{
		AnalyzeCmd: "echo go",
		Runner:     &fakeGateRunner{exits: []int{1, 1}},
	}
	req := newReq(proto.StageCoder, proto.StageReview)
	req.MaxBuildRetries = 1
	r, _ := New(adapter, Options{Gate: gate, ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), req)
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("verdict: got %q want fail (gate exhausted)", res.Verdict)
	}
	if res.BlockingStage != proto.StageCoder {
		t.Fatalf("blocking_stage: got %q want coder", res.BlockingStage)
	}
}

func TestRunnerCompletionGatePass(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageTester, verdict: proto.VerdictPass},
		},
	}
	cg := &CompletionGate{
		TestCmd: "true",
		Runner:  &fakeGateRunner{exits: []int{0}},
	}
	r, _ := New(adapter, Options{CompletionGate: cg, ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(proto.StageTester))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict: got %q want pass", res.Verdict)
	}
}

func TestRunnerCompletionGateFail(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageTester, verdict: proto.VerdictPass},
		},
	}
	cg := &CompletionGate{
		TestCmd: "false",
		Runner:  &fakeGateRunner{exits: []int{1}},
	}
	r, _ := New(adapter, Options{CompletionGate: cg, ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(proto.StageTester))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("verdict: got %q want fail", res.Verdict)
	}
	if res.BlockingStage != "completion_gate" {
		t.Fatalf("blocking_stage: got %q want completion_gate", res.BlockingStage)
	}
}

func TestRunnerAdapterError(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
		},
		errAfter: 1,
		err:      errors.New("subprocess died"),
	}
	r, _ := New(adapter, Options{ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(proto.StageCoder, proto.StageReview))
	if err != nil {
		t.Fatalf("RunAttempt should NOT return error (failure folded into result): %v", err)
	}
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("verdict: got %q want fail", res.Verdict)
	}
	if res.Error == "" {
		t.Fatalf("error field should be populated")
	}
}

func TestRunnerInvalidRequest(t *testing.T) {
	adapter := &fakeAdapter{}
	r, _ := New(adapter, Options{})
	_, err := r.RunAttempt(context.Background(), &proto.PipelineAttemptRequestV1{})
	if err == nil {
		t.Fatalf("expected error for invalid request")
	}
}

func TestRunnerNoAdapter(t *testing.T) {
	if _, err := New(nil, Options{}); err == nil {
		t.Fatalf("expected ErrNoAdapter")
	}
}

func TestRunnerLogDirPropagates(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageIntake, verdict: proto.VerdictPass},
		},
	}
	r, _ := New(adapter, Options{ResultDir: t.TempDir(), LogDir: "/tmp/logs"})
	if _, err := r.RunAttempt(context.Background(), newReq(proto.StageIntake)); err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if adapter.calls[0].LogFile != "/tmp/logs/intake.log" {
		t.Fatalf("log file: got %q want /tmp/logs/intake.log", adapter.calls[0].LogFile)
	}
}

func TestRunnerCleanupAndDocsStages(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageCleanup, verdict: proto.VerdictPass, agentCalls: 1},
			{stage: proto.StageDocs, verdict: proto.VerdictSkip},
		},
	}
	r, _ := New(adapter, Options{ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(proto.StageCleanup, proto.StageDocs))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Verdict != proto.VerdictPass && res.Verdict != proto.VerdictSkip {
		t.Fatalf("verdict: got %q want pass/skip", res.Verdict)
	}
	if len(res.Stages) != 2 {
		t.Fatalf("stages: got %d want 2", len(res.Stages))
	}
}

// TestRunnerStageFailRoutesToSaveExit reproduces the exit-127 regression
// from HUMAN_NOTES.md. When a non-coder stage emits verdict="fail" (or the
// adapter synthesizes one for a structural subprocess crash), the
// per-attempt result must carry AttemptOutcomeFailureSaveExit — not
// FailureRetry — so RunCompleteLoop terminates instead of looping until
// autonomous_timeout. The 147-iteration log was symptomatic of this routing
// mistake: structural failures were being treated as recoverable.
func TestRunnerStageFailRoutesToSaveExit(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageIntake, verdict: proto.VerdictFail, exitReason: "exit=127"},
		},
	}
	r, _ := New(adapter, Options{ResultDir: t.TempDir()})
	res, err := r.RunAttempt(context.Background(), newReq(proto.StageIntake, proto.StageCoder))
	if err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeFailureSaveExit {
		t.Fatalf("outcome: got %q want failure_save_exit (structural failure must NOT loop)", res.Outcome)
	}
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("verdict: got %q want fail", res.Verdict)
	}
	if res.BlockingStage != proto.StageIntake {
		t.Fatalf("blocking_stage: got %q want intake", res.BlockingStage)
	}
	// The runner must NOT have advanced past the failed stage.
	if len(adapter.calls) != 1 {
		t.Fatalf("downstream stage ran after intake fail: %d calls", len(adapter.calls))
	}
}

// TestOutcomeForVerdictMapping locks the outcomeFor contract so a future
// edit cannot silently re-introduce the unbounded-retry bug. Only "rework"
// is recoverable; everything that isn't pass/skip/rework terminates the
// outer loop.
func TestOutcomeForVerdictMapping(t *testing.T) {
	cases := []struct {
		verdict string
		want    string
	}{
		{proto.VerdictPass, proto.AttemptOutcomeSuccess},
		{proto.VerdictSkip, proto.AttemptOutcomeSuccess},
		{proto.VerdictBlock, proto.AttemptOutcomeFailureSaveExit},
		{proto.VerdictFail, proto.AttemptOutcomeFailureSaveExit},
		{proto.VerdictRework, proto.AttemptOutcomeFailureRetry},
		{"unrecognized_verdict", proto.AttemptOutcomeFailureSaveExit},
	}
	for _, c := range cases {
		if got := outcomeFor(c.verdict); got != c.want {
			t.Errorf("outcomeFor(%q) = %q, want %q", c.verdict, got, c.want)
		}
	}
}

func TestRunnerStageEnvForwarded(t *testing.T) {
	adapter := &fakeAdapter{
		sequence: []fakeOutcome{
			{stage: proto.StageCoder, verdict: proto.VerdictPass},
		},
	}
	r, _ := New(adapter, Options{ResultDir: t.TempDir()})
	req := newReq(proto.StageCoder)
	req.StageEnv = map[string]map[string]string{
		proto.StageCoder: {"EFFECTIVE_CODER_MAX_TURNS": "60"},
	}
	if _, err := r.RunAttempt(context.Background(), req); err != nil {
		t.Fatalf("RunAttempt: %v", err)
	}
	if got := adapter.calls[0].EnvOverrides["EFFECTIVE_CODER_MAX_TURNS"]; got != "60" {
		t.Fatalf("env override not forwarded: %q", got)
	}
}
