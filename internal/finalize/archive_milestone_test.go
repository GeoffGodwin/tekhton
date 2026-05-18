package finalize

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

func TestArchiveMilestone_AppendsBodyToArchiveOnCompleteContinue(t *testing.T) {
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
	body := "# m21 — body\n\nimplementation notes go here.\n"
	if err := os.WriteFile(filepath.Join(milestoneDir, "m21-body.md"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(dir, ".tekhton", "MILESTONE_ARCHIVE.md")
	h := &ArchiveMilestone{
		ArchiveFile: archive,
		Now: func() time.Time {
			return time.Date(2026, 5, 17, 12, 0, 0, 0, time.UTC)
		},
	}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		Milestone:            "m21",
		MilestoneMode:        true,
		MilestoneDisposition: "COMPLETE_AND_CONTINUE",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ArchiveMilestone.Run: %v", err)
	}

	got, err := os.ReadFile(archive)
	if err != nil {
		t.Fatalf("read archive: %v", err)
	}
	gotStr := string(got)
	if !strings.Contains(gotStr, "# Milestone Archive") {
		t.Errorf("expected archive header preamble in %q", gotStr)
	}
	if !strings.Contains(gotStr, "Archived: 2026-05-17") {
		t.Errorf("expected date stamp in archive entry")
	}
	if !strings.Contains(gotStr, "implementation notes go here") {
		t.Errorf("expected body content appended to archive")
	}
}

func TestArchiveMilestone_NoopWhenStatusNotDone(t *testing.T) {
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
	archive := filepath.Join(dir, ".tekhton", "MILESTONE_ARCHIVE.md")
	h := &ArchiveMilestone{ArchiveFile: archive}
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
	if _, err := os.Stat(archive); err == nil {
		t.Errorf("archive should not exist when milestone is not done")
	}
}

func TestArchiveMilestone_NoopWhenManifestMissing(t *testing.T) {
	dir := t.TempDir()
	h := &ArchiveMilestone{}
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

func TestArchiveMilestone_NoopWhenBodyFileMissing(t *testing.T) {
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
	// Do NOT create missing-body.md — the hook should skip silently.
	archive := filepath.Join(dir, ".tekhton", "MILESTONE_ARCHIVE.md")
	h := &ArchiveMilestone{ArchiveFile: archive}
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
	// Archive should not be created since the body was absent.
	if _, err := os.Stat(archive); err == nil {
		t.Errorf("archive should not be created when body file is missing")
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
	// Lookup by bare numeric "21" — should resolve to "m21".
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
