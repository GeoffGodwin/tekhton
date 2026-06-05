package runner

import (
	"context"
	"os"
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

// TestRequestFromSnapshotAutoAdvanceFields covers the m40.1 round-trip: a
// snapshot with auto_advance=true and auto_advance_limit=4 must restore both
// fields onto the rebuilt RunRequestV1 so `tekhton --resume` continues the
// auto-advance arc the operator originally started.
func TestRequestFromSnapshotAutoAdvanceFields(t *testing.T) {
	r := New(&fakePipeline{})
	snap := &proto.StateSnapshotV1{
		ResumeTask:       "ms task",
		MilestoneID:      "m42",
		AutoAdvance:      true,
		AutoAdvanceLimit: 4,
	}
	req := r.requestFromSnapshot(snap)
	if !req.AutoAdvance {
		t.Fatalf("AutoAdvance should be true after round-trip")
	}
	if req.AutoAdvanceLimit != 4 {
		t.Fatalf("AutoAdvanceLimit = %d; want 4", req.AutoAdvanceLimit)
	}
}

// TestRequestFromSnapshotAutoAdvanceBackwardCompat verifies a state file
// written WITHOUT the new fields (i.e. by pre-m40.1 code) loads cleanly and
// leaves AutoAdvance / AutoAdvanceLimit at their zero values. Backward compat
// AC for m40.1.
func TestRequestFromSnapshotAutoAdvanceBackwardCompat(t *testing.T) {
	r := New(&fakePipeline{})
	snap := &proto.StateSnapshotV1{
		ResumeTask: "do thing",
		ExitReason: "stage_failed_review",
	}
	req := r.requestFromSnapshot(snap)
	if req.AutoAdvance {
		t.Fatalf("AutoAdvance should be false when snapshot omits the field")
	}
	if req.AutoAdvanceLimit != 0 {
		t.Fatalf("AutoAdvanceLimit = %d; want 0 when snapshot omits the field", req.AutoAdvanceLimit)
	}
}

// TestRequestFromSnapshotMilestoneIDFixture covers the m40.2 round-trip: a
// hand-authored fixture envelope containing `"milestone_id":"m34.2"` must
// rebuild a request with Mode == RunModeMilestone and Milestone == "m34.2"
// after passing through state.Read + requestFromSnapshot. Drives the same
// path operators reach via `tekhton --resume` from a halted milestone run.
func TestRequestFromSnapshotMilestoneIDFixture(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "PIPELINE_STATE.json")
	fixture := `{
  "proto":"tekhton.state.v1",
  "updated_at":"2026-06-05T08:00:00Z",
  "resume_task":"Implement milestone",
  "milestone_id":"m34.2",
  "exit_stage":"coder",
  "exit_reason":"stage_failed_review"
}
`
	if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	store := state.New(path)
	snap, err := store.Read()
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	r := New(&fakePipeline{})
	req := r.requestFromSnapshot(snap)
	if req.Mode != proto.RunModeMilestone {
		t.Fatalf("Mode = %q, want RunModeMilestone", req.Mode)
	}
	if req.Milestone != "m34.2" {
		t.Fatalf("Milestone = %q, want m34.2", req.Milestone)
	}
}

// TestRequestFromSnapshotMilestoneIDAbsentFallsThrough is the m40.2 backward-
// compat AC: a fixture without milestone_id must NOT route to milestone mode.
// It falls through to task mode when ResumeTask is present, or stays resume
// otherwise. Anchors the m40.2 behavior that a pre-m40.2 state file (no
// milestone_id key) keeps producing the historical resume request shape.
func TestRequestFromSnapshotMilestoneIDAbsentFallsThrough(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "PIPELINE_STATE.json")
	fixture := `{
  "proto":"tekhton.state.v1",
  "updated_at":"2026-06-05T08:00:00Z",
  "resume_task":"Continue task",
  "exit_stage":"review",
  "exit_reason":"stage_failed_review"
}
`
	if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	store := state.New(path)
	snap, err := store.Read()
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if snap.MilestoneID != "" {
		t.Fatalf("snap.MilestoneID = %q, want empty (fixture omits the key)", snap.MilestoneID)
	}
	r := New(&fakePipeline{})
	req := r.requestFromSnapshot(snap)
	if req.Mode != proto.RunModeTask {
		t.Fatalf("Mode = %q, want RunModeTask when milestone_id absent and ResumeTask present", req.Mode)
	}
	if req.Milestone != "" {
		t.Fatalf("Milestone = %q, want empty when fixture omits milestone_id", req.Milestone)
	}
}

// TestStateSnapshotAutoAdvanceJSONRoundTrip covers the on-disk JSON round-
// trip: encoded → decoded snapshots preserve both fields and the omitempty
// behavior (zero values emit no key, restored zero values match).
func TestStateSnapshotAutoAdvanceJSONRoundTrip(t *testing.T) {
	tmp := t.TempDir()
	store := state.New(filepath.Join(tmp, "PIPELINE_STATE.json"))
	if err := store.Update(func(s *proto.StateSnapshotV1) {
		s.MilestoneID = "m42"
		s.AutoAdvance = true
		s.AutoAdvanceLimit = 4
	}); err != nil {
		t.Fatalf("write state: %v", err)
	}
	snap, err := store.Read()
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	if !snap.AutoAdvance || snap.AutoAdvanceLimit != 4 {
		t.Fatalf("round-trip lost fields: AutoAdvance=%v, Limit=%d", snap.AutoAdvance, snap.AutoAdvanceLimit)
	}
	r := New(&fakePipeline{})
	req := r.requestFromSnapshot(snap)
	if !req.AutoAdvance || req.AutoAdvanceLimit != 4 {
		t.Fatalf("requestFromSnapshot lost fields: AutoAdvance=%v, Limit=%d", req.AutoAdvance, req.AutoAdvanceLimit)
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
