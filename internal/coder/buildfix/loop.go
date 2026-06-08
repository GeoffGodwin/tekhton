package buildfix

import (
	"context"
	"fmt"
)

// LoopConfig aliases Config so callers reading a milestone-design term can
// see it land in code. The two are interchangeable at the Go level.
type LoopConfig = Config

// LoopResult is the orchestrator's return envelope from Run. Stats are
// populated on every exit path (ExportStats is the last step before a
// return); a terminal failure additionally sets StateExit so the m39.4
// orchestrator can persist pipeline state with the correct context.
type LoopResult struct {
	Outcome              Outcome
	Attempts             int
	TurnBudgetUsed       int
	ProgressGateFailures int
	Classification       Decision
	FinalProgress        Signal
	FinalDelta           string // "prev→new"
	SecondaryCause       *SecondaryCause
	StateExit            *StateExit
}

// StateExit captures the four fields the m39.4 orchestrator hands to
// state.WritePipelineState on terminal failure. Decoupled from env side
// effects so the loop body stays testable without subprocess plumbing.
type StateExit struct {
	Stage      string
	ExitReason string // "build_failure" | "env_failure"
	ResumeFlag string
	Task       string
	Notes      string
}

// Paths bundles the file paths the loop reads or writes. The m39.4
// orchestrator resolves them once from env; tests pass synthesized tmp
// paths.
type Paths struct {
	BuildRawErrorsFile   string
	BuildErrorsFile      string
	BuildRoutingDiagFile string
	BuildFixReportFile   string
	CoderModel           string
	AgentTools           string
	LogFile              string
	BaseResumeFlag       string
	Task                 string
}

// Run is the M128 continuation-loop entry point. Returns a populated
// LoopResult on every code path; the (Outcome, StateExit) pair tells the
// caller whether to exit, continue, or save resume state. The four Goal-7
// stats fields are always set before return.
func Run(ctx context.Context, cfg *LoopConfig, deps *Deps, paths *Paths) (*LoopResult, error) {
	if cfg == nil {
		cfg = &Config{}
	}
	if deps == nil {
		deps = &Deps{}
	}
	if paths == nil {
		paths = &Paths{}
	}
	applyLoopDefaults(cfg)
	applyDepsDefaults(deps)
	applyPathsDefaults(paths)

	result := &LoopResult{
		FinalProgress: SignalUnchanged,
		FinalDelta:    "n/a",
	}

	if !cfg.Enabled {
		warnf(deps, "BUILD_FIX_ENABLED=false — skipping build-fix continuation loop.")
		result.StateExit = &StateExit{
			Stage:      "coder",
			ExitReason: "build_failure",
			ResumeFlag: paths.BaseResumeFlag,
			Task:       paths.Task,
			Notes: fmt.Sprintf(
				"Build errors remain; build-fix loop disabled (BUILD_FIX_ENABLED=false). See %s.",
				paths.BuildErrorsFile),
		}
		errorf(deps, "State saved. Review %s manually then re-run.", paths.BuildErrorsFile)
		writeStats(result, OutcomeNotRun)
		return result, nil
	}

	rawErrors, err := deps.ReadRawErrors()
	if err != nil {
		warnf(deps, "Failed to read raw build errors: %v", err)
	}

	decision := deps.Classify(rawErrors)
	result.Classification = decision
	logf(deps, "Build-fix routing decision: %s", decision)

	if decision == DecisionNoncodeDominant {
		handleNoncodeDominant(ctx, deps, paths, rawErrors, result)
		writeStats(result, OutcomeNotRun)
		return result, nil
	}

	if decision == DecisionMixedUncertain && deps.EmitRoutingDiagnosis != nil {
		stats := ""
		if deps.ClassifyWithStats != nil {
			stats = deps.ClassifyWithStats(rawErrors)
		}
		if err := deps.EmitRoutingDiagnosis(paths.BuildRoutingDiagFile, stats); err != nil {
			warnf(deps, "Failed to write routing diagnosis: %v", err)
		}
	}

	switch decision {
	case DecisionCodeDominant, DecisionMixedUncertain, DecisionUnknownOnly:
		// known tokens fall through
	default:
		warnf(deps, "Build-fix loop received unrecognized routing token '%s'; treating as code_dominant.", decision)
	}

	extra := ExtraContextFor(decision, paths.BuildRoutingDiagFile)
	base := cfg.EffectiveCoderMaxTurns / cfg.BaseTurnDivisor
	if base < 8 {
		base = 8
	}

	prevCount, _ := deps.CountErrors(paths.BuildRawErrorsFile)
	prevTail, _ := deps.ErrorTail(paths.BuildRawErrorsFile)

	outcome := runAttempts(ctx, cfg, deps, paths, decision, extra, rawErrors,
		base, prevCount, prevTail, result)

	finalizeOutcome(ctx, deps, paths, outcome, result)
	return result, nil
}
