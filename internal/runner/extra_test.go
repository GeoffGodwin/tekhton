package runner

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

func TestResultPathRespectsOverride(t *testing.T) {
	r := New(&fakePipeline{})
	r.RunResultFile = "/explicit/result.json"
	got := r.resultPath(&proto.RunRequestV1{ProjectDir: "/should/ignore"})
	if got != "/explicit/result.json" {
		t.Fatalf("override ignored: %q", got)
	}
}

func TestWriteResultEmptyPathIsNoOp(t *testing.T) {
	r := New(&fakePipeline{})
	if err := r.writeResult("", &proto.RunResultV1{}); err != nil {
		t.Fatalf("empty path should noop; got %v", err)
	}
}

func TestRunCompleteLoopWritesRunResultFile(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess, AgentCalls: 4},
		},
	}
	r := New(fp)
	_, err := r.RunCompleteLoop(context.Background(), req)
	if err != nil {
		t.Fatalf("complete: %v", err)
	}
	want := filepath.Join(req.ProjectDir, ".tekhton", "RUN_RESULT.json")
	if _, err := readResultFile(want); err != nil {
		t.Fatalf("RUN_RESULT.json missing/invalid: %v", err)
	}
}

func TestRunCompleteLoopClearsStateOnSuccess(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	// seed a stale state file
	if err := store.Update(func(s *proto.StateSnapshotV1) {
		s.ResumeTask = "stale"
	}); err != nil {
		t.Fatal(err)
	}
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess},
		},
	}
	r := New(fp)
	r.State = store
	req := validReq(t)
	if _, err := r.RunCompleteLoop(context.Background(), req); err != nil {
		t.Fatalf("complete: %v", err)
	}
	if _, err := store.Read(); !errors.Is(err, state.ErrNotFound) {
		t.Fatalf("state should be cleared after success: %v", err)
	}
}

func TestRunSingleNilRequest(t *testing.T) {
	r := New(&fakePipeline{})
	_, err := r.RunSingle(context.Background(), nil)
	if !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("want ErrInvalidRequest; got %v", err)
	}
}

func TestRunCompleteLoopNilRequest(t *testing.T) {
	r := New(&fakePipeline{})
	_, err := r.RunCompleteLoop(context.Background(), nil)
	if !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("want ErrInvalidRequest; got %v", err)
	}
}

// readResultFile is a tiny helper; tests need to read the result file we
// wrote. Mirrors the Go runner's own writeResult.
func readResultFile(path string) (*proto.RunResultV1, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	res := &proto.RunResultV1{}
	if err := json.Unmarshal(b, res); err != nil {
		return nil, err
	}
	return res, nil
}
