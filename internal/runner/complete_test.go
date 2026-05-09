package runner

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeAcceptance lets tests force the milestone-acceptance result without
// shelling to bash.
type fakeAcceptance struct {
	calls int32
	pass  []bool
}

func (a *fakeAcceptance) Check(_ context.Context, _ string) (bool, error) {
	idx := int(atomic.AddInt32(&a.calls, 1)) - 1
	if idx >= len(a.pass) {
		return true, nil
	}
	return a.pass[idx], nil
}

func TestRunCompleteLoopSucceedsImmediately(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 3},
		},
	}
	r := New(fp)
	res, err := r.RunCompleteLoop(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Disposition != proto.RunDispositionSuccess {
		t.Fatalf("want success; got %q", res.Disposition)
	}
	if res.Attempts != 1 {
		t.Fatalf("want attempts=1; got %d", res.Attempts)
	}
	if atomic.LoadInt32(&fp.calls) != 1 {
		t.Fatalf("pipeline called %d times; want 1", fp.calls)
	}
}

func TestRunCompleteLoopRetriesUntilMaxAttempts(t *testing.T) {
	req := validReq(t)
	req.MaxPipelineAttempts = 3
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeFailureRetry},
			{Outcome: proto.AttemptOutcomeFailureRetry},
			{Outcome: proto.AttemptOutcomeFailureRetry},
		},
	}
	r := New(fp)
	res, err := r.RunCompleteLoop(context.Background(), req)
	if err == nil || err != ErrSafetyBound {
		t.Fatalf("want ErrSafetyBound; got %v", err)
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("want failure; got %q", res.Disposition)
	}
	if atomic.LoadInt32(&fp.calls) != 3 {
		t.Fatalf("pipeline called %d times; want 3", fp.calls)
	}
}

func TestRunCompleteLoopHonorsAgentCap(t *testing.T) {
	req := validReq(t)
	req.MaxAutonomousAgentCalls = 5
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeFailureRetry, AgentCalls: 6},
		},
	}
	r := New(fp)
	res, err := r.RunCompleteLoop(context.Background(), req)
	if err != ErrSafetyBound {
		t.Fatalf("want ErrSafetyBound; got %v", err)
	}
	if res.Disposition != proto.RunDispositionAgentCap {
		t.Fatalf("want agent_cap; got %q", res.Disposition)
	}
}

func TestRunCompleteLoopHonorsTimeout(t *testing.T) {
	req := validReq(t)
	req.AutonomousTimeoutSecs = 1
	// Build a fake clock that jumps 5 seconds on second call.
	calls := 0
	r := New(&fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeFailureRetry},
		},
	})
	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	r.Now = func() time.Time {
		calls++
		switch calls {
		case 1:
			return t0
		case 2:
			return t0
		default:
			return t0.Add(10 * time.Second)
		}
	}
	res, err := r.RunCompleteLoop(context.Background(), req)
	if err != ErrSafetyBound {
		t.Fatalf("want ErrSafetyBound; got %v", err)
	}
	if res.Disposition != proto.RunDispositionTimeout {
		t.Fatalf("want timeout; got %q", res.Disposition)
	}
}

func TestRunCompleteLoopAcceptanceFailureLoopsThenStuck(t *testing.T) {
	req := validReq(t)
	req.Mode = proto.RunModeMilestone
	req.Milestone = "m99"
	req.MaxPipelineAttempts = 5
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 1},
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 1},
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 1},
		},
	}
	acc := &fakeAcceptance{pass: []bool{false, false, true}}
	r := New(fp)
	r.Acceptance = acc

	res, err := r.RunCompleteLoop(context.Background(), req)
	if err != ErrStuck {
		t.Fatalf("want ErrStuck; got %v", err)
	}
	if res.Disposition != proto.RunDispositionStuck {
		t.Fatalf("want stuck; got %q", res.Disposition)
	}
	if atomic.LoadInt32(&fp.calls) != 2 {
		t.Fatalf("want 2 attempts before stuck; got %d", fp.calls)
	}
}

