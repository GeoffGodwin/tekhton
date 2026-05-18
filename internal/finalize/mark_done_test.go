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
