package runner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// fakePipeline records calls and returns canned results.
type fakePipeline struct {
	calls   int32
	results []*proto.PipelineAttemptResultV1
	errs    []error
}

func (f *fakePipeline) RunAttempt(_ context.Context, _ *proto.PipelineAttemptRequestV1) (*proto.PipelineAttemptResultV1, error) {
	idx := int(atomic.AddInt32(&f.calls, 1)) - 1
	var res *proto.PipelineAttemptResultV1
	var err error
	if idx < len(f.results) {
		res = f.results[idx]
	}
	if idx < len(f.errs) {
		err = f.errs[idx]
	}
	return res, err
}

// fakeHooks records preflight/finalize invocations.
type fakeHooks struct {
	preflightCalls int32
	finalizeCalls  int32
	preflightErr   error
	lastResult     *proto.RunResultV1
	lastDispo      string
}

func (h *fakeHooks) Preflight(_ context.Context, _ *proto.RunRequestV1) error {
	atomic.AddInt32(&h.preflightCalls, 1)
	return h.preflightErr
}

func (h *fakeHooks) Finalize(_ context.Context, _ *proto.RunRequestV1, res *proto.RunResultV1) error {
	atomic.AddInt32(&h.finalizeCalls, 1)
	h.lastResult = res
	if res != nil {
		h.lastDispo = res.Disposition
	}
	return nil
}

func validReq(t *testing.T) *proto.RunRequestV1 {
	t.Helper()
	dir := t.TempDir()
	return &proto.RunRequestV1{
		Proto:       proto.RunRequestProtoV1,
		Mode:        proto.RunModeTask,
		Task:        "do thing",
		ProjectDir:  dir,
		TekhtonHome: t.TempDir(),
	}
}

func TestRunSingleSuccess(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 5},
		},
	}
	fh := &fakeHooks{}
	r := New(fp)
	r.Hooks = fh

	res, err := r.RunSingle(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Disposition != proto.RunDispositionSuccess {
		t.Fatalf("want success, got %q", res.Disposition)
	}
	if res.Attempts != 1 {
		t.Fatalf("want attempts=1, got %d", res.Attempts)
	}
	if res.AgentCalls != 5 {
		t.Fatalf("want agent_calls=5, got %d", res.AgentCalls)
	}
	if atomic.LoadInt32(&fh.preflightCalls) != 1 {
		t.Fatalf("preflight not called")
	}
	if atomic.LoadInt32(&fh.finalizeCalls) != 1 {
		t.Fatalf("finalize not called")
	}
	if fh.lastDispo != proto.RunDispositionSuccess {
		t.Fatalf("finalize saw %q, want success", fh.lastDispo)
	}
}

func TestRunSingleFailure(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeFailureSaveExit, BlockingStage: proto.StageReview, Error: "review blocked"},
		},
	}
	r := New(fp)
	res, err := r.RunSingle(context.Background(), req)
	if err != nil {
		t.Fatalf("RunSingle returns nil err on failure-save-exit (pipeRes != nil); got %v", err)
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("want failure, got %q", res.Disposition)
	}
	if res.ErrorClass != proto.StageReview {
		t.Fatalf("want error_class=review, got %q", res.ErrorClass)
	}
}

func TestRunSinglePreflightAborts(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{}
	fh := &fakeHooks{preflightErr: errors.New("boom")}
	r := New(fp)
	r.Hooks = fh
	_, err := r.RunSingle(context.Background(), req)
	if err == nil {
		t.Fatalf("expected preflight error")
	}
	if atomic.LoadInt32(&fp.calls) != 0 {
		t.Fatalf("pipeline ran despite preflight error")
	}
}

func TestRunSingleResultFileWritten(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 1},
		},
	}
	r := New(fp)
	_, _ = r.RunSingle(context.Background(), req)
	want := filepath.Join(req.ProjectDir, ".tekhton", "RUN_RESULT.json")
	if _, err := os.Stat(want); err != nil {
		t.Fatalf("RUN_RESULT.json not written: %v", err)
	}
}

func TestEffectiveBoundsHonorsRequest(t *testing.T) {
	r := New(&fakePipeline{})
	req := &proto.RunRequestV1{
		MaxPipelineAttempts:     7,
		AutonomousTimeoutSecs:   100,
		MaxAutonomousAgentCalls: 50,
	}
	a, t1, c := r.effectiveBounds(req)
	if a != 7 || t1 != 100 || c != 50 {
		t.Fatalf("want 7,100,50; got %d,%d,%d", a, t1, c)
	}
}

func TestEffectiveBoundsFallsBackToDefaults(t *testing.T) {
	r := New(&fakePipeline{})
	a, t1, c := r.effectiveBounds(&proto.RunRequestV1{})
	if a != 5 || t1 != 7200 || c != 200 {
		t.Fatalf("want defaults 5,7200,200; got %d,%d,%d", a, t1, c)
	}
}

func TestNewSetsDefaults(t *testing.T) {
	r := New(&fakePipeline{})
	if r.Stdout == nil || r.Stderr == nil {
		t.Fatalf("std streams nil")
	}
	if r.Now == nil {
		t.Fatalf("Now nil")
	}
	now := r.Now()
	if now.IsZero() {
		t.Fatalf("Now returned zero time")
	}
	_ = time.Now()
}

func TestValidateAndDefaultRejectsNil(t *testing.T) {
	r := New(&fakePipeline{})
	err := r.validateAndDefault(nil)
	if err == nil || !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("want ErrInvalidRequest for nil; got %v", err)
	}
}

func TestBuildResumeFlags(t *testing.T) {
	tests := []struct {
		mode string
		tag  string
		want string
	}{
		{proto.RunModeTask, "", "--complete --start-at coder"},
		{proto.RunModeMilestone, "", "--complete --milestone --start-at coder"},
		{proto.RunModeHuman, "BUG", "--human BUG --start-at coder"},
		{proto.RunModeHuman, "", "--human --start-at coder"},
	}
	for _, tc := range tests {
		t.Run(tc.mode+":"+tc.tag, func(t *testing.T) {
			req := &proto.RunRequestV1{Mode: tc.mode, HumanTag: tc.tag}
			got := buildResumeFlags(req)
			if got != tc.want {
				t.Fatalf("want %q; got %q", tc.want, got)
			}
		})
	}
}

func TestPersistFailureStateZerosCountersOnSafetyBound(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	r := New(&fakePipeline{})
	r.State = store
	req := validReq(t)
	res := &proto.RunResultV1{
		Disposition: proto.RunDispositionTimeout,
		Attempts:    5,
		AgentCalls:  47,
	}
	r.persistFailureState(req, res)
	snap, err := store.Read()
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	if snap.PipelineAttempt != 0 || snap.AgentCallsTotal != 0 {
		t.Fatalf("safety-bound did not zero counters: %d / %d",
			snap.PipelineAttempt, snap.AgentCallsTotal)
	}
}

func TestPersistFailureStateKeepsCountersOnSaveExit(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	r := New(&fakePipeline{})
	r.State = store
	req := validReq(t)
	res := &proto.RunResultV1{
		Disposition: proto.RunDispositionFailure,
		Attempts:    3,
		AgentCalls:  17,
	}
	r.persistFailureState(req, res)
	snap, _ := store.Read()
	if snap.PipelineAttempt != 3 || snap.AgentCallsTotal != 17 {
		t.Fatalf("save_exit zeroed counters: %d / %d",
			snap.PipelineAttempt, snap.AgentCallsTotal)
	}
}
