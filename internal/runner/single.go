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
//
// m26: every stage in defaultStageOrder() receives the SAME composed env
// (built once via r.envBuilder()). The legacy per-stage curation that
// shipped in 85b00ac is folded into EnvBuilder.Compose — a new bash file
// that reads MILESTONE_MODE/_CURRENT_MILESTONE/TASK/etc. now inherits
// them automatically, without a hand edit to single.go.
func (r *Runner) buildPipelineRequest(req *proto.RunRequestV1) *proto.PipelineAttemptRequestV1 {
	pr := &proto.PipelineAttemptRequestV1{
		Proto:      proto.PipelineAttemptRequestProtoV1,
		Task:       req.Task,
		Milestone:  req.Milestone,
		Order:      defaultStageOrder(),
		ProjectDir: req.ProjectDir,
		StageEnv:   r.buildStageEnv(req),
	}
	pr.EnsureProto()
	return pr
}

// envBuilder returns the runner's EnvBuilder, lazily constructing a
// defaults-only one if the caller never assigned r.Env. Production
// (cmd/tekhton/run.go:buildRunner) always assigns Env up-front; this
// fallback keeps direct-construction tests working.
func (r *Runner) envBuilder() *EnvBuilder {
	if r.Env != nil {
		return r.Env
	}
	r.Env = NewEnvBuilder(nil, LogContext{})
	return r.Env
}

// buildStageEnv composes the env contract once and applies it uniformly to
// every stage in defaultStageOrder. The KV slice from AsKV is folded into
// the StageRequestV1.EnvOverrides map shape stagerunner/adapter.go
// expects (KEY → value); a stage added later that needs a different
// override layers on top via a separate per-stage map (not used today).
func (r *Runner) buildStageEnv(req *proto.RunRequestV1) map[string]map[string]string {
	if req == nil {
		return nil
	}
	b := r.envBuilder()
	composed := b.Compose(req, nil)
	kv := b.AsKV(composed)
	if len(kv) == 0 {
		return nil
	}
	flat := make(map[string]string, len(kv))
	for _, line := range kv {
		for i := 0; i < len(line); i++ {
			if line[i] == '=' {
				flat[line[:i]] = line[i+1:]
				break
			}
		}
	}
	out := make(map[string]map[string]string, len(defaultStageOrder()))
	for _, stage := range defaultStageOrder() {
		stageCopy := make(map[string]string, len(flat))
		for k, v := range flat {
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
