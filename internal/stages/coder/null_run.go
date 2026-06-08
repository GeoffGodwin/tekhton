package coder

import (
	"context"
	"fmt"
)

// EscalationKind names a null-run escalation path. The orchestrator passes
// one of these to Handler.Handle to drive the correct branch.
type EscalationKind int

const (
	// EscalationNullRun — the agent died before doing meaningful work
	// (was_null_run returned true). Mirrors stages/coder.sh:753.
	EscalationNullRun EscalationKind = iota

	// EscalationTurnExhaustion — the agent used all its turns but produced
	// no CODER_SUMMARY.md and no substantive tracked/untracked changes.
	// Mirrors stages/coder.sh:806.
	EscalationTurnExhaustion

	// EscalationContinuationExhausted — the M14 continuation loop hit
	// MAX_CONTINUATION_ATTEMPTS without producing a COMPLETE status.
	// Mirrors stages/coder.sh:1031.
	EscalationContinuationExhausted

	// EscalationMissingButSubstantive — the agent did substantive work
	// but failed to produce or maintain CODER_SUMMARY.md. The orchestrator
	// reconstructs from git state, trips the commit gate, and proceeds.
	// Mirrors stages/coder.sh:802-805.
	EscalationMissingButSubstantive
)

// EscalationInfo carries the per-call inputs the handler needs.
type EscalationInfo struct {
	Milestone   string
	LastAgentTurns int
	LastAgentExit  int
}

// EscalationResult names the handler's terminal disposition. The
// orchestrator branches on (ShouldRetry, ShouldExit):
//
//   - ShouldRetry=true: re-invoke run_stage_coder for the new sub-milestone.
//     ShouldExit and ExitReason are unset on this path.
//   - ShouldExit=true: state was saved; the orchestrator returns failResult.
//   - Both false: handler reconstructed the summary; orchestrator proceeds.
type EscalationResult struct {
	ShouldRetry bool
	ShouldExit  bool
	ExitReason  string
	StateNotes  string
}

// Handler owns the three escalation paths. The orchestrator constructs one
// per Run invocation; the recursive auto-split path bounded by
// Config.MaxSplitDepth lives in the handler so it can be unit-tested
// without a full pipeline.
type Handler struct {
	o     *orchestrator
	depth int
}

// newNullRunHandler returns a handler bound to the orchestrator's Config
// (which carries MaxSplitDepth) and Deps (the split + state-write seams).
func newNullRunHandler(o *orchestrator) *Handler {
	return &Handler{o: o}
}

// Handle dispatches to the correct escalation path. Reads the orchestrator's
// dependencies for the split + state-write helpers; bounded recursion is
// enforced via Config.MaxSplitDepth.
//
// The bash version inlines the recursion via `run_stage_coder` calls; the Go
// port lifts the recursion bound to the handler so the orchestrator's Run
// remains linear and the auto-split branch is testable in isolation.
func (h *Handler) Handle(ctx context.Context, kind EscalationKind, info EscalationInfo) (*EscalationResult, error) {
	switch kind {
	case EscalationNullRun:
		return h.handleNullRun(ctx, info)
	case EscalationTurnExhaustion:
		return h.handleTurnExhaustion(ctx, info)
	case EscalationContinuationExhausted:
		return h.handleContinuationExhausted(ctx, info)
	case EscalationMissingButSubstantive:
		return h.handleMissingButSubstantive(ctx, info)
	default:
		return &EscalationResult{
			ShouldExit: true,
			ExitReason: "unknown_escalation",
			StateNotes: fmt.Sprintf("unknown escalation kind %d", kind),
		}, nil
	}
}

// handleNullRun ports stages/coder.sh:753-792. Attempts auto-split in
// milestone mode; otherwise saves state and exits.
func (h *Handler) handleNullRun(ctx context.Context, info EscalationInfo) (*EscalationResult, error) {
	if h.canSplit(info.Milestone) {
		ok, err := h.attemptSplit(ctx, info.Milestone)
		if err != nil {
			return nil, err
		}
		if ok {
			return &EscalationResult{ShouldRetry: true}, nil
		}
	}
	notes := fmt.Sprintf(
		"Agent used %d turn(s) and exited %d. Likely died during initial file discovery. "+
			"Consider: narrower task description, adding a SCOUT_REPORT manually, or checking agent logs.",
		info.LastAgentTurns, info.LastAgentExit)
	if h.o.deps.WritePipelineState != nil {
		_ = h.o.deps.WritePipelineState("coder", "null_run", h.buildResumeFlag(), h.o.req.Task, notes)
	}
	return &EscalationResult{
		ShouldExit: true,
		ExitReason: "null_run",
		StateNotes: notes,
	}, nil
}

