package runner

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

func TestIsCompleteLoopExit(t *testing.T) {
	tests := map[string]bool{
		"complete_loop_timeout": true,
		"complete_loop_failure": true,
		"":                      false,
		"intake_failed":         false,
	}
	for in, want := range tests {
		if got := isCompleteLoopExit(in); got != want {
			t.Fatalf("isCompleteLoopExit(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestResumeMissingState(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	r := New(&fakePipeline{})
	r.State = store
	_, err := r.Resume(context.Background())
	if err == nil {
		t.Fatalf("want error when state file missing")
	}
}

func TestResumeRebuildsTaskRequest(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	if err := store.Update(func(s *proto.StateSnapshotV1) {
		s.ResumeTask = "do thing"
		s.ExitReason = "stage_failed_review"
		s.PipelineAttempt = 2
	}); err != nil {
		t.Fatalf("write state: %v", err)
	}
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess},
		},
	}
	r := New(fp)
	r.State = store
	// Set defaults that validateAndDefault needs.
	dir := t.TempDir()
	res, err := r.resumeWithEnv(context.Background(), dir, dir)
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if res.Disposition != proto.RunDispositionSuccess {
		t.Fatalf("want success; got %q", res.Disposition)
	}
}

// resumeWithEnv is a test-helper wrapping Resume that fills env defaults the
// CLI layer would normally inject. Keeps the test stable without exporting
// extra plumbing.
func (r *Runner) resumeWithEnv(ctx context.Context, project, home string) (*proto.RunResultV1, error) {
	snap, err := r.State.Read()
	if err != nil {
		return nil, err
	}
	req := r.requestFromSnapshot(snap)
	ApplyEnvDefaults(req, project, home)
	if isCompleteLoopExit(snap.ExitReason) {
		return r.RunCompleteLoop(ctx, req)
	}
	return r.RunSingle(ctx, req)
}

func TestRequestFromSnapshotMilestoneMode(t *testing.T) {
	r := New(&fakePipeline{})
	snap := &proto.StateSnapshotV1{
		ResumeTask:  "ms task",
		MilestoneID: "m42",
		ExitReason:  "complete_loop_failure",
	}
	req := r.requestFromSnapshot(snap)
	if req.Mode != proto.RunModeMilestone {
		t.Fatalf("want milestone mode; got %q", req.Mode)
	}
	if req.Milestone != "m42" {
		t.Fatalf("want m42; got %q", req.Milestone)
	}
	if !req.Complete {
		t.Fatalf("complete flag should be set when exit_reason is complete_loop_*")
	}
}

func TestApplyEnvDefaultsLeavesNonEmpty(t *testing.T) {
	req := &proto.RunRequestV1{ProjectDir: "/orig", TekhtonHome: "/orig-home"}
	ApplyEnvDefaults(req, "/p", "/h")
	if req.ProjectDir != "/orig" || req.TekhtonHome != "/orig-home" {
		t.Fatalf("override clobbered non-empty fields")
	}
}

// TestResumeProductionPath exercises r.Resume(ctx) directly (the production
// CLI dispatch path) — not the resumeWithEnv test helper. It seeds a state
// file with a saved task and ensures that the Runner's ProjectDir/TekhtonHome
// fields refill the rebuilt request so validateAndDefault accepts it.
func TestResumeProductionPath(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	if err := store.Update(func(s *proto.StateSnapshotV1) {
		s.ResumeTask = "do thing"
		s.ExitReason = "stage_failed_review"
		s.PipelineAttempt = 2
	}); err != nil {
		t.Fatalf("write state: %v", err)
	}
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{
			{Outcome: proto.AttemptOutcomeSuccess},
		},
	}
	r := New(fp)
	r.State = store
	r.ProjectDir = tmp
	r.TekhtonHome = t.TempDir()

	res, err := r.Resume(context.Background())
	if err != nil {
		t.Fatalf("Resume: %v", err)
	}
	if res.Disposition != proto.RunDispositionSuccess {
		t.Fatalf("want success; got %q", res.Disposition)
	}
}

// TestResumeProductionPathRejectsMissingAmbient confirms Resume still surfaces
// an invalid-request error when the Runner was constructed without
// ProjectDir/TekhtonHome — the validation gate is intact, the fix only adds
// the success path that depends on the ambient context being present.
func TestResumeProductionPathRejectsMissingAmbient(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	if err := store.Update(func(s *proto.StateSnapshotV1) {
		s.ResumeTask = "do thing"
		s.ExitReason = "stage_failed_review"
	}); err != nil {
		t.Fatalf("write state: %v", err)
	}
	r := New(&fakePipeline{})
	r.State = store
	// Intentionally leave r.ProjectDir / r.TekhtonHome empty.

	_, err := r.Resume(context.Background())
	if err == nil {
		t.Fatalf("want ErrInvalidRequest when ambient context is missing")
	}
}
