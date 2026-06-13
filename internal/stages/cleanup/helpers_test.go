package cleanup

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestReadModifiedFilesFromCoderSummary(t *testing.T) {
	dir := t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatal(err)
	}
	summary := `# Coder Summary
## Files Created
- ` + "`lib/foo.sh`" + ` (NEW)
- bar/baz.go

## Files Modified
- internal/stages/cleanup/stage.go
- README.md

## Other Section
- not a file
`
	if err := os.WriteFile(filepath.Join(tekhtonDir, "CODER_SUMMARY.md"), []byte(summary), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readModifiedFilesFromCoderSummary(dir)
	want := []string{
		"lib/foo.sh",
		"bar/baz.go",
		"internal/stages/cleanup/stage.go",
		"README.md",
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("got[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestReadModifiedFilesFromCoderSummary_MissingFile(t *testing.T) {
	got := readModifiedFilesFromCoderSummary(t.TempDir())
	if got != nil {
		t.Errorf("got %v, want nil for missing summary", got)
	}
}

func TestLoadNonBlockingDoc_MissingFile(t *testing.T) {
	d, err := loadNonBlockingDoc(filepath.Join(t.TempDir(), "nope.md"))
	if err != nil {
		t.Fatalf("err = %v, want nil for missing file", err)
	}
	if d == nil {
		t.Fatal("expected empty doc, got nil")
	}
	if len(d.Notes) != 0 {
		t.Errorf("expected 0 notes, got %d", len(d.Notes))
	}
}

func TestResolveProjectDir_FromEnv(t *testing.T) {
	t.Setenv("PROJECT_DIR", "/tmp/from-env")
	if got := resolveProjectDir(nil); got != "/tmp/from-env" {
		t.Errorf("got %q, want /tmp/from-env", got)
	}
}

func TestResolvePromptsDir_Fallback(t *testing.T) {
	t.Setenv("TEKHTON_HOME", "")
	if got := resolvePromptsDir(nil); got != "prompts" {
		t.Errorf("got %q, want 'prompts'", got)
	}
}

func TestNonBlockingLogPath_Absolute(t *testing.T) {
	req := &proto.StageRequestV1{
		EnvOverrides: map[string]string{
			"NON_BLOCKING_LOG_FILE": "/etc/notes.md",
		},
	}
	if got := nonBlockingLogPath("/proj", req); got != "/etc/notes.md" {
		t.Errorf("got %q, want /etc/notes.md", got)
	}
}

func TestCleanupReportPath_Absolute(t *testing.T) {
	t.Setenv("CLEANUP_REPORT_FILE", "/abs/report.md")
	req := &proto.StageRequestV1{Stage: proto.StageCleanup}
	if got := cleanupReportPath(req); got != "/abs/report.md" {
		t.Errorf("got %q, want /abs/report.md", got)
	}
}

func TestArchiveReport_WithTimestamp(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, "logs")
	t.Setenv("LOG_DIR", logDir)
	t.Setenv("TIMESTAMP", "20260601_120000")

	reportPath := filepath.Join(dir, "CLEANUP_REPORT.md")
	if err := os.WriteFile(reportPath, []byte("report body"), 0o644); err != nil {
		t.Fatal(err)
	}

	req := &proto.StageRequestV1{
		Stage:        proto.StageCleanup,
		EnvOverrides: map[string]string{"PROJECT_DIR": dir},
	}
	archiveReport(reportPath, req)

	// Original should be gone, archive should exist.
	if _, err := os.Stat(reportPath); !os.IsNotExist(err) {
		t.Errorf("original report still present: err=%v", err)
	}
	archived := filepath.Join(logDir, "20260601_120000_CLEANUP_REPORT.md")
	if _, err := os.Stat(archived); err != nil {
		t.Errorf("archived file missing: %v", err)
	}
}

func TestArchiveReport_NoTimestamp(t *testing.T) {
	t.Setenv("TIMESTAMP", "")
	reportPath := filepath.Join(t.TempDir(), "CLEANUP_REPORT.md")
	if err := os.WriteFile(reportPath, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	req := &proto.StageRequestV1{Stage: proto.StageCleanup}
	archiveReport(reportPath, req)
	// File should remain in place (no archive performed).
	if _, err := os.Stat(reportPath); err != nil {
		t.Errorf("expected report preserved, got %v", err)
	}
}

func TestResolveByFileChanges_NoModifications(t *testing.T) {
	// In a temp dir with no git repo, gitDiffNameOnly returns an error
	// → resolveByFileChanges returns zero mutations.
	dir := t.TempDir()
	prevWD, _ := os.Getwd()
	defer func() { _ = os.Chdir(prevWD) }()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	d, batch := makeBatchDoc(t, "alpha")
	res := resolveByFileChanges(d, batch)
	if res.Resolved != 0 {
		t.Errorf("resolved = %d, want 0 (no git diff)", res.Resolved)
	}
}


func TestResolveTekhtonBin_NotFound(t *testing.T) {
	t.Setenv("TEKHTON_BIN", "")
	t.Setenv("TEKHTON_HOME", "")
	t.Setenv("PATH", "")
	got := resolveTekhtonBin()
	if got != "" {
		t.Errorf("resolveTekhtonBin() = %q, want empty", got)
	}
}

func TestResolveTekhtonBin_FromEnv(t *testing.T) {
	// Create a fake binary file so the stat check passes.
	dir := t.TempDir()
	bin := filepath.Join(dir, "tekhton-fake")
	if err := os.WriteFile(bin, []byte("#!/bin/sh"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TEKHTON_BIN", bin)
	if got := resolveTekhtonBin(); got != bin {
		t.Errorf("got %q, want %q", got, bin)
	}
}