// handleTurnExhaustion ports stages/coder.sh:806-844. Tries auto-split first;
// falls back to FAILED reconstruct + state save.
func (h *Handler) handleTurnExhaustion(ctx context.Context, info EscalationInfo) (*EscalationResult, error) {
	if h.canSplit(info.Milestone) {
		ok, err := h.attemptSplit(ctx, info.Milestone)
		if err != nil {
			return nil, err
		}
		if ok {
			return &EscalationResult{ShouldRetry: true}, nil
		}
	}
	_ = h.o.reconstructSummary("FAILED")
	notes := fmt.Sprintf(
		"Coder used %d turns but produced no output. Likely spent turns exploring without "+
			"implementing. Consider: narrower task, manual scout report, or milestone split.",
		info.LastAgentTurns)
	if h.o.deps.WritePipelineState != nil {
		_ = h.o.deps.WritePipelineState("coder", "turn_exhaustion_no_output",
			h.buildResumeFlag(), h.o.req.Task, notes)
	}
	return &EscalationResult{
		ShouldExit: true,
		ExitReason: "turn_exhaustion_no_output",
		StateNotes: notes,
	}, nil
}

// handleContinuationExhausted ports stages/coder.sh:1031-1046.
func (h *Handler) handleContinuationExhausted(ctx context.Context, info EscalationInfo) (*EscalationResult, error) {
	if h.canSplit(info.Milestone) {
		ok, err := h.attemptSplit(ctx, info.Milestone)
		if err != nil {
			return nil, err
		}
		if ok {
			return &EscalationResult{ShouldRetry: true}, nil
		}
	}
	notes := "Coder exhausted all continuation attempts. Likely too-broad scope; consider splitting."
	if h.o.deps.WritePipelineState != nil {
		_ = h.o.deps.WritePipelineState("coder", "continuation_exhausted",
			h.buildResumeFlag(), h.o.req.Task, notes)
	}
	return &EscalationResult{
		ShouldExit: true,
		ExitReason: "continuation_exhausted",
		StateNotes: notes,
	}, nil
}

// handleMissingButSubstantive ports stages/coder.sh:802-805. Reconstructs the
// summary from git state and trips the commit gate so the synthesize-fallback
// path doesn't rubber-stamp a COMPLETE-looking SUMMARY.
func (h *Handler) handleMissingButSubstantive(_ context.Context, _ EscalationInfo) (*EscalationResult, error) {
	_ = h.o.reconstructSummary("COMPLETE")
	if h.o.deps.TripCommitGate != nil {
		reason := "coder_did_not_produce_summary"
		if h.o.cfg.CurrentMilestone != "" {
			reason = fmt.Sprintf("milestone_block_unavailable_%s", h.o.cfg.CurrentMilestone)
		}
		_ = reason // reserved for the future m46 commit-gate plumb-through
		h.o.deps.TripCommitGate("coder_did_not_produce_summary")
	}
	// Reconstructed — orchestrator proceeds to review.
	return &EscalationResult{}, nil
}

// canSplit returns true when milestone mode is on AND the current depth is
// below MaxSplitDepth.
func (h *Handler) canSplit(milestone string) bool {
	if !h.o.cfg.MilestoneMode || milestone == "" {
		return false
	}
	if h.o.deps.GetSplitDepth != nil {
		depth := h.o.deps.GetSplitDepth(milestone)
		if depth >= h.o.cfg.MaxSplitDepth {
			return false
		}
		h.depth = depth
	}
	return h.o.deps.HandleNullRunSplit != nil
}

// attemptSplit drives the split helper. Returns true when the split
// succeeded and the orchestrator should re-run.
func (h *Handler) attemptSplit(ctx context.Context, milestone string) (bool, error) {
	if h.o.deps.HandleNullRunSplit == nil {
		return false, nil
	}
	ok, err := h.o.deps.HandleNullRunSplit(ctx, milestone)
	if err != nil || !ok {
		return false, err
	}
	if h.o.deps.SwitchToSubMilestone != nil {
		_, _ = h.o.deps.SwitchToSubMilestone(milestone)
	}
	return true, nil
}

// buildResumeFlag is the Go equivalent of `_build_resume_flag coder` —
// returns the --start-at coder argv fragment used by the state writer.
func (h *Handler) buildResumeFlag() string {
	if h.o.cfg.MilestoneMode {
		return "--milestone --start-at coder"
	}
	return "--start-at coder"
}
