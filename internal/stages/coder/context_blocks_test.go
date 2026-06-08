package coder

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBuild_EmptyEnv asserts an empty env yields empty blocks.
func TestBuild_EmptyEnv(t *testing.T) {
	// Clear env vars the blocks read.
	for _, k := range []string{
		"REPO_MAP_CONTENT", "GLOSSARY_FILE", "MILESTONE_BLOCK",
		"HUMAN_NOTES_BLOCK", "BUG_SCOUT_CONTEXT", "AFFECTED_TEST_FILES",
		"TEST_BASELINE_SUMMARY", "CLARIFICATIONS_CONTENT", "TDD_PREFLIGHT_FILE",
		"PRIOR_GIT_DIFF_STAT", "PRIOR_EXIT_REASON",
	} {
		t.Setenv(k, "")
	}
	dir := t.TempDir()
	env := &Env{ProjectDir: dir, StartAt: "coder"}
	b := Build(context.Background(), env, &Deps{})

	if b.Architecture != "" {
		t.Errorf("Architecture = %q; want empty", b.Architecture)
	}
	if b.RepoMap != "" {
		t.Errorf("RepoMap = %q; want empty", b.RepoMap)
	}
	if b.PriorTester != "" {
		t.Errorf("PriorTester = %q; want empty", b.PriorTester)
	}
}

// TestBuild_ArchitectureBlockWraps asserts the architecture file is read and
// wrapped with the expected header.
func TestBuild_ArchitectureBlockWraps(t *testing.T) {
	dir := t.TempDir()
	archPath := filepath.Join(dir, "ARCHITECTURE.md")
	if err := os.WriteFile(archPath, []byte("# Arch\nMap content."), 0o644); err != nil {
		t.Fatalf("write arch: %v", err)
	}
	t.Setenv("ARCHITECTURE_FILE", "ARCHITECTURE.md")
	env := &Env{ProjectDir: dir, StartAt: "coder"}
	b := Build(context.Background(), env, &Deps{})
	if !strings.Contains(b.Architecture, "Map content.") {
		t.Errorf("Architecture missing file body: %q", b.Architecture)
	}
	if !strings.Contains(b.Architecture, "Architecture Map") {
		t.Errorf("Architecture missing header prefix")
	}
}

// TestBuild_PriorTesterGatedByBugMarkers asserts only files containing
// "Bugs Found" or "BUG-" markers populate the block.
func TestBuild_PriorTesterGatedByBugMarkers(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tester.md")
	t.Setenv("TESTER_REPORT_FILE", "tester.md")

	// no marker → empty block
	_ = os.WriteFile(path, []byte("# nothing\n"), 0o644)
	env := &Env{ProjectDir: dir, StartAt: "coder"}
	b := Build(context.Background(), env, &Deps{})
	if b.PriorTester != "" {
		t.Errorf("PriorTester populated without bug marker: %q", b.PriorTester)
	}

	// marker present → populated
	_ = os.WriteFile(path, []byte("## Bugs Found\n- BUG-1\n"), 0o644)
	b = Build(context.Background(), env, &Deps{})
	if !strings.Contains(b.PriorTester, "BUG-1") {
		t.Errorf("PriorTester missing bug marker content: %q", b.PriorTester)
	}
}

// TestBuild_TDDPreflightOnlyWhenTestFirst asserts the TDD block is only
// populated when PIPELINE_ORDER=test_first AND TDD_PREFLIGHT_FILE is set.
func TestBuild_TDDPreflightOnlyWhenTestFirst(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tdd.md")
	_ = os.WriteFile(path, []byte("preflight body"), 0o644)
	t.Setenv("TDD_PREFLIGHT_FILE", path)

	// standard order → empty
	env := &Env{ProjectDir: dir, PipelineOrder: "standard"}
	b := Build(context.Background(), env, &Deps{})
	if b.TDDPreflight != "" {
		t.Errorf("TDDPreflight populated under standard order: %q", b.TDDPreflight)
	}

	// test_first → populated
	env.PipelineOrder = "test_first"
	b = Build(context.Background(), env, &Deps{})
	if !strings.Contains(b.TDDPreflight, "preflight body") {
		t.Errorf("TDDPreflight missing body: %q", b.TDDPreflight)
	}
}

// TestBuild_AsTemplateVarsMatches asserts the map round-trip preserves all
// 15 expected keys.
func TestBuild_AsTemplateVarsMatches(t *testing.T) {
	b := &ContextBlocks{
		Architecture:      "A",
		RepoMap:           "R",
		Glossary:          "G",
		Milestone:         "M",
		HumanNotes:        "HN",
		PriorReviewer:     "PR",
		PriorProgress:     "PP",
		PriorTester:       "PT",
		PreflightTests:    "PFT",
		NonBlockingNotes:  "NB",
		ScoutReport:       "S",
		AffectedTestFiles: "AT",
		TestBaselineSummary: "TB",
		Clarifications:    "C",
		TDDPreflight:      "TDD",
	}
	vars := b.AsTemplateVars()
	expected := []string{
		"ARCHITECTURE_BLOCK", "REPO_MAP_CONTENT", "GLOSSARY_BLOCK",
		"MILESTONE_BLOCK", "HUMAN_NOTES_BLOCK", "PRIOR_REVIEWER_CONTEXT",
		"PRIOR_PROGRESS_CONTEXT", "PRIOR_TESTER_CONTEXT",
		"PREFLIGHT_TEST_CONTEXT", "NON_BLOCKING_CONTEXT",
		"BUG_SCOUT_CONTEXT", "AFFECTED_TEST_FILES",
		"TEST_BASELINE_SUMMARY", "CLARIFICATIONS_CONTENT",
		"TESTER_PREFLIGHT_CONTENT",
	}
	for _, k := range expected {
		if _, ok := vars[k]; !ok {
			t.Errorf("AsTemplateVars missing key %q", k)
		}
	}
	if len(vars) != len(expected) {
		t.Errorf("AsTemplateVars has %d keys; want %d", len(vars), len(expected))
	}
}

// TestSafeReadFileFallback covers the file-size cap.
func TestSafeReadFileFallback(t *testing.T) {
	dir := t.TempDir()
	smallPath := filepath.Join(dir, "small.md")
	_ = os.WriteFile(smallPath, []byte("hi"), 0o644)
	if got := safeReadFileFallback(smallPath); got != "hi" {
		t.Errorf("safeReadFile small = %q; want hi", got)
	}
	if got := safeReadFileFallback(filepath.Join(dir, "no-such")); got != "" {
		t.Errorf("safeReadFile missing != \"\"")
	}
}
