package intake

import (
	"os"
	"path/filepath"

	pkgintake "github.com/geoffgodwin/tekhton/internal/intake"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// newVerdictHandler builds a VerdictHandler wired to in-process state,
// stdio, and the operator's session env. The PipelineState writer goes
// straight to internal/state.Store (no TSV sentinel — m36.3 inverts the
// call direction relative to the m36.2 transition shim).
func newVerdictHandler(cfg config, h *pkgintake.Helpers) *pkgintake.VerdictHandler {
	rules := cfg.ProjectRulesFile
	if rules == "" {
		rules = "CLAUDE.md"
	}

	return &pkgintake.VerdictHandler{
		H:                h,
		AutoSplit:        cfg.AutoSplit,
		ConfirmTweaks:    cfg.ConfirmTweaks,
		CompleteMode:     cfg.CompleteMode,
		MilestoneMode:    cfg.MilestoneMode,
		CurrentMs:        cfg.CurrentMilestone,
		Task:             cfg.Task,
		ProjectRulesFile: rules,
		PipelineState:    inProcessPipelineState(cfg),
		Split:            stubSplit,
		Switch:           stubSwitch,
		ClarifyHandle:    nil, // defaults to exec `tekhton clarify handle`
		TekhtonBin:       resolveTekhtonBin(),
		Stdin:            os.Stdin,
		Stdout:           os.Stdout,
		Stderr:           os.Stderr,
		IsStdinTTY:       isStdinTTY(),
		SizeGuardMinPct:  cfg.TweakMinSizePct,
	}
}

// inProcessPipelineState returns a PipelineStateWriter that updates the
// canonical state file via internal/state.Store. Mirrors the bash
// write_pipeline_state contract: stage, exit_reason, args, task, msg,
// milestone are written to the snapshot.
func inProcessPipelineState(cfg config) pkgintake.PipelineStateWriter {
	statePath := resolveStatePath(cfg)
	if statePath == "" {
		return nil
	}
	store := state.New(statePath)
	return func(stage, exitReason, args, task, msg, milestone string) error {
		return store.Update(func(snap *proto.StateSnapshotV1) {
			snap.ExitStage = stage
			snap.ExitReason = exitReason
			snap.ResumeTask = task
			snap.ResumeFlag = args
			snap.Notes = msg
			if milestone != "" {
				snap.MilestoneID = milestone
			}
		})
	}
}

func resolveStatePath(cfg config) string {
	override := os.Getenv("PIPELINE_STATE_FILE")
	if override != "" {
		if filepath.IsAbs(override) {
			return override
		}
		return filepath.Join(cfg.ProjectDir, override)
	}
	return filepath.Join(cfg.ProjectDir, cfg.TekhtonDir, "PIPELINE_STATE.json")
}

// stubSplit / stubSwitch are placeholders for the milestone-split CLI seams.
// SPLIT_RECOMMENDED in non-interactive mode falls through to the operator
// prompt; auto-split shells out to the bash helpers via the operator CLI.
// A future milestone replaces these with in-process internal/manifest calls.
func stubSplit(milestone, claudeMD string) error {
	_ = milestone
	_ = claudeMD
	return nil
}

func stubSwitch(milestone, claudeMD string) error {
	_ = milestone
	_ = claudeMD
	return nil
}

// isStdinTTY mirrors the bash `[[ -t 0 ]]` test.
func isStdinTTY() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) != 0
}
