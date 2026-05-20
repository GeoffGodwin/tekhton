package finalize

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

func TestCleanupMilestone_RemovesFileOnCompleteContinue(t *testing.T) {
	dir := t.TempDir()
	milestoneDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestoneDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestoneDir, "MANIFEST.cfg")
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|Finalize Orchestrator Port|done||m21-body.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	bodyPath := filepath.Join(milestoneDir, "m21-body.md")
	if err := os.WriteFile(bodyPath, []byte("# m21 — body\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &CleanupMilestone{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("CleanupMilestone.Run: %v", err)
	}
	if _, err := os.Stat(bodyPath); !os.IsNotExist(err) {
		t.Errorf("expected milestone file to be removed; stat err = %v", err)
	}
	// Manifest itself should not be touched.
	if _, err := os.Stat(manifestPath); err != nil {
		t.Errorf("manifest should be preserved; got %v", err)
	}
}

func TestCleanupMilestone_NoopWhenStatusNotDone(t *testing.T) {
	dir := t.TempDir()
	milestoneDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestoneDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestoneDir, "MANIFEST.cfg")
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|t|todo||m21-body.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	bodyPath := filepath.Join(milestoneDir, "m21-body.md")
	if err := os.WriteFile(bodyPath, []byte("body"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &CleanupMilestone{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(bodyPath); err != nil {
		t.Errorf("file should be preserved when status != done; got %v", err)
	}
}

func TestCleanupMilestone_NoopWhenManifestMissing(t *testing.T) {
	dir := t.TempDir()
	h := &CleanupMilestone{}
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

func TestCleanupMilestone_IdempotentWhenFileAlreadyGone(t *testing.T) {
	dir := t.TempDir()
	milestoneDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestoneDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestoneDir, "MANIFEST.cfg")
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|t|done||missing-body.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	// Do NOT create missing-body.md — hook should treat as a no-op.
	h := &CleanupMilestone{}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Errorf("missing body file should not error; got %v", err)
	}
}

func TestResolveMilestone_NumericKey(t *testing.T) {
	dir := t.TempDir()
	milestoneDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestoneDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestoneDir, "MANIFEST.cfg")
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|Title|done||m21.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := manifest.Load(manifestPath)
	if err != nil {
		t.Fatalf("manifest.Load: %v", err)
	}
	id, entry := resolveMilestone(m, "21")
	if entry == nil {
		t.Fatalf("resolveMilestone(%q) should resolve via m-prefix; got nil", "21")
	}
	if id != "m21" {
		t.Errorf("resolved id = %q, want m21", id)
	}
	if entry.Status != "done" {
		t.Errorf("resolved entry status = %q, want done", entry.Status)
	}
}

func TestResolveMilestone_MissingKey(t *testing.T) {
	dir := t.TempDir()
	milestoneDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestoneDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestoneDir, "MANIFEST.cfg")
	content := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|Title|done||m21.md|\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := manifest.Load(manifestPath)
	if err != nil {
		t.Fatalf("manifest.Load: %v", err)
	}
	_, entry := resolveMilestone(m, "m99")
	if entry != nil {
		t.Errorf("resolveMilestone(%q) should return nil for missing id; got %+v", "m99", entry)
	}
}
