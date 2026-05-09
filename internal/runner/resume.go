package runner

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// Resume reads PIPELINE_STATE.json and continues the run. The on-disk state
// is the m03 Go writer's tekhton.state.v1 envelope; markdown-formatted
// snapshots from V3 are not supported here (callers must run the migration
// tool — `bash tekhton.sh --resume` still works against the legacy reader).
//
// Resume routing:
//   - If the saved state has milestone_id, pick milestone mode.
//   - Otherwise, pick task mode and inherit the saved task.
//   - The saved exit_reason informs which run path (single vs complete).
//     A complete_loop_* exit_reason resumes via RunCompleteLoop; anything
//     else resumes via RunSingle.
func (r *Runner) Resume(ctx context.Context) (*proto.RunResultV1, error) {
	if r.State == nil {
		return nil, fmt.Errorf("runner: resume requires a state store")
	}
	snap, err := r.State.Read()
	if err != nil {
		if errors.Is(err, state.ErrNotFound) {
			return nil, fmt.Errorf("runner: nothing to resume — no state file at %s", r.State.Path())
		}
		if errors.Is(err, state.ErrLegacyFormat) {
			return nil, fmt.Errorf("runner: legacy V3 state file at %s — run `tekhton state migrate` first", r.State.Path())
		}
		return nil, fmt.Errorf("runner: read state: %w", err)
	}

	req := r.requestFromSnapshot(snap)
	if err := r.validateAndDefault(req); err != nil {
		return nil, err
	}

	if isCompleteLoopExit(snap.ExitReason) {
		return r.RunCompleteLoop(ctx, req)
	}
	return r.RunSingle(ctx, req)
}

// requestFromSnapshot rebuilds a RunRequestV1 from a saved state envelope.
// ProjectDir/TekhtonHome are not in the snapshot (the bash state writer never
// put them there) — Resume copies them off the Runner instance, which the CLI
// layer populates from --project-dir / --tekhton-home (or their env defaults)
// at flag-parse time. By Phase 5 they will live in snap.Extra and the Runner
// fields become redundant.
func (r *Runner) requestFromSnapshot(snap *proto.StateSnapshotV1) *proto.RunRequestV1 {
	req := &proto.RunRequestV1{
		Proto:       proto.RunRequestProtoV1,
		Mode:        proto.RunModeResume,
		Task:        snap.ResumeTask,
		Complete:    isCompleteLoopExit(snap.ExitReason),
		ProjectDir:  r.ProjectDir,
		TekhtonHome: r.TekhtonHome,
	}
	if snap.MilestoneID != "" {
		req.Mode = proto.RunModeMilestone
		req.Milestone = snap.MilestoneID
	} else if req.Task != "" {
		req.Mode = proto.RunModeTask
	}
	return req
}

func isCompleteLoopExit(exit string) bool {
	return strings.HasPrefix(exit, "complete_loop_")
}

// ApplyEnvDefaults fills missing ProjectDir / TekhtonHome on a request from
// the process env. CLI callers use this so a request built by the resume
// path picks up the same env defaults as `tekhton run` would.
func ApplyEnvDefaults(req *proto.RunRequestV1, project, home string) {
	if req == nil {
		return
	}
	if req.ProjectDir == "" {
		req.ProjectDir = project
	}
	if req.TekhtonHome == "" {
		req.TekhtonHome = home
	}
}
