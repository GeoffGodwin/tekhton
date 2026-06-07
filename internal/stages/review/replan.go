package review

import (
	"context"
)

// replanDecision is the human-side outcome of the REPLAN_REQUIRED branch.
// Mirrors the four exit codes from lib/replan_midrun.sh::trigger_replan
// collapsed into the two outcomes the stage actually distinguishes: continue
// (with verdict overridden to APPROVED_WITH_NOTES) or abort (caller writes
// pipeline state and returns verdict=fail / replan_user_aborted).
type replanDecision int

const (
	replanContinue replanDecision = iota
	replanUserAborted
)

// ReplanRunner is the seam between the review stage and the interactive
// replan flow that lives in lib/replan_midrun.sh. Production wires a
// subprocess implementation that execs into bash; tests substitute a stub
// that returns the desired decision deterministically.
//
// Run is invoked when the reviewer emits REPLAN_REQUIRED and CLARIFICATION is
// in scope. Returns replanContinue or replanUserAborted; the caller maps the
// outcome onto the stage verdict.
type ReplanRunner interface {
	Run(ctx context.Context, projectDir, reportFile string) (replanDecision, error)
}

// defaultReplan is the package-level seam — defaults to aborting the run.
// The Go review stage is not the right place to host an interactive prompt;
// the production wedge keeps the bash-side trigger_replan logic available via
// a future shim, and the default here is "abort" so non-interactive Go-only
// callers fail closed rather than hang.
var replanRunner ReplanRunner = abortReplan{}

// SetReplanRunner replaces the package-level replan seam.
func SetReplanRunner(r ReplanRunner) ReplanRunner {
	prev := replanRunner
	replanRunner = r
	return prev
}

// triggerReplan is the per-stage entry point. The cycle-loop driver dispatches
// here on a REPLAN_REQUIRED verdict.
func triggerReplan(ctx context.Context, cfg *config, reportFile string) (replanDecision, error) {
	if replanRunner == nil {
		return replanUserAborted, nil
	}
	return replanRunner.Run(ctx, cfg.ProjectDir, reportFile)
}

// abortReplan is the default ReplanRunner — always returns replanUserAborted.
type abortReplan struct{}

func (abortReplan) Run(_ context.Context, _, _ string) (replanDecision, error) {
	return replanUserAborted, nil
}
