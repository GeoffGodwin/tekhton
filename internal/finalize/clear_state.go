package finalize

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
//
// Fourth gate (added 2026-05): the user must have actually committed.
// _hook_commit writes `.tekhton/.commit_decision` with value "committed"
// (or "declined") after the prompt; these three hooks now run AFTER
// _hook_commit and skip when the sentinel says "declined" or is absent.
// Without this gate, a declined prompt would leave the manifest marked
// done with no commit to back it up — and the next `tekhton --milestone
// m23` run would produce a no-op coder because m23 was already "done."
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
	if !isCompleteDisposition(in.MilestoneDisposition) {
		return false
	}
	return commitWasApproved(in)
}

// commitWasApproved reads the `.tekhton/.commit_decision` sentinel that
// _hook_commit writes. Missing sentinel → false (e.g. AUTO_COMMIT=false
// and the user never reached the prompt because of an earlier crash, or
// _hook_commit was bypassed entirely). Value "committed" → true; anything
// else (including "declined", "skipped", or empty) → false.
//
// Read lives here rather than helpers.go so callers can grep for the
// sentinel name in one place when debugging "why didn't mark_done fire."
func commitWasApproved(in *Input) bool {
	dir := tekhtonDir(in)
	b, err := os.ReadFile(filepath.Join(dir, ".commit_decision"))
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(b)) == "committed"
}

// tekhtonDir resolves TEKHTON_DIR relative to the project (default
// ".tekhton"). Matches the bash convention used by trip_commit_gate and
// the rest of the finalize chain.
func tekhtonDir(in *Input) string {
	if v := os.Getenv("TEKHTON_DIR"); v != "" {
		if filepath.IsAbs(v) {
			return v
		}
		return filepath.Join(in.ProjectDir, v)
	}
	return filepath.Join(in.ProjectDir, ".tekhton")
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
