package coder

import (
	"context"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestHandlerRespectsMaxSplitDepth asserts the
// MILESTONE_MAX_SPLIT_DEPTH=3 bound. With GetSplitDepth returning 3, the
// handler must NOT recurse — it saves state and exits.
func TestHandlerRespectsMaxSplitDepth(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MilestoneMode = true
	cfg.MaxSplitDepth = 3
	cfg.CurrentMilestone = "39.4"

	var splitCalled, stateWritten bool
	deps := &Deps{
		GetSplitDepth: func(string) int { return 3 }, // already at cap
		HandleNullRunSplit: func(ctx context.Context, _ string) (bool, error) {
			splitCalled = true
			return true, nil
		},
		WritePipelineState: func(stage, exitReason, _, _, _ string) error {
			stateWritten = true
			if stage != "coder" {
				t.Errorf("state stage = %q; want coder", stage)
			}
			if exitReason != "null_run" {
				t.Errorf("state exit_reason = %q; want null_run", exitReason)
			}
			return nil
		},
	}

	o := newOrchestrator(&proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "t",
		ResultFile: "/dev/null",
	}).withConfig(cfg).withDeps(deps)

	h := newNullRunHandler(o)
	res, err := h.Handle(context.Background(), EscalationNullRun, EscalationInfo{
		Milestone: cfg.CurrentMilestone, LastAgentTurns: 1,
	})
	if err != nil {
		t.Fatalf("Handle err = %v", err)
	}
	if splitCalled {
		t.Error("split called despite being at MaxSplitDepth")
	}
	if !stateWritten {
		t.Error("state not written despite at-cap path")
	}
	if !res.ShouldExit {
		t.Errorf("ShouldExit = false; want true")
	}
	if res.ShouldRetry {
		t.Errorf("ShouldRetry = true; want false")
	}
	if res.ExitReason != "null_run" {
		t.Errorf("ExitReason = %q; want null_run", res.ExitReason)
	}
}

// TestHandlerSplitsUnderDepth asserts that when depth < MaxSplitDepth AND
// a split is possible, the handler returns ShouldRetry=true (don't save
// state, recurse into Run).
func TestHandlerSplitsUnderDepth(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MilestoneMode = true
	cfg.CurrentMilestone = "39.4"

	var splitCalled bool
	deps := &Deps{
		GetSplitDepth: func(string) int { return 1 }, // under cap
		HandleNullRunSplit: func(ctx context.Context, _ string) (bool, error) {
			splitCalled = true
			return true, nil
		},
		SwitchToSubMilestone: func(string) (string, error) { return "39.4.1", nil },
	}
	o := newOrchestrator(&proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "t",
		ResultFile: "/dev/null",
	}).withConfig(cfg).withDeps(deps)

	h := newNullRunHandler(o)
	res, err := h.Handle(context.Background(), EscalationNullRun, EscalationInfo{
		Milestone: cfg.CurrentMilestone,
	})
	if err != nil {
		t.Fatalf("Handle err = %v", err)
	}
	if !splitCalled {
		t.Errorf("split not called despite under-cap path")
	}
	if !res.ShouldRetry {
		t.Errorf("ShouldRetry = false; want true")
	}
	if res.ShouldExit {
		t.Errorf("ShouldExit = true; want false")
	}
}

// TestHandlerMissingButSubstantive_Reconstructs covers the EscalationKind
// that should NOT save state — it reconstructs and trips the commit gate
// so the orchestrator proceeds to review.
func TestHandlerMissingButSubstantive_Reconstructs(t *testing.T) {
	dir := t.TempDir()
	cfg := DefaultConfig()
	cfg.CoderSummaryFile = dir + "/summary.md"

	var commitTripped bool
	deps := &Deps{
		TripCommitGate: func(_ string) { commitTripped = true },
		GitTrackedNameOnly: func() (string, error) { return "a.go", nil },
		GitDiffStat:        func() (string, error) { return "a.go | 1 +", nil },
		GitUntrackedFiles:  func() (string, error) { return "", nil },
	}
	o := newOrchestrator(&proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "t",
		ResultFile: "/dev/null",
	}).withConfig(cfg).withDeps(deps)

	h := newNullRunHandler(o)
	res, err := h.Handle(context.Background(), EscalationMissingButSubstantive, EscalationInfo{})
	if err != nil {
		t.Fatalf("Handle err = %v", err)
	}
	if !commitTripped {
		t.Errorf("commit gate not tripped")
	}
	if res.ShouldRetry || res.ShouldExit {
		t.Errorf("MissingButSubstantive: should NOT retry or exit; got %+v", res)
	}
}

// TestHandlerUnknownKindFails covers the default branch.
func TestHandlerUnknownKindFails(t *testing.T) {
	o := newOrchestrator(&proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "t",
		ResultFile: "/dev/null",
	})
	h := newNullRunHandler(o)
	res, err := h.Handle(context.Background(), EscalationKind(999), EscalationInfo{})
	if err != nil {
		t.Fatalf("Handle err = %v", err)
	}
	if !res.ShouldExit || res.ExitReason != "unknown_escalation" {
		t.Errorf("unknown kind: got %+v", res)
	}
}

// TestHandlerTurnExhaustionSavesFailedSummary covers the FAILED-reconstruct
// path on the turn-exhaustion branch.
func TestHandlerTurnExhaustionSavesFailedSummary(t *testing.T) {
	dir := t.TempDir()
	cfg := DefaultConfig()
	cfg.CoderSummaryFile = dir + "/summary.md"

	var stateExitReason string
	deps := &Deps{
		GitTrackedNameOnly: func() (string, error) { return "a.go", nil },
		GitDiffStat:        func() (string, error) { return "stat", nil },
		GitUntrackedFiles:  func() (string, error) { return "", nil },
		WritePipelineState: func(_, reason, _, _, _ string) error {
			stateExitReason = reason
			return nil
		},
	}
	o := newOrchestrator(&proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "t",
		ResultFile: "/dev/null",
	}).withConfig(cfg).withDeps(deps)

	h := newNullRunHandler(o)
	res, err := h.Handle(context.Background(), EscalationTurnExhaustion, EscalationInfo{
		LastAgentTurns: 80,
	})
	if err != nil {
		t.Fatalf("Handle err = %v", err)
	}
	if stateExitReason != "turn_exhaustion_no_output" {
		t.Errorf("state exit_reason = %q; want turn_exhaustion_no_output", stateExitReason)
	}
	if !res.ShouldExit {
		t.Errorf("ShouldExit = false; want true")
	}
}
