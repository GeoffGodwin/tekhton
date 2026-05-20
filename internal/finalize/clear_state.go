package finalize

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// ClearState is the Go body of _hook_clear_state. The bash hook removed
// MILESTONE_STATE.md on a successful milestone run (so the cleared state is
// included in the post-run commit). Pure Go because the milestone state file
// is a plain on-disk artifact — no notes/drift/dashboard subsystem
// dependencies remain.
type ClearState struct {
	// Path overrides the default milestone state file location.
	Path string
}

// Name implements Hook.
func (h *ClearState) Name() string { return "_hook_clear_state" }

// Run removes the milestone state file when the run was successful AND it
// was a milestone run AND the milestone reached a terminal disposition. The
// triple gate matches the bash version line-for-line; reordering or
// relaxing any one gate is a behavior change, not a port.
func (h *ClearState) Run(_ context.Context, in *Input) error {
	if !shouldRunOnCompletion(in) {
		return nil
	}
	path := h.Path
	if path == "" {
		path = filepath.Join(in.ProjectDir, ".claude", "MILESTONE_STATE.md")
	}
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("clear_state: remove %s: %w", path, err)
	}
	return nil
}

// shouldRunOnCompletion is the success+milestone-complete gate shared by
// clear_state / mark_done / cleanup_milestone. Centralized here so the
// three hooks branch identically — the bash side replicated the same gate
// in each function body and a single edit propagates to all three.
func shouldRunOnCompletion(in *Input) bool {
	if in.ExitCode != 0 {
		return false
	}
	if !in.MilestoneMode {
		return false
	}
	if in.Milestone == "" {
		return false
	}
	return isCompleteDisposition(in.MilestoneDisposition)
}

// isCompleteDisposition mirrors the bash check on _CACHED_DISPOSITION ==
// COMPLETE_AND_CONTINUE | COMPLETE_AND_WAIT.
func isCompleteDisposition(d string) bool {
	switch d {
	case "COMPLETE_AND_CONTINUE", "COMPLETE_AND_WAIT":
		return true
	}
	return false
}