func TestRunCompleteLoopAcceptancePassResetsCounter(t *testing.T) {
	req := validReq(t)
	req.Mode = proto.RunModeMilestone
	req.Milestone = "m99"
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 1},
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 2},
		},
	}
	acc := &fakeAcceptance{pass: []bool{false, true}}
	r := New(fp)
	r.Acceptance = acc

	res, err := r.RunCompleteLoop(context.Background(), req)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Disposition != proto.RunDispositionSuccess {
		t.Fatalf("want success; got %q", res.Disposition)
	}
}

// TestRunCompleteLoopExit127BoundedByMaxAttempts is the regression test for
// the 147-retry bug recorded in HUMAN_NOTES.md. A stage subprocess that
// exits 127 ("command not found") is a deterministic structural failure —
// the outer loop must not treat it as recoverable. The pipeline reports
// AttemptOutcomeFailureSaveExit (per the outcomeFor("fail") mapping), so
// RunCompleteLoop terminates after a single iteration and surfaces the
// structural error class, instead of looping until the autonomous_timeout
// burns through ~150 iterations.
//
// MAX_TRANSIENT_RETRIES is the supervisor-level agent-call retry budget
// (default 3); for a structural stage failure the loop must give up well
// before MAX_TRANSIENT_RETRIES + 1 invocations.
func TestRunCompleteLoopExit127BoundedByMaxAttempts(t *testing.T) {
	req := validReq(t)
	// Defensive: even if maxAttempts somehow defaulted higher, the structural-
	// failure routing in pipeline.outcomeFor must terminate the loop after
	// the first failed attempt.
	req.MaxPipelineAttempts = 100
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{
				Outcome:       proto.AttemptOutcomeFailureSaveExit,
				Verdict:       proto.VerdictFail,
				BlockingStage: proto.StageIntake,
				Error:         "stagerunner: subprocess failed\nexit status 127",
			},
		},
	}
	r := New(fp)
	res, err := r.RunCompleteLoop(context.Background(), req)
	if err != nil {
		t.Fatalf("RunCompleteLoop: %v", err)
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("disposition: got %q want failure", res.Disposition)
	}
	if got := atomic.LoadInt32(&fp.calls); got != 1 {
		t.Fatalf("pipeline invoked %d times; structural failure must not retry (want 1)", got)
	}
	if res.ErrorClass != proto.StageIntake {
		t.Fatalf("error_class: got %q want intake", res.ErrorClass)
	}
	if res.Recovery != "save_exit" {
		t.Fatalf("recovery: got %q want save_exit", res.Recovery)
	}
}

// TestRunCompleteLoopRepeatedSaveExitDoesNotIterate is the paranoid variant
// of the above: even when the fake pipeline is willing to keep returning
// FailureSaveExit, the outer loop must terminate after one attempt rather
// than draining the result list.
func TestRunCompleteLoopRepeatedSaveExitDoesNotIterate(t *testing.T) {
	req := validReq(t)
	req.MaxPipelineAttempts = 100
	results := make([]*proto.PipelineAttemptResultV1, 100)
	for i := range results {
		results[i] = &proto.PipelineAttemptResultV1{
			Outcome:       proto.AttemptOutcomeFailureSaveExit,
			Verdict:       proto.VerdictFail,
			BlockingStage: proto.StageIntake,
		}
	}
	fp := &fakePipeline{results: results}
	r := New(fp)
	res, err := r.RunCompleteLoop(context.Background(), req)
	if err != nil {
		t.Fatalf("RunCompleteLoop: %v", err)
	}
	if got := atomic.LoadInt32(&fp.calls); got != 1 {
		t.Fatalf("pipeline invoked %d times; save_exit must terminate immediately", got)
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("disposition: got %q want failure", res.Disposition)
	}
}

func TestRunCompleteLoopWritesResult(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 2},
		},
	}
	r := New(fp)
	res, _ := r.RunCompleteLoop(context.Background(), req)
	if res.AgentCalls != 2 {
		t.Fatalf("want agent_calls=2; got %d", res.AgentCalls)
	}
}
