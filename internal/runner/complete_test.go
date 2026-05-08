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
