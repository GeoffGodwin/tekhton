package finalize

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

func TestMarkDone_SetsManifestStatusDoneOnCompleteContinue(t *testing.T) {
	dir := t.TempDir()
	manifestPath := filepath.Join(dir, ".claude", "milestones", "MANIFEST.cfg")
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
		t.Fatal(err)
	}
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|Finalize Orchestrator Port|todo||m21-finalize-orchestrator-port.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	writeCommitDecision(t, dir, "committed")
	h := &MarkDone{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("MarkDone.Run: %v", err)
	}

	m, err := manifest.Load(manifestPath)
	if err != nil {
		t.Fatalf("manifest.Load: %v", err)
	}
	entry, ok := m.Get("m21")
	if !ok {
		t.Fatalf("entry m21 missing from manifest")
	}
	if entry.Status != "done" {
		t.Errorf("entry.Status = %q, want %q", entry.Status, "done")
	}
}

func TestMarkDone_NoopOnFailure(t *testing.T) {
	dir := t.TempDir()
	manifestPath := filepath.Join(dir, ".claude", "milestones", "MANIFEST.cfg")
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
		t.Fatal(err)
	}
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|t|todo||f.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &MarkDone{}
	in := &Input{
		ExitCode:             1,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("MarkDone.Run: %v", err)
	}
	m, err := manifest.Load(manifestPath)
	if err != nil {
		t.Fatalf("manifest.Load: %v", err)
	}
	entry, _ := m.Get("m21")
	if entry.Status == "done" {
		t.Errorf("should not mark done on failure")
	}
}

func TestMarkDone_NoopWhenManifestMissing(t *testing.T) {
	dir := t.TempDir()
	h := &MarkDone{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Errorf("missing manifest should not error; got %v", err)
	}
}

func TestMarkDone_Idempotent(t *testing.T) {
	dir := t.TempDir()
	manifestPath := filepath.Join(dir, ".claude", "milestones", "MANIFEST.cfg")
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
		t.Fatal(err)
	}
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|t|done||f.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	writeCommitDecision(t, dir, "committed")
	h := &MarkDone{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Errorf("idempotent re-mark should not error; got %v", err)
	}
}

// TestMarkDone_GatedByCommitDecisionSentinel locks in the 2026-05 fix:
// when the user declines the commit prompt (sentinel = "declined"), the
// manifest must NOT be mutated even though everything else looks like a
// successful completion. Without this gate, `tekhton --milestone m23`
// after a declined commit silently turned into a no-op coder run
// (regression that ate 5+ hollow runs before being root-caused).
func TestMarkDone_GatedByCommitDecisionSentinel(t *testing.T) {
	cases := []struct {
		name     string
		decision string
		wantMark bool
	}{
		{"committed_marks_done", "committed", true},
		{"declined_does_not_mark", "declined", false},
		{"skipped_does_not_mark", "skipped", false},
		{"missing_sentinel_does_not_mark", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			manifestPath := filepath.Join(dir, ".claude", "milestones", "MANIFEST.cfg")
			if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
				t.Fatal(err)
			}
			content := "# Tekhton Milestone Manifest v1\n" +
				"# id|title|status|depends_on|file|parallel_group\n" +
				"m21|t|todo||f.md|\n"
			if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
			if tc.decision != "" {
				writeCommitDecision(t, dir, tc.decision)
			}
			h := &MarkDone{}
			in := &Input{
				ExitCode:             0,
				ProjectDir:           dir,
				Milestone:            "m21",
				MilestoneMode:        true,
				MilestoneDisposition: "COMPLETE_AND_CONTINUE",
			}
			if err := h.Run(context.Background(), in); err != nil {
				t.Fatalf("MarkDone.Run: %v", err)
			}
			m, _ := manifest.Load(manifestPath)
			entry, _ := m.Get("m21")
			got := entry.Status == "done"
			if got != tc.wantMark {
				t.Errorf("decision=%q: marked done? got %v, want %v", tc.decision, got, tc.wantMark)
			}
		})
	}
}

// writeCommitDecision writes the .tekhton/.commit_decision sentinel the
// shouldRunOnCompletion gate reads. Test helper because three test files
// (mark_done, cleanup_milestone, clear_state) all need the same setup.
func writeCommitDecision(t *testing.T, projectDir, decision string) {
	t.Helper()
	tekhtonDir := filepath.Join(projectDir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tekhtonDir, ".commit_decision"),
		[]byte(decision+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}
