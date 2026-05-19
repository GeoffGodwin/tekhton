package runner

import (
	"context"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// RunSingle drives one pipeline attempt — the --task non-complete-mode path.
//
// Lifecycle:
//  1. Validate the request.
//  2. (Hook) Run pre-flight.
//  3. (Optional) Start the TUI sidecar.
//  4. Build a tekhton.pipeline.attempt.request.v1 envelope and call
//     Pipeline.RunAttempt once.
//  5. Translate the per-attempt result into a tekhton.run.result.v1 envelope.
//  6. (Hook) Run finalize with the disposition env vars set.
//  7. (Optional) Stop the TUI sidecar.
func (r *Runner) RunSingle(ctx context.Context, req *proto.RunRequestV1) (*proto.RunResultV1, error) {
	if err := r.validateAndDefault(req); err != nil {
		return nil, err
	}

	if r.Hooks != nil {
		if err := r.Hooks.Preflight(ctx, req); err != nil {
			return nil, err
		}
	}

	startedTUI := false
	if r.TUI != nil && !req.NoTUI {
		if err := r.TUI.Start(ctx); err == nil {
			startedTUI = true
		}
	}
	defer func() {
		if startedTUI {
			_ = r.TUI.Stop(context.Background(), false)
		}
	}()

	start := r.Now()
	pipeReq := r.buildPipelineRequest(req)
	pipeRes, pipeErr := r.Pipeline.RunAttempt(ctx, pipeReq)

	res := &proto.RunResultV1{
		Proto:       proto.RunResultProtoV1,
		Attempts:    1,
		ElapsedSecs: int64(r.Now().Sub(start).Seconds()),
	}
	if pipeRes != nil {
		res.AgentCalls = pipeRes.AgentCalls
	}
	if pipeErr != nil {
		res.Disposition = proto.RunDispositionFailure
		res.ErrorMessage = pipeErr.Error()
	} else if pipeRes != nil && pipeRes.Outcome == proto.AttemptOutcomeSuccess {
		res.Disposition = proto.RunDispositionSuccess
	} else if pipeRes != nil {
		res.Disposition = proto.RunDispositionFailure
		res.Recovery = "save_exit"
		res.ErrorMessage = pipeRes.Error
		res.ErrorClass = pipeRes.BlockingStage
	} else {
		res.Disposition = proto.RunDispositionFailure
		res.ErrorMessage = "pipeline returned no result"
	}

	resultPath := r.resultPath(req)
	if err := r.writeResult(resultPath, res); err != nil {
		fmt.Fprintln(r.Stderr, "runner: warning: write result:", err)
	}

	if r.Hooks != nil {
		if err := r.Hooks.Finalize(ctx, req, res); err != nil {
			fmt.Fprintln(r.Stderr, "runner: finalize:", err)
		}
	}

	return res, pipeErr
}

// buildPipelineRequest derives the per-attempt envelope from the run request.
// The Order list is fixed for now (standard pipeline) — a future port of
// PIPELINE_ORDER resolution lives in lib/pipeline_order.sh, which stays bash.
func (r *Runner) buildPipelineRequest(req *proto.RunRequestV1) *proto.PipelineAttemptRequestV1 {
	pr := &proto.PipelineAttemptRequestV1{
		Proto:      proto.PipelineAttemptRequestProtoV1,
		Task:       req.Task,
		Milestone:  req.Milestone,
		Order:      defaultStageOrder(),
		ProjectDir: req.ProjectDir,
		StageEnv:   buildStageEnv(req),
	}
	pr.EnsureProto()
	return pr
}

// buildStageEnv synthesizes the per-stage env overrides expected by the bash
// stage scripts. The legacy pipeline set MILESTONE_MODE / _CURRENT_MILESTONE
// as bash globals at flag-parse time; under V4 the Go binary owns flag
// parsing, so we must propagate these into every stage subprocess or the
// bash stages crash under `set -u` (e.g. intake_helpers.sh:191).
//
// Applied uniformly to every stage in defaultStageOrder so a stage added
// later that touches the same globals automatically inherits the env.
func buildStageEnv(req *proto.RunRequestV1) map[string]map[string]string {
	if req == nil {
		return nil
	}
	common := map[string]string{}
	if req.Milestone != "" {
		common["MILESTONE_MODE"] = "true"
		common["_CURRENT_MILESTONE"] = req.Milestone
	} else {
		common["MILESTONE_MODE"] = "false"
	}
	// TASK is read directly by several bash stage helpers
	// (e.g. intake_helpers.sh:224 — fallback to the task string in
	// non-milestone mode). Always export it (empty if absent) so
	// `set -u` doesn't crash the stage subprocess.
	common["TASK"] = req.Task
	if req.AutoAdvance {
		common["AUTO_ADVANCE"] = "true"
	}
	if req.HumanTag != "" {
		common["HUMAN_NOTES_TAG"] = req.HumanTag
	}
	if req.Mode == proto.RunModeHuman {
		common["HUMAN_MODE"] = "true"
	}
	if len(common) == 0 {
		return nil
	}
	out := make(map[string]map[string]string, len(defaultStageOrder()))
	for _, stage := range defaultStageOrder() {
		stageCopy := make(map[string]string, len(common))
		for k, v := range common {
			stageCopy[k] = v
		}
		out[stage] = stageCopy
	}
	return out
}

// defaultStageOrder is the standard pipeline order. The bash side resolves
// PIPELINE_ORDER (standard | test_first) — the runner today picks "standard"
// and the bash bridge is responsible for the test_first variant when that
// path lights up.
func defaultStageOrder() []string {
	return []string{
		proto.StageIntake,
		proto.StageCoder,
		proto.StageSecurity,
		proto.StageReview,
		proto.StageTester,
	}
}
