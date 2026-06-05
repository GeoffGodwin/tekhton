package intake

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestHelpers(t *testing.T) *Helpers {
	t.Helper()
	root := t.TempDir()
	session := filepath.Join(root, "session")
	msDir := filepath.Join(root, "milestones")
	if err := os.MkdirAll(session, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(msDir, 0o755); err != nil {
		t.Fatal(err)
	}
	return &Helpers{
		ProjectDir:         root,
		SessionDir:         session,
		MilestoneDir:       msDir,
		ProjectRulesFile:   filepath.Join(root, "CLAUDE.md"),
		ClarificationsFile: ".tekhton/CLARIFICATIONS.md",
		DagEnabled:         true,
	}
}

func TestContentHash(t *testing.T) {
	h := &Helpers{}
	got := h.ContentHash("hello world")
	want := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
	if got != want {
		t.Fatalf("ContentHash mismatch: got %q want %q", got, want)
	}
}

func TestShouldSkipSaveHashRoundTrip(t *testing.T) {
	h := newTestHelpers(t)
	hash := h.ContentHash("body")
	if h.ShouldSkip(hash) {
		t.Fatalf("ShouldSkip true before SaveHash")
	}
	if err := h.SaveHash(hash); err != nil {
		t.Fatalf("SaveHash: %v", err)
	}
	if !h.ShouldSkip(hash) {
		t.Fatalf("ShouldSkip false after SaveHash")
	}
	if h.ShouldSkip("different") {
		t.Fatalf("ShouldSkip true for wrong hash")
	}
}

func TestParseVerdictHappyPath(t *testing.T) {
	h := newTestHelpers(t)
	cases := map[string]string{
		"testdata/report_pass.md":          "PASS",
		"testdata/report_tweaked.md":       "TWEAKED",
		"testdata/report_split.md":         "SPLIT_RECOMMENDED",
		"testdata/report_needs_clarity.md": "NEEDS_CLARITY",
	}
	for path, want := range cases {
		got := h.ParseVerdict(path)
		if got != want {
			t.Errorf("ParseVerdict(%s) = %q, want %q", path, got, want)
		}
	}
}

func TestParseVerdictFallback(t *testing.T) {
	h := newTestHelpers(t)
	if got := h.ParseVerdict("does-not-exist.md"); got != "PASS" {
		t.Errorf("missing file: got %q, want PASS", got)
	}
	// Garbage verdict.
	bad := filepath.Join(t.TempDir(), "bad.md")
	_ = os.WriteFile(bad, []byte("## Verdict\nMAYBE\n"), 0o644)
	if got := h.ParseVerdict(bad); got != "PASS" {
		t.Errorf("garbage verdict: got %q, want PASS", got)
	}
	// Empty section.
	emptySection := filepath.Join(t.TempDir(), "empty.md")
	_ = os.WriteFile(emptySection, []byte("## Verdict\n\n## Confidence\n50\n"), 0o644)
	if got := h.ParseVerdict(emptySection); got != "PASS" {
		t.Errorf("empty verdict section: got %q, want PASS", got)
	}
}

func TestParseConfidence(t *testing.T) {
	h := newTestHelpers(t)
	if got := h.ParseConfidence("testdata/report_pass.md"); got != 95 {
		t.Errorf("pass report confidence = %d, want 95", got)
	}
	if got := h.ParseConfidence("testdata/report_split.md"); got != 60 {
		t.Errorf("split report confidence = %d, want 60", got)
	}
	// Out-of-range falls back to 100.
	oor := filepath.Join(t.TempDir(), "oor.md")
	_ = os.WriteFile(oor, []byte("## Confidence\n9999\n"), 0o644)
	if got := h.ParseConfidence(oor); got != 100 {
		t.Errorf("out-of-range: got %d, want 100 (clamp)", got)
	}
	// Non-numeric falls back to 100.
	non := filepath.Join(t.TempDir(), "non.md")
	_ = os.WriteFile(non, []byte("## Confidence\nhigh\n"), 0o644)
	if got := h.ParseConfidence(non); got != 100 {
		t.Errorf("non-numeric: got %d, want 100", got)
	}
	// Missing file.
	if got := h.ParseConfidence("does-not-exist.md"); got != 100 {
		t.Errorf("missing file: got %d, want 100", got)
	}
}

func TestParseTweaks(t *testing.T) {
	h := newTestHelpers(t)
	got := h.ParseTweaks("testdata/report_tweaked.md")
	if !strings.Contains(got, "# m99.9 — Test Milestone (PM-tweaked)") {
		t.Errorf("missing tweaked content body; got:\n%s", got)
	}
	if strings.Contains(got, "## Questions") {
		t.Errorf("section bleed: parsed tweaks contains the ## Questions stop heading")
	}
}

func TestParseQuestions(t *testing.T) {
	h := newTestHelpers(t)
	got := h.ParseQuestions("testdata/report_needs_clarity.md")
	if !strings.Contains(got, "[BLOCKING] Which dashboard files") {
		t.Errorf("missing first question; got:\n%s", got)
	}
	if !strings.Contains(got, "What is the expected interaction model for the new sidebar?") {
		t.Errorf("missing third question; got:\n%s", got)
	}
}

func TestApplyTweakMilestone_SizeGuardReject(t *testing.T) {
	h := newTestHelpers(t)
	// Place a 100-line milestone under MilestoneDir as m99.9.md.
	orig, err := os.ReadFile("testdata/milestone_long.md")
	if err != nil {
		t.Fatal(err)
	}
	msFile := filepath.Join(h.MilestoneDir, "m99.9.md")
	if err := os.WriteFile(msFile, orig, 0o644); err != nil {
		t.Fatal(err)
	}
	tweaked := "# m99.9 — shrunk\n\n## Acceptance\n- [ ] something\n"

	err = h.ApplyTweakMilestone(tweaked, "m99.9", 50)
	if !errors.Is(err, ErrTweakRejected) {
		t.Fatalf("expected ErrTweakRejected, got %v", err)
	}

	// Original unchanged.
	after, _ := os.ReadFile(msFile)
	if string(after) != string(orig) {
		t.Fatalf("original milestone modified despite rejection")
	}
	// REJECTED_TWEAK.md saved.
	saved, err := os.ReadFile(filepath.Join(h.SessionDir, "REJECTED_TWEAK.md"))
	if err != nil {
		t.Fatalf("REJECTED_TWEAK.md missing: %v", err)
	}
	if !strings.Contains(string(saved), "shrunk") {
		t.Fatalf("REJECTED_TWEAK.md missing tweaked content")
	}
}

func TestApplyTweakMilestone_SizeGuardAccept(t *testing.T) {
	h := newTestHelpers(t)
	orig, _ := os.ReadFile("testdata/milestone_long.md")
	msFile := filepath.Join(h.MilestoneDir, "m99.9.md")
	_ = os.WriteFile(msFile, orig, 0o644)

	// Build tweaked content above the 50% threshold (>= 50 lines for a
	// 96-line original).
	var sb strings.Builder
	for i := 0; i < 80; i++ {
		sb.WriteString("tweaked line\n")
	}
	tweaked := sb.String()

	if err := h.ApplyTweakMilestone(tweaked, "m99.9", 50); err != nil {
		t.Fatalf("ApplyTweakMilestone: %v", err)
	}
	// File replaced.
	after, _ := os.ReadFile(msFile)
	if !strings.HasPrefix(string(after), "tweaked line\n") {
		t.Errorf("milestone not overwritten")
	}
	// .pre-tweak backup exists.
	bak, err := os.ReadFile(msFile + ".pre-tweak")
	if err != nil {
		t.Fatalf(".pre-tweak missing: %v", err)
	}
	if string(bak) != string(orig) {
		t.Errorf(".pre-tweak does not match original")
	}
}

func TestApplyTweakMilestone_SmallMilestoneNoGuard(t *testing.T) {
	h := newTestHelpers(t)
	// Small (<= 20 lines) milestone skips the guard.
	small := "# m1\n## A\n- [ ] x\n- [ ] y\n- [ ] z\n"
	msFile := filepath.Join(h.MilestoneDir, "m1.md")
	_ = os.WriteFile(msFile, []byte(small), 0o644)
	tweaked := "# m1\n## B\n"

	if err := h.ApplyTweakMilestone(tweaked, "m1", 50); err != nil {
		t.Fatalf("ApplyTweakMilestone (small, no guard): %v", err)
	}
}

func TestAddPMMetadata_InsertAfterMetaBlock(t *testing.T) {
	h := newTestHelpers(t)
	body := `<!-- milestone-meta
id: "1"
status: "todo"
-->

# m1 — Demo

## Overview
Body.
`
	msFile := filepath.Join(h.MilestoneDir, "m1.md")
	_ = os.WriteFile(msFile, []byte(body), 0o644)

	pinDate(t, "2026-06-04")
	if err := h.AddPMMetadata(msFile); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(msFile)
	wantContains := "-->\n<!-- PM-tweaked: 2026-06-04 -->\n"
	if !strings.Contains(string(got), wantContains) {
		t.Errorf("expected meta-block insertion; got:\n%s", got)
	}
}

func TestAddPMMetadata_InsertAfterFirstLine(t *testing.T) {
	h := newTestHelpers(t)
	body := "# m1 — Demo\n\n## Overview\nBody.\n"
	msFile := filepath.Join(h.MilestoneDir, "m1.md")
	_ = os.WriteFile(msFile, []byte(body), 0o644)

	pinDate(t, "2026-06-04")
	if err := h.AddPMMetadata(msFile); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(msFile)
	wantPrefix := "# m1 — Demo\n<!-- PM-tweaked: 2026-06-04 -->\n"
	if !strings.HasPrefix(string(got), wantPrefix) {
		t.Errorf("expected first-line insertion; got:\n%s", got)
	}
}

func TestAddPMMetadata_UpdateExisting(t *testing.T) {
	h := newTestHelpers(t)
	body := "# m1\n<!-- PM-tweaked: 2020-01-01 -->\n\n## Body\n"
	msFile := filepath.Join(h.MilestoneDir, "m1.md")
	_ = os.WriteFile(msFile, []byte(body), 0o644)

	pinDate(t, "2026-06-04")
	if err := h.AddPMMetadata(msFile); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(msFile)
	if strings.Contains(string(got), "2020-01-01") {
		t.Errorf("old date not replaced; got:\n%s", got)
	}
	if !strings.Contains(string(got), "<!-- PM-tweaked: 2026-06-04 -->") {
		t.Errorf("new date missing; got:\n%s", got)
	}
}

func TestApplyTweakTask(t *testing.T) {
	h := newTestHelpers(t)
	tweaked := "\n\nbuild the parser more carefully\n\nadditional context\n"
	got, err := h.ApplyTweakTask(tweaked)
	if err != nil {
		t.Fatal(err)
	}
	want := "build the parser more carefully"
	if got != want {
		t.Errorf("ApplyTweakTask = %q, want %q", got, want)
	}
	saved, _ := os.ReadFile(filepath.Join(h.SessionDir, "INTAKE_TWEAKED_TASK.md"))
	if !strings.Contains(string(saved), want) {
		t.Errorf("INTAKE_TWEAKED_TASK.md missing content; got: %s", saved)
	}
}

func TestApplyTweakTask_Empty(t *testing.T) {
	h := newTestHelpers(t)
	if _, err := h.ApplyTweakTask("   \n\n"); err == nil {
		t.Errorf("expected error on empty input")
	}
}

func TestMilestoneContent_DAGFile(t *testing.T) {
	h := newTestHelpers(t)
	msFile := filepath.Join(h.MilestoneDir, "m1.md")
	body := "# m1\nbody.\n"
	_ = os.WriteFile(msFile, []byte(body), 0o644)
	got, err := h.MilestoneContent(true, "m1", "fallback-task")
	if err != nil {
		t.Fatal(err)
	}
	if got != body {
		t.Errorf("got %q, want %q", got, body)
	}
}

func TestMilestoneContent_InlineFallback(t *testing.T) {
	h := newTestHelpers(t)
	h.DagEnabled = false
	claude := `# Project

## Milestone 1
First milestone body.

### Sub-heading inside milestone 1
Still in milestone 1.

## Milestone 2
Second milestone — should not be included.
`
	_ = os.WriteFile(h.ProjectRulesFile, []byte(claude), 0o644)
	got, err := h.MilestoneContent(true, "1", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "First milestone body.") {
		t.Errorf("missing first milestone body; got:\n%s", got)
	}
	if strings.Contains(got, "Second milestone") {
		t.Errorf("bled into next milestone; got:\n%s", got)
	}
}

func TestMilestoneContent_NonMilestoneMode(t *testing.T) {
	h := newTestHelpers(t)
	got, err := h.MilestoneContent(false, "", "raw task")
	if err != nil {
		t.Fatal(err)
	}
	if got != "raw task" {
		t.Errorf("got %q, want raw task", got)
	}
}

// pinDate overrides dateProvider for the duration of t.
func pinDate(t *testing.T, want string) {
	t.Helper()
	orig := dateProvider
	dateProvider = func() string { return want }
	t.Cleanup(func() { dateProvider = orig })
}
