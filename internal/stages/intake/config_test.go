package intake

import (
	"os"
	"path/filepath"
	"testing"
)

// TestNewHelpers_ResolverFindsSlugFile locks in the fix for the m37.1 / m42
// false-positive NEEDS_CLARITY: when MilestoneContent receives a bare id
// like "37.1" or an m-prefixed id like "m37.1", newHelpers must wire a
// MilestoneFileResolver that looks up the manifest entry's File field. Before
// the fix, the direct join `<MilestoneDir>/37.1.md` missed every slug-named
// milestone file, the inline CLAUDE.md fallback couldn't find per-milestone
// content, and the intake agent saw only the task title.
func TestNewHelpers_ResolverFindsSlugFile(t *testing.T) {
	dir := t.TempDir()
	msDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(msDir, 0o755); err != nil {
		t.Fatalf("mkdir milestones: %v", err)
	}

	manifestPath := filepath.Join(msDir, "MANIFEST.cfg")
	manifestBody := "# header\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m37.1|Review Helpers and Parser|todo||m37.1-review-helpers-and-parser.md|\n"
	if err := os.WriteFile(manifestPath, []byte(manifestBody), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}

	slug := filepath.Join(msDir, "m37.1-review-helpers-and-parser.md")
	body := "# m37.1 — Review Helpers and Parser\n\nFull design body.\n"
	if err := os.WriteFile(slug, []byte(body), 0o644); err != nil {
		t.Fatalf("write slug: %v", err)
	}

	cfg := config{
		ProjectDir:   dir,
		MilestoneDir: ".claude/milestones",
		DagEnabled:   true,
	}
	h := newHelpers(cfg)

	for _, id := range []string{"37.1", "m37.1"} {
		got, err := h.MilestoneContent(true, id, "fallback-task-string")
		if err != nil {
			t.Fatalf("MilestoneContent(%q): %v", id, err)
		}
		if got != body {
			t.Errorf("MilestoneContent(%q) returned %q, want milestone body %q", id, got, body)
		}
	}
}

// TestNewHelpers_ResolverMissingEntryReturnsEmpty confirms the resolver
// returns "" (not the fallback task) when the manifest exists but the entry
// is absent. Lets MilestoneContent fall through to its inline-mode branch.
func TestNewHelpers_ResolverMissingEntryReturnsEmpty(t *testing.T) {
	dir := t.TempDir()
	msDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(msDir, 0o755); err != nil {
		t.Fatalf("mkdir milestones: %v", err)
	}
	manifestPath := filepath.Join(msDir, "MANIFEST.cfg")
	if err := os.WriteFile(manifestPath, []byte(
		"# id|title|status|depends_on|file|parallel_group\n"+
			"m99|Other|todo||m99-other.md|\n"), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}

	cfg := config{
		ProjectDir:   dir,
		MilestoneDir: ".claude/milestones",
		DagEnabled:   true,
	}
	h := newHelpers(cfg)
	if got := h.MilestoneFileResolver("37.1"); got != "" {
		t.Errorf("resolver for unknown id: got %q, want empty", got)
	}
}
