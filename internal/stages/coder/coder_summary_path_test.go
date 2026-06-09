package coder

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// newTestOrchestrator builds a minimal orchestrator pointed at a temp
// project directory. The deps are no-op (DefaultDeps) so individual tests
// only wire what their code path touches.
func newTestOrchestrator(t *testing.T, projectDir string) *orchestrator {
	t.Helper()
	req := &proto.StageRequestV1{Stage: "coder"}
	o := newOrchestrator(req)
	o.cfg.ProjectDir = projectDir
	return o
}

// TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalAbsent verifies
// the "move" path: when JR_CODER_SUMMARY.md exists at the project root but
// the canonical .tekhton/JR_CODER_SUMMARY.md is absent, the hook moves it
// and logs a warning. The canonical path must contain the original content.
//
// This covers acceptance criterion:
// "TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalAbsent passing"
func TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalAbsent(t *testing.T) {
	dir := t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}

	const wantContent = "## Status — COMPLETE\nImplemented the fix.\n"

	// Plant the misplaced file at the repo root.
	misplaced := filepath.Join(dir, "JR_CODER_SUMMARY.md")
	if err := os.WriteFile(misplaced, []byte(wantContent), 0o644); err != nil {
		t.Fatalf("write misplaced file: %v", err)
	}

	canonical := filepath.Join(dir, ".tekhton", "JR_CODER_SUMMARY.md")

	// Precondition: canonical does not exist.
	if _, err := os.Stat(canonical); !os.IsNotExist(err) {
		t.Fatalf("canonical should not exist before hook runs")
	}

	o := newTestOrchestrator(t, dir)
	o.checkAndMoveMisplacedSummaries()

	// The misplaced root file must be gone.
	if _, err := os.Stat(misplaced); !os.IsNotExist(err) {
		t.Errorf("misplaced root file still exists after hook — hook did not move it")
	}

	// The canonical file must now exist with the original content intact.
	got, err := os.ReadFile(canonical)
	if err != nil {
		t.Fatalf("canonical file not created: %v", err)
	}
	if string(got) != wantContent {
		t.Errorf("canonical file content mismatch after move:\n  want: %q\n   got: %q", wantContent, string(got))
	}
}

// TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalPresent verifies
// the "delete misplaced, preserve canonical" path. When both files exist, the
// hook removes the misplaced root copy and leaves the canonical file
// byte-for-byte unchanged.
//
// Reviewer note: the canonical file's content is written as a known fixture
// string and asserted after the hook runs. An implementation that truncates
// the canonical before removing the misplaced one would fail here.
//
// This covers acceptance criterion:
// "TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalPresent passing"
func TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalPresent(t *testing.T) {
	dir := t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}

	// Known fixture written to the canonical path BEFORE the hook runs.
	const canonicalContent = "## Status — COMPLETE\nCanonical version — must survive the hook.\n"
	const misplacedContent = "## Status — INCOMPLETE\nStale stray at root.\n"

	canonical := filepath.Join(dir, ".tekhton", "JR_CODER_SUMMARY.md")
	if err := os.WriteFile(canonical, []byte(canonicalContent), 0o644); err != nil {
		t.Fatalf("write canonical: %v", err)
	}
	misplaced := filepath.Join(dir, "JR_CODER_SUMMARY.md")
	if err := os.WriteFile(misplaced, []byte(misplacedContent), 0o644); err != nil {
		t.Fatalf("write misplaced: %v", err)
	}

	o := newTestOrchestrator(t, dir)
	o.checkAndMoveMisplacedSummaries()

	// The misplaced root file must be gone.
	if _, err := os.Stat(misplaced); !os.IsNotExist(err) {
		t.Errorf("misplaced root file still exists — hook should have deleted it")
	}

	// The canonical file must exist and contain the ORIGINAL content byte-for-byte.
	// This assertion catches an implementation that truncates canonical before
	// deleting the misplaced file (the reviewer-identified failure mode).
	got, err := os.ReadFile(canonical)
	if err != nil {
		t.Fatalf("canonical file missing after hook ran: %v", err)
	}
	if string(got) != canonicalContent {
		t.Errorf("canonical file content was altered:\n  want: %q\n   got: %q", canonicalContent, string(got))
	}
}

// TestCheckAndMoveMisplacedSummaries_CleanState verifies the no-op path:
// when neither a misplaced root file nor a canonical file is present, the
// hook makes no filesystem changes and returns without error.
func TestCheckAndMoveMisplacedSummaries_CleanState(t *testing.T) {
	dir := t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}

	// No misplaced file. No canonical file.
	o := newTestOrchestrator(t, dir)
	o.checkAndMoveMisplacedSummaries() // Must not panic or create files.

	// Confirm neither file was created.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	for _, e := range entries {
		if e.Name() == "JR_CODER_SUMMARY.md" || e.Name() == "CODER_SUMMARY.md" {
			t.Errorf("hook created unexpected file in project root: %s", e.Name())
		}
	}
	tekhtonEntries, err := os.ReadDir(tekhtonDir)
	if err != nil {
		t.Fatalf("ReadDir .tekhton: %v", err)
	}
	for _, e := range tekhtonEntries {
		if e.Name() == "JR_CODER_SUMMARY.md" || e.Name() == "CODER_SUMMARY.md" {
			t.Errorf("hook created unexpected file in .tekhton/: %s", e.Name())
		}
	}
}

// TestCheckAndMoveMisplacedSummaries_BothFiles covers CODER_SUMMARY.md as
// well as JR_CODER_SUMMARY.md — the milestone spec says the hook checks both.
// The test plants CODER_SUMMARY.md at the root (with no canonical) and asserts
// it moves to .tekhton/CODER_SUMMARY.md with content intact.
func TestCheckAndMoveMisplacedSummaries_CoderSummaryMisplaced(t *testing.T) {
	dir := t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}

	const wantContent = "## Status — COMPLETE\nCoder summary at root — should move.\n"

	misplaced := filepath.Join(dir, "CODER_SUMMARY.md")
	if err := os.WriteFile(misplaced, []byte(wantContent), 0o644); err != nil {
		t.Fatalf("write misplaced CODER_SUMMARY.md: %v", err)
	}

	canonical := filepath.Join(dir, ".tekhton", "CODER_SUMMARY.md")

	o := newTestOrchestrator(t, dir)
	o.checkAndMoveMisplacedSummaries()

	if _, err := os.Stat(misplaced); !os.IsNotExist(err) {
		t.Errorf("misplaced CODER_SUMMARY.md at root still exists")
	}
	got, err := os.ReadFile(canonical)
	if err != nil {
		t.Fatalf("canonical CODER_SUMMARY.md not created: %v", err)
	}
	if string(got) != wantContent {
		t.Errorf("canonical CODER_SUMMARY.md content mismatch:\n  want: %q\n   got: %q", wantContent, string(got))
	}
}
