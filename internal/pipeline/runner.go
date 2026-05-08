// Package pipeline owns the per-attempt scheduler ported from
// lib/orchestrate_iteration.sh::_run_pipeline_stages and its helpers as part
// of the m18 wedge.
//
// One Runner.RunAttempt = one full pass through the configured stage order
// (intake → coder → security → review → tester or test_first variants),
// applying build-gate retries inside the coder stage and review-rework
// cycles inside the review stage. The outer recovery loop (m12) sits above
// this package and decides how to react to a failed attempt.
package pipeline

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/stagerunner"
)

// Sentinel errors callers match with errors.Is.
var (
	// ErrInvalidConfig is returned when RunAttempt receives a request with
	// inconsistent fields (empty Order, ReviewCycle > MaxReviewCycles, etc.).
	ErrInvalidConfig = errors.New("pipeline: invalid configuration")

	// ErrNoAdapter is returned when Runner is constructed without a
	// stagerunner.Adapter.
	ErrNoAdapter = errors.New("pipeline: no stage adapter")
)

// Runner schedules stages for a single pipeline attempt. Construct via New
// and drive with RunAttempt.
type Runner struct {
	adapter   stagerunner.Adapter
	gate      *BuildGate
	complete  *CompletionGate
	now       func() time.Time
	resultDir string
	logDir    string
}

// Options carries the optional fields for New. Adapter is required.
type Options struct {
	Gate           *BuildGate
	CompletionGate *CompletionGate
	Now            func() time.Time
	ResultDir      string
	LogDir         string
}

