package finalize

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestClearState_RemovesMilestoneStateOnCompleteContinue(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, ".claude", "MILESTONE_STATE.md")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte("dummy"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeCommitDecision(t, dir, "committed")

	h := &ClearState{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ClearState.Run: %v", err)
	}
	if _, err := os.Stat(statePath); !os.IsNotExist(err) {
		t.Errorf("expected MILESTONE_STATE.md to be removed; stat err=%v", err)
	}
}

func TestClearState_SkipsWhenExitCodeNonZero(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, ".claude", "MILESTONE_STATE.md")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte("dummy"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &ClearState{}
	in := &Input{
		ExitCode:             1,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ClearState.Run: %v", err)
	}
	if _, err := os.Stat(statePath); err != nil {
		t.Errorf("expected MILESTONE_STATE.md to remain on failure; stat err=%v", err)
	}
}

func TestClearState_SkipsWhenDispositionNotComplete(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, ".claude", "MILESTONE_STATE.md")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte("dummy"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &ClearState{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "IN_PROGRESS",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ClearState.Run: %v", err)
	}
	if _, err := os.Stat(statePath); err != nil {
		t.Errorf("expected MILESTONE_STATE.md to remain on partial; stat err=%v", err)
	}
}

func TestClearState_NoopWhenFileMissing(t *testing.T) {
	dir := t.TempDir()
	h := &ClearState{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_WAIT",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Errorf("expected no error when state file missing; got %v", err)
	}
}

func TestClearState_Name(t *testing.T) {
	h := &ClearState{}
	if got := h.Name(); got != "_hook_clear_state" {
		t.Errorf("Name() = %q, want %q", got, "_hook_clear_state")
	}
}

func TestClearState_RemovesOnCompleteAndWait(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, ".claude", "MILESTONE_STATE.md")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte("pending"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeCommitDecision(t, dir, "committed")
	h := &ClearState{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_WAIT",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ClearState.Run: %v", err)
	}
	if _, err := os.Stat(statePath); !os.IsNotExist(err) {
		t.Errorf("expected MILESTONE_STATE.md removed on COMPLETE_AND_WAIT; stat err=%v", err)
	}
}

// TestClearState_GatedByCommitDecisionSentinel covers the 2026-05 fix:
// MILESTONE_STATE.md must survive when the commit prompt was declined
// — otherwise a re-run loses the state record of where the previous
// run got to.
func TestClearState_GatedByCommitDecisionSentinel(t *testing.T) {
	for _, decision := range []string{"declined", "skipped", ""} {
		t.Run("decision="+decision, func(t *testing.T) {
			dir := t.TempDir()
			statePath := filepath.Join(dir, ".claude", "MILESTONE_STATE.md")
			if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(statePath, []byte("pending"), 0o644); err != nil {
				t.Fatal(err)
			}
			if decision != "" {
				writeCommitDecision(t, dir, decision)
			}
			h := &ClearState{}
			in := &Input{
				ExitCode:             0,
				ProjectDir:           dir,
				Milestone:            "m21",
				MilestoneMode:        true,
				MilestoneDisposition: "COMPLETE_AND_CONTINUE",
			}
			if err := h.Run(context.Background(), in); err != nil {
				t.Fatalf("ClearState.Run: %v", err)
			}
			if _, err := os.Stat(statePath); err != nil {
				t.Errorf("decision=%q: MILESTONE_STATE.md should survive; stat err=%v", decision, err)
			}
		})
	}
}

// TestClearState_NoopWhenFileIsMissing_SentinelPresent directly exercises the
// os.IsNotExist branch at clear_state.go:37-39. The sentinel must say
// "committed" so shouldRunOnCompletion returns true and execution actually
// reaches the os.Remove call — without the sentinel the early-return at the
// commitWasApproved gate shadows the missing-file branch entirely.
func TestClearState_NoopWhenFileIsMissing_SentinelPresent(t *testing.T) {
	dir := t.TempDir()
	// Write sentinel so all gates in shouldRunOnCompletion pass.
	writeCommitDecision(t, dir, "committed")
	// Deliberately do NOT create .claude/MILESTONE_STATE.md.
	h := &ClearState{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Errorf("expected nil when state file missing; got %v", err)
	}
}

func TestClearState_SkipsWhenNotMilestoneMode(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, ".claude", "MILESTONE_STATE.md")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte("pending"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &ClearState{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        false, // not milestone mode
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ClearState.Run: %v", err)
	}
	if _, err := os.Stat(statePath); err != nil {
		t.Errorf("expected MILESTONE_STATE.md to remain when not in milestone mode; stat err=%v", err)
	}
}
