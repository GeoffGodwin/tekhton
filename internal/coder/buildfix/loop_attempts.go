package buildfix

import (
	"context"
	"fmt"
)

// runAttempts is the inner loop body. Updates result.Attempts /
// TurnBudgetUsed / ProgressGateFailures / FinalProgress / FinalDelta on
// each iteration. Returns the terminal Outcome; finalizeOutcome wires
// it into LoopResult.Outcome + StateExit on return.
func runAttempts(
	ctx context.Context,
	cfg *Config,
	deps *Deps,
	paths *Paths,
	decision Decision,
	extra, rawErrors string,
	base, prevCount int,
	prevTail string,
	result *LoopResult,
) Outcome {
	outcome := OutcomeExhausted

	for result.Attempts < cfg.MaxAttempts {
		result.Attempts++

		budget := ComputeBudget(result.Attempts, base, result.TurnBudgetUsed, *cfg)
		if budget == 0 {
			logf(deps, "Build-fix cumulative turn cap reached after %d turns; halting loop.", result.TurnBudgetUsed)
			result.Attempts--
			outcome = OutcomeExhausted
			break
		}

		logf(deps, "Build-fix attempt %d/%d (budget=%d turns, used=%d).",
			result.Attempts, cfg.MaxAttempts, budget, result.TurnBudgetUsed)

		exitCode, turns := invokeBuildFix(ctx, deps, paths, decision, extra, rawErrors, budget)
		result.TurnBudgetUsed += budget

		terminal := TerminalClass(exitCode, turns, budget)

		passed, gateErr := deps.RunBuildGate(ctx, fmt.Sprintf("post-coder-fix-%d", result.Attempts))
		if gateErr != nil {
			warnf(deps, "Build gate runner error: %v", gateErr)
		}

		if passed {
			newCount, _ := deps.CountErrors(paths.BuildRawErrorsFile)
			result.FinalDelta = fmt.Sprintf("%d→%d", prevCount, newCount)
			appendAttemptReport(deps, paths, result.Attempts, budget, terminal, "pass",
				SignalUnchanged, result.FinalDelta, decision, true)
			outcome = OutcomePassed
			break
		}

		newCount, _ := deps.CountErrors(paths.BuildRawErrorsFile)
		newTail, _ := deps.ErrorTail(paths.BuildRawErrorsFile)
		progress := ProgressSignal(prevCount, newCount, prevTail, newTail)
		result.FinalProgress = progress
		result.FinalDelta = fmt.Sprintf("%d→%d", prevCount, newCount)

		appendAttemptReport(deps, paths, result.Attempts, budget, terminal, "fail",
			progress, result.FinalDelta, decision, false)

		fresh, readErr := deps.ReadRawErrors()
		if readErr != nil {
			warnf(deps, "Failed to re-read raw build errors after attempt %d: %v", result.Attempts, readErr)
		} else {
			rawErrors = fresh
		}

		if cfg.RequireProgress && result.Attempts >= 2 &&
			(progress == SignalUnchanged || progress == SignalWorsened) {
			warnf(deps, "Build-fix halted early: no measurable progress after attempt %d.", result.Attempts)
			result.ProgressGateFailures++
			outcome = OutcomeNoProgress
			break
		}

		// M130 classification-required save_exit: mixed_uncertain attempts
		// run at most once when ClassificationRequired is true.
		if cfg.ClassificationRequired && decision == DecisionMixedUncertain && result.Attempts >= 1 {
			outcome = OutcomeExhausted
			break
		}

		prevCount = newCount
		prevTail = newTail
	}

	return outcome
}

// finalizeOutcome wires the loop's terminal Outcome into LoopResult:
// stats, secondary cause on failure paths, and StateExit notes.
func finalizeOutcome(ctx context.Context, deps *Deps, paths *Paths, outcome Outcome, result *LoopResult) {
	_ = ctx // reserved for future state-write hooks
	switch outcome {
	case OutcomePassed:
		writeStats(result, OutcomePassed)
		return
	case OutcomeNoProgress:
		writeStats(result, OutcomeNoProgress)
		result.SecondaryCause = &SecondaryCause{}
		SetSecondaryCause(result.SecondaryCause)
		errorf(deps, "Build gate failed after %d attempt(s); progress stalled.", result.Attempts)
		result.StateExit = &StateExit{
			Stage:      "coder",
			ExitReason: "build_failure",
			ResumeFlag: paths.BaseResumeFlag,
			Task:       paths.Task,
			Notes: fmt.Sprintf(
				"Build-fix loop halted after %d attempt(s) with no measurable progress. terminated_early_no_progress=true. Final progress=%s, delta=%s, classification=%s. See %s and %s.",
				result.Attempts, result.FinalProgress, result.FinalDelta, result.Classification,
				paths.BuildFixReportFile, paths.BuildErrorsFile),
		}
		errorf(deps, "State saved. Review %s and %s then re-run.", paths.BuildFixReportFile, paths.BuildErrorsFile)
	default:
		writeStats(result, OutcomeExhausted)
		result.SecondaryCause = &SecondaryCause{}
		SetSecondaryCause(result.SecondaryCause)
		errorf(deps, "Build gate failed after %d build-fix attempt(s).", result.Attempts)
		result.StateExit = &StateExit{
			Stage:      "coder",
			ExitReason: "build_failure",
			ResumeFlag: paths.BaseResumeFlag,
			Task:       paths.Task,
			Notes: fmt.Sprintf(
				"Build-fix loop exhausted %d attempt(s). Final progress=%s, delta=%s, classification=%s. See %s and %s.",
				result.Attempts, result.FinalProgress, result.FinalDelta, result.Classification,
				paths.BuildFixReportFile, paths.BuildErrorsFile),
		}
		errorf(deps, "State saved. Review %s and %s then re-run.", paths.BuildFixReportFile, paths.BuildErrorsFile)
	}
}

// writeStats is a thin wrapper that funnels every exit path through
// ExportStats. Keeps the four Goal-7 stats fields stable regardless of
// how the loop terminated.
func writeStats(result *LoopResult, outcome Outcome) {
	stats := &Stats{
		Attempts:             result.Attempts,
		TurnBudgetUsed:       result.TurnBudgetUsed,
		ProgressGateFailures: result.ProgressGateFailures,
	}
	ExportStats(stats, outcome)
	result.Outcome = stats.Outcome
}