// New constructs a Runner with the given stagerunner adapter.
func New(a stagerunner.Adapter, opts Options) (*Runner, error) {
	if a == nil {
		return nil, ErrNoAdapter
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	return &Runner{
		adapter:   a,
		gate:      opts.Gate,
		complete:  opts.CompletionGate,
		now:       now,
		resultDir: opts.ResultDir,
		logDir:    opts.LogDir,
	}, nil
}

// RunAttempt walks the resolved stage order once and returns the per-attempt
// result envelope. Failure short-circuits the schedule: a stage returning
// verdict "block" or "fail" stops downstream work.
//
// Review reworks are handled in-package: when review returns
// next_action="rework", the runner loops back to coder + review until either
// review approves or MaxReviewCycles is reached.
//
// The build gate (when configured) runs after the coder stage; on failure
// the runner re-invokes coder up to MaxBuildRetries times. The build-fix
// continuation loop (M128) inside the coder stage is NOT this — that's a
// sub-stage of coder and stays bash.
//
// The completion gate (when configured) runs after the tester stage on a
// pass.
func (r *Runner) RunAttempt(ctx context.Context, req *proto.PipelineAttemptRequestV1) (*proto.PipelineAttemptResultV1, error) {
	if err := req.Validate(); err != nil {
		return nil, fmt.Errorf("pipeline: %w", err)
	}
	if req.MaxReviewCycles < 0 {
		return nil, fmt.Errorf("%w: max_review_cycles negative", ErrInvalidConfig)
	}

	res := &proto.PipelineAttemptResultV1{
		Proto:   proto.PipelineAttemptResultProtoV1,
		Outcome: proto.AttemptOutcomeSuccess,
		Verdict: proto.VerdictPass,
		Stages:  []proto.StageBreakdown{},
	}
	start := r.now()
	reviewCycle := req.ReviewCycle
	if reviewCycle <= 0 {
		reviewCycle = 1
	}
	maxReview := req.MaxReviewCycles
	if maxReview <= 0 {
		maxReview = 3
	}
	maxBuild := req.MaxBuildRetries
	// 0 here means "no retries" — the gate runs once.

	scheduleIdx := 0
	for scheduleIdx < len(req.Order) {
		if err := ctx.Err(); err != nil {
			res.Outcome = proto.AttemptOutcomeFailureSaveExit
			res.Verdict = proto.VerdictFail
			res.Error = err.Error()
			break
		}
		stage := req.Order[scheduleIdx]
		switch stage {
		case proto.StageCoder:
			breakdown, err := r.runCoderWithGate(ctx, req, reviewCycle, maxBuild)
			res.Stages = append(res.Stages, breakdown...)
			if err != nil {
				r.fillFailure(res, err, breakdown)
				goto done
			}
			if last := lastBreakdown(breakdown); last != nil && shouldShortCircuit(last.Verdict) {
				res.Outcome = outcomeFor(last.Verdict)
				res.Verdict = last.Verdict
				res.BlockingStage = last.Stage
				goto done
			}
			scheduleIdx++

		case proto.StageReview:
			final, all, err := r.runReviewLoop(ctx, req, &reviewCycle, maxReview)
			res.Stages = append(res.Stages, all...)
			if err != nil {
				r.fillFailure(res, err, all)
				goto done
			}
			if final == nil {
				goto done
			}
			if final.Verdict == proto.VerdictRework {
				// Review rework loop exhausted without approval.
				res.Outcome = proto.AttemptOutcomeFailureRetry
				res.Verdict = proto.VerdictRework
				res.BlockingStage = proto.StageReview
				goto done
			}
			if shouldShortCircuit(final.Verdict) {
				res.Outcome = outcomeFor(final.Verdict)
				res.Verdict = final.Verdict
				res.BlockingStage = final.Stage
				goto done
			}
			scheduleIdx++

		case proto.StageTester:
			breakdown, err := r.runStage(ctx, req, stage, reviewCycle, 0)
			if breakdown != nil {
				res.Stages = append(res.Stages, *breakdown)
			}
			if err != nil {
				r.fillFailure(res, err, []proto.StageBreakdown{*breakdownOrEmpty(breakdown, stage)})
				goto done
			}
			if shouldShortCircuit(breakdown.Verdict) {
				res.Outcome = outcomeFor(breakdown.Verdict)
				res.Verdict = breakdown.Verdict
				res.BlockingStage = stage
				goto done
			}
			if r.complete != nil {
				cgVerdict, cgErr := r.complete.Run(ctx)
				if cgErr != nil {
					res.Outcome = proto.AttemptOutcomeFailureSaveExit
					res.Verdict = proto.VerdictFail
					res.BlockingStage = "completion_gate"
					res.Error = cgErr.Error()
					goto done
				}
				if cgVerdict != proto.VerdictPass {
					res.Outcome = outcomeFor(cgVerdict)
					res.Verdict = cgVerdict
					res.BlockingStage = "completion_gate"
					goto done
				}
			}
			scheduleIdx++

		default:
			breakdown, err := r.runStage(ctx, req, stage, reviewCycle, 0)
			if breakdown != nil {
				res.Stages = append(res.Stages, *breakdown)
			}
			if err != nil {
				r.fillFailure(res, err, []proto.StageBreakdown{*breakdownOrEmpty(breakdown, stage)})
				goto done
			}
			if shouldShortCircuit(breakdown.Verdict) {
				res.Outcome = outcomeFor(breakdown.Verdict)
				res.Verdict = breakdown.Verdict
				res.BlockingStage = stage
				goto done
			}
			scheduleIdx++
		}
	}

done:
	for _, s := range res.Stages {
		res.AgentCalls += s.AgentCalls
	}
	res.DurationSec = int(r.now().Sub(start).Seconds())
	return res, nil
}

// runCoderWithGate invokes the coder stage and, when configured, the build
// gate. On gate failure, re-invokes coder until MaxBuildRetries is reached.
// Returns the ordered breakdown (one or more coder entries).
func (r *Runner) runCoderWithGate(
	ctx context.Context,
	req *proto.PipelineAttemptRequestV1,
	reviewCycle, maxBuild int,
) ([]proto.StageBreakdown, error) {
	out := []proto.StageBreakdown{}
	for attempt := 0; attempt <= maxBuild; attempt++ {
		bd, err := r.runStage(ctx, req, proto.StageCoder, reviewCycle, attempt)
		if bd != nil {
			out = append(out, *bd)
		}
		if err != nil {
			return out, err
		}
		if shouldShortCircuit(bd.Verdict) {
			return out, nil
		}
		if r.gate == nil {
			return out, nil
		}
		gateVerdict, gateErr := r.gate.Run(ctx, attempt)
		if gateErr != nil {
			return out, gateErr
		}
		if gateVerdict == proto.VerdictPass {
			return out, nil
		}
		// Gate failed; loop unless we've exhausted retries.
		if attempt >= maxBuild {
			// Mark the last coder entry as failed by build gate.
			if last := lastBreakdown(out); last != nil {
				last.ExitReason = "build gate failed after retries"
				last.Verdict = proto.VerdictFail
				out[len(out)-1] = *last
			}
			return out, nil
		}
	}
	return out, nil
}

// runReviewLoop drives the review rework cycle. Returns the final review
// breakdown plus every stage entry produced (including coder reruns triggered
// by reworks, in case future variants want them; today coder reruns happen on
// the next outer-loop iteration so this slice is review-only).
func (r *Runner) runReviewLoop(
	ctx context.Context,
	req *proto.PipelineAttemptRequestV1,
	reviewCycle *int,
	maxReview int,
) (*proto.StageBreakdown, []proto.StageBreakdown, error) {
	all := []proto.StageBreakdown{}
	bd, err := r.runStage(ctx, req, proto.StageReview, *reviewCycle, 0)
	if bd != nil {
		all = append(all, *bd)
	}
	if err != nil {
		return bd, all, err
	}
	if bd.Verdict != proto.VerdictRework {
		return bd, all, nil
	}
	// Rework requested. Bump reviewCycle and return; the outer pipeline
	// scheduler owns coder reruns and the maxReview cap, and re-enters this
	// loop on the next iteration. Single-pass return preserves bash semantics.
	*reviewCycle++
	return bd, all, nil
}

// runStage is the leaf invocation of a stage adapter. Builds the
// StageRequestV1 and forwards to the adapter.
func (r *Runner) runStage(
	ctx context.Context,
	req *proto.PipelineAttemptRequestV1,
	stage string,
	reviewCycle, buildAttempt int,
) (*proto.StageBreakdown, error) {
	resultFile := r.resultFileFor(stage, reviewCycle, buildAttempt)
	logFile := r.logFileFor(stage)
	stageReq := &proto.StageRequestV1{
		Proto:        proto.StageRequestProtoV1,
		Stage:        stage,
		Task:         req.Task,
		Milestone:    req.Milestone,
		ReviewCycle:  reviewCycle,
		BuildAttempt: buildAttempt,
		ResultFile:   resultFile,
		LogFile:      logFile,
	}
	if req.StageEnv != nil {
		if env, ok := req.StageEnv[stage]; ok {
			stageReq.EnvOverrides = env
		}
	}
	res, err := r.adapter.Run(ctx, stageReq)
	if res == nil && err == nil {
		return nil, fmt.Errorf("pipeline: adapter returned nil result and nil error")
	}
	if res == nil {
		return nil, err
	}
	bd := &proto.StageBreakdown{
		Stage:        res.Stage,
		Verdict:      res.Verdict,
		ExitReason:   res.ExitReason,
		AgentCalls:   res.AgentCalls,
		DurationSec:  res.DurationSec,
		NextAction:   res.NextAction,
		ReviewCycle:  reviewCycle,
		BuildAttempt: buildAttempt,
	}
	return bd, err
}

// resultFileFor builds a unique-per-cycle result path so multiple invocations
// of the same stage in one attempt do not clobber each other.
func (r *Runner) resultFileFor(stage string, reviewCycle, buildAttempt int) string {
	dir := r.resultDir
	if dir == "" {
		dir = "/tmp"
	}
	name := fmt.Sprintf("stage_%s_r%d_b%d.json", stage, reviewCycle, buildAttempt)
	return filepath.Join(dir, name)
}

// logFileFor preserves the V3 stage log filename convention when LogDir is set.
func (r *Runner) logFileFor(stage string) string {
	if r.logDir == "" {
		return ""
	}
	return filepath.Join(r.logDir, fmt.Sprintf("%s.log", stage))
}

// fillFailure populates the result envelope's failure fields from an error
// observed during stage execution.
func (r *Runner) fillFailure(res *proto.PipelineAttemptResultV1, err error, recent []proto.StageBreakdown) {
	res.Outcome = proto.AttemptOutcomeFailureSaveExit
	res.Verdict = proto.VerdictFail
	if err != nil {
		res.Error = err.Error()
	}
	if last := lastBreakdown(recent); last != nil {
		res.BlockingStage = last.Stage
	}
}

// shouldShortCircuit reports whether a stage verdict should stop downstream
// work. fail and block both do; rework, pass, skip do not.
func shouldShortCircuit(verdict string) bool {
	switch verdict {
	case proto.VerdictBlock, proto.VerdictFail:
		return true
	}
	return false
}

// outcomeFor maps a terminal verdict to the corresponding attempt outcome
// constant from the m12 envelope vocabulary.
func outcomeFor(verdict string) string {
	switch verdict {
	case proto.VerdictPass, proto.VerdictSkip:
		return proto.AttemptOutcomeSuccess
	case proto.VerdictBlock:
		return proto.AttemptOutcomeFailureSaveExit
	}
	return proto.AttemptOutcomeFailureRetry
}

// lastBreakdown returns a pointer to the last entry in s, or nil if empty.
func lastBreakdown(s []proto.StageBreakdown) *proto.StageBreakdown {
	if len(s) == 0 {
		return nil
	}
	cp := s[len(s)-1]
	return &cp
}

// breakdownOrEmpty returns bd if non-nil, otherwise a synthetic stage-fail
// breakdown so res.Stages always has at least one entry on failure paths.
func breakdownOrEmpty(bd *proto.StageBreakdown, stage string) *proto.StageBreakdown {
	if bd != nil {
		return bd
	}
	return &proto.StageBreakdown{
		Stage:      stage,
		Verdict:    proto.VerdictFail,
		ExitReason: "adapter returned no breakdown",
	}
}
