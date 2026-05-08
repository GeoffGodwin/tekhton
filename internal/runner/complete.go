package runner

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// loopState carries per-iteration counters that mirror the bash _ORCH_*
// globals from lib/orchestrate_main.sh. Kept inside RunCompleteLoop so a
// caller doesn't have to manage them explicitly; tests substitute counters
// via Runner fields and assert the persisted RunResult.
type loopState struct {
	attempt        int
	agentCalls     int
	totalTurns     int
	noProgressHits int
	startedAt      time.Time
}

// RunCompleteLoop drives the outer retry loop — the --complete-mode path.
// Direct port of run_complete_loop from lib/orchestrate_main.sh. Each
// iteration calls Pipeline.RunAttempt; the loop applies safety bounds,
// progress detection, milestone-acceptance shell-out, and writes
// PIPELINE_STATE.json on terminal exits via state.Store.
//
// The bash front-end's recovery dispatch (bump_review, retry_coder_build,
// retry_ui_gate_env, escalate_turns, split, save_exit) is mirrored here only
// to the extent of "retry vs save_exit": detailed classification stays in
// internal/orchestrate.Classify (m12), which the pipeline runner already
// invokes. RunCompleteLoop's job is to bound the number of attempts and to
// hand control back to bash for finalize when the loop terminates.
func (r *Runner) RunCompleteLoop(ctx context.Context, req *proto.RunRequestV1) (*proto.RunResultV1, error) {
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

	maxAttempts, timeoutSecs, maxCalls := r.effectiveBounds(req)

	st := loopState{startedAt: r.Now()}
	res := &proto.RunResultV1{
		Proto: proto.RunResultProtoV1,
	}

	var loopErr error
loop:
	for {
		if err := ctx.Err(); err != nil {
			res.Disposition = proto.RunDispositionFailure
			res.ErrorMessage = "context canceled"
			loopErr = err
			break loop
		}

		st.attempt++
		elapsed := int64(r.Now().Sub(st.startedAt).Seconds())

		if timeoutSecs > 0 && elapsed >= int64(timeoutSecs) {
			res.Disposition = proto.RunDispositionTimeout
			res.Recovery = "save_exit"
			res.ErrorMessage = fmt.Sprintf("autonomous_timeout reached (%ds)", timeoutSecs)
			loopErr = ErrSafetyBound
			st.attempt--
			break loop
		}

		if maxAttempts > 0 && st.attempt > maxAttempts {
			res.Disposition = proto.RunDispositionFailure
			res.Recovery = "save_exit"
			res.ErrorMessage = fmt.Sprintf("max_pipeline_attempts reached (%d)", maxAttempts)
			loopErr = ErrSafetyBound
			st.attempt--
			break loop
		}

		if maxCalls > 0 && st.agentCalls >= maxCalls {
			res.Disposition = proto.RunDispositionAgentCap
			res.Recovery = "save_exit"
			res.ErrorMessage = fmt.Sprintf("max_autonomous_agent_calls reached (%d)", maxCalls)
			loopErr = ErrSafetyBound
			st.attempt--
			break loop
		}

		pipeReq := r.buildPipelineRequest(req)
		pipeRes, pipeErr := r.Pipeline.RunAttempt(ctx, pipeReq)

		if pipeRes != nil {
			st.agentCalls += pipeRes.AgentCalls
		}

		if pipeErr != nil {
			res.Disposition = proto.RunDispositionFailure
			res.Recovery = "save_exit"
			res.ErrorMessage = pipeErr.Error()
			loopErr = pipeErr
			break loop
		}
		if pipeRes == nil {
			res.Disposition = proto.RunDispositionFailure
			res.ErrorMessage = "pipeline returned no result"
			loopErr = errors.New("nil pipeline result")
			break loop
		}

		if pipeRes.Outcome == proto.AttemptOutcomeSuccess {
			accepted := true
			if r.Acceptance != nil && req.Milestone != "" {
				ok, err := r.Acceptance.Check(ctx, req.Milestone)
				if err != nil {
					fmt.Fprintln(r.Stderr, "runner: acceptance check error:", err)
				}
				accepted = ok
			}
			if accepted {
				res.Disposition = proto.RunDispositionSuccess
				break loop
			}
			st.noProgressHits++
			if st.noProgressHits >= 2 {
				res.Disposition = proto.RunDispositionStuck
				res.Recovery = "save_exit"
				res.ErrorMessage = "acceptance failed twice in a row"
				loopErr = ErrStuck
				break loop
			}
			continue
		}

		// Failure path. Per the milestone, RunCompleteLoop only iterates on
		// "retry"-class outcomes; "save_exit"-class outcomes terminate.
		// internal/pipeline.Runner already maps the per-attempt verdicts to
		// AttemptOutcomeFailureRetry vs AttemptOutcomeFailureSaveExit.
		if pipeRes.Outcome == proto.AttemptOutcomeFailureRetry {
			st.noProgressHits = 0
			continue
		}

		// failure_save_exit and any unrecognized outcome.
		res.Disposition = proto.RunDispositionFailure
		res.Recovery = "save_exit"
		res.ErrorMessage = pipeRes.Error
		res.ErrorClass = pipeRes.BlockingStage
		break loop
	}

	res.Attempts = st.attempt
	res.AgentCalls = st.agentCalls
	res.ElapsedSecs = int64(r.Now().Sub(st.startedAt).Seconds())

	if res.Disposition != proto.RunDispositionSuccess {
		r.persistFailureState(req, res)
	} else if r.State != nil {
		_ = r.State.Clear()
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

	return res, loopErr
}

// persistFailureState writes the orchestration counters into PIPELINE_STATE
// so a subsequent --resume picks up where we left off. Mirrors the bash
// _save_orchestration_state writer in lib/orchestrate_state.sh — but goes
// through the m03 Go state.Store rather than bash heredoc.
func (r *Runner) persistFailureState(req *proto.RunRequestV1, res *proto.RunResultV1) {
	if r.State == nil {
		return
	}
	flags := buildResumeFlags(req)
	res.ResumeFlags = flags
	if res.ResumeStartAt == "" {
		res.ResumeStartAt = "coder"
	}

	err := r.State.Update(func(snap *proto.StateSnapshotV1) {
		snap.EnsureProto()
		snap.ResumeTask = req.Task
		snap.ResumeFlag = flags
		snap.ExitStage = res.ResumeStartAt
		snap.ExitReason = "complete_loop_" + res.Disposition
		snap.MilestoneID = req.Milestone
		// Safety-bound exits zero the counters so the next invocation has a
		// fresh budget — mirrors the bash _save_orchestration_state branch.
		switch res.Disposition {
		case proto.RunDispositionTimeout, proto.RunDispositionAgentCap:
			snap.PipelineAttempt = 0
			snap.AgentCallsTotal = 0
		default:
			snap.PipelineAttempt = res.Attempts
			snap.AgentCallsTotal = res.AgentCalls
		}
		if res.ErrorMessage != "" {
			snap.Notes = res.ErrorMessage
		}
	})
	if err != nil {
		fmt.Fprintln(r.Stderr, "runner: persist state:", err)
	}
}

// buildResumeFlags mirrors lib/state.sh::_build_resume_flag for the run-flag
// surface. The bash entry point is still the canonical reader; we emit the
// same string so `tekhton.sh --resume` keeps working.
func buildResumeFlags(req *proto.RunRequestV1) string {
	flag := "--complete"
	switch req.Mode {
	case proto.RunModeMilestone:
		flag = "--complete --milestone"
	case proto.RunModeHuman:
		flag = "--human"
		if req.HumanTag != "" {
			flag += " " + req.HumanTag
		}
	}
	return flag + " --start-at coder"
}
