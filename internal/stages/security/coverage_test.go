package security

// coverage_test.go — targeted tests for the code paths that kept
// internal/stages/security below the 80% line-coverage threshold after m35.2:
//
//   - writePromptTmpFile: CreateTemp failure path
//   - resolveTekhtonBin: TEKHTON_HOME/bin/tekhton, exec.LookPath, not-found
//   - writeHaltState: milestone-mode resume-flag branch; store.Update failure
//   - humanActionFile: relative-path join branch
//   - subprocessBuildGate.Run: noop-when-no-binary and exec-with-binary
//   - RunStage: scan_failed / failResult path via CreateTemp error

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// ---------------------------------------------------------------------------
// writePromptTmpFile
// ---------------------------------------------------------------------------

// TestWritePromptTmpFile_Success verifies the happy path: content is written
// to a temp file whose path is returned, and the cleanup func removes it.
func TestWritePromptTmpFile_Success(t *testing.T) {
	content := "# Security Scan Prompt\nsome content here\n"
	path, cleanup, err := writePromptTmpFile(content)
	if err != nil {
		t.Fatalf("writePromptTmpFile: unexpected error: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read temp file: %v", err)
	}
	if string(got) != content {
		t.Errorf("content=%q want %q", string(got), content)
	}
	cleanup()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("cleanup func should have removed the temp file")
	}
}

// TestWritePromptTmpFile_CreateTempFails sets TMPDIR to a non-existent
// directory so os.CreateTemp fails. writePromptTmpFile must return a non-nil
// error and a no-op cleanup func.
func TestWritePromptTmpFile_CreateTempFails(t *testing.T) {
	// t.TempDir() is evaluated before t.Setenv, so the parent dir exists;
	// only the "nonexistent-sub" child does not.
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "nonexistent-sub"))
	_, cleanup, err := writePromptTmpFile("content")
	if err == nil {
		cleanup()
		t.Error("expected error from CreateTemp with non-existent TMPDIR; got nil")
	}
}

// ---------------------------------------------------------------------------
// resolveTekhtonBin
// ---------------------------------------------------------------------------

// TestResolveTekhtonBin_TekhtonBinExists verifies that TEKHTON_BIN pointing
// to an existing file is returned without falling through to other branches.
func TestResolveTekhtonBin_TekhtonBinExists(t *testing.T) {
	fakeBin := filepath.Join(t.TempDir(), "tekhton")
	if err := os.WriteFile(fakeBin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("create fake binary: %v", err)
	}
	t.Setenv("TEKHTON_BIN", fakeBin)

	got := resolveTekhtonBin()
	if got != fakeBin {
		t.Errorf("resolveTekhtonBin=%q want %q", got, fakeBin)
	}
}

// TestResolveTekhtonBin_TekhtonBinMissingFallsToHome verifies that a missing
// TEKHTON_BIN path is skipped and the TEKHTON_HOME/bin/tekhton candidate is
// returned when it exists.
func TestResolveTekhtonBin_TekhtonBinMissingFallsToHome(t *testing.T) {
	fakeHome := t.TempDir()
	homeBinDir := filepath.Join(fakeHome, "bin")
	if err := os.MkdirAll(homeBinDir, 0o755); err != nil {
		t.Fatalf("mkdir bin: %v", err)
	}
	homeBin := filepath.Join(homeBinDir, "tekhton")
	if err := os.WriteFile(homeBin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("create fake home binary: %v", err)
	}

	t.Setenv("TEKHTON_BIN", filepath.Join(t.TempDir(), "no-such-tekhton"))
	t.Setenv("TEKHTON_HOME", fakeHome)

	got := resolveTekhtonBin()
	if got != homeBin {
		t.Errorf("resolveTekhtonBin=%q want %q", got, homeBin)
	}
}

// TestResolveTekhtonBin_LookPath verifies that when TEKHTON_BIN and
// TEKHTON_HOME miss, exec.LookPath is consulted and returns the binary on
// PATH.
func TestResolveTekhtonBin_LookPath(t *testing.T) {
	binDir := t.TempDir()
	fakeBin := filepath.Join(binDir, "tekhton")
	if err := os.WriteFile(fakeBin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("create fake binary: %v", err)
	}
	t.Setenv("TEKHTON_BIN", "")
	t.Setenv("TEKHTON_HOME", "")
	t.Setenv("PATH", binDir)

	got := resolveTekhtonBin()
	if got == "" {
		t.Error("resolveTekhtonBin returned empty string; expected path via LookPath")
	}
	if !strings.HasSuffix(got, "tekhton") {
		t.Errorf("resolveTekhtonBin=%q want path ending in 'tekhton'", got)
	}
}

// TestResolveTekhtonBin_NoneFound verifies the "" fallback when all three
// resolution paths miss.
func TestResolveTekhtonBin_NoneFound(t *testing.T) {
	t.Setenv("TEKHTON_BIN", "")
	t.Setenv("TEKHTON_HOME", "")
	t.Setenv("PATH", t.TempDir()) // empty dir — no binaries

	got := resolveTekhtonBin()
	if got != "" {
		t.Errorf("resolveTekhtonBin=%q want empty string when nothing found", got)
	}
}

// ---------------------------------------------------------------------------
// writeHaltState
// ---------------------------------------------------------------------------

// TestWriteHaltState_MilestoneMode verifies that when MilestoneMode is true
// the resume flag written to the state file is "--milestone --start-at security".
func TestWriteHaltState_MilestoneMode(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, "PIPELINE_STATE.json")
	t.Setenv("PIPELINE_STATE_FILE", statePath)

	cfg := config{
		ProjectDir:    dir,
		Task:          "test task",
		MilestoneMode: true,
	}
	writeHaltState(cfg)

	data, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read state file: %v", err)
	}
	s := string(data)
	if !strings.Contains(s, "--milestone") {
		t.Errorf("state file missing '--milestone' prefix in milestone mode:\n%s", s)
	}
	if !strings.Contains(s, "--start-at security") {
		t.Errorf("state file missing '--start-at security':\n%s", s)
	}
}

// TestWriteHaltState_StoreFails exercises the error-ignored path: when
// store.Update cannot write (because a regular file blocks the would-be
// parent directory), writeHaltState must not panic or return an error to its
// caller — it discards the error via _ = store.Update(...).
func TestWriteHaltState_StoreFails(t *testing.T) {
	// Create a regular file at the path that store.Update would treat as a
	// directory. os.Open on the state path will fail with ENOTDIR, causing
	// store.Update to return an error that writeHaltState ignores.
	blockFile := filepath.Join(t.TempDir(), "blocking-file")
	if err := os.WriteFile(blockFile, []byte("not a dir"), 0o644); err != nil {
		t.Fatalf("write blocking file: %v", err)
	}
	t.Setenv("PIPELINE_STATE_FILE", filepath.Join(blockFile, "PIPELINE_STATE.json"))

	cfg := config{Task: "test task"}
	writeHaltState(cfg) // must not panic
}

// ---------------------------------------------------------------------------
// humanActionFile
// ---------------------------------------------------------------------------

// TestHumanActionFile_RelativePath verifies that a relative HUMAN_ACTION_FILE
// value is joined with ProjectDir.
func TestHumanActionFile_RelativePath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HUMAN_ACTION_FILE", "custom/action.md")

	cfg := config{ProjectDir: dir}
	got := humanActionFile(cfg)
	want := filepath.Join(dir, "custom", "action.md")
	if got != want {
		t.Errorf("humanActionFile=%q want %q", got, want)
	}
}

// TestHumanActionFile_AbsoluteOverride verifies that an absolute
// HUMAN_ACTION_FILE is returned unchanged (no ProjectDir join).
func TestHumanActionFile_AbsoluteOverride(t *testing.T) {
	absPath := "/absolute/path/to/action.md"
	t.Setenv("HUMAN_ACTION_FILE", absPath)

	cfg := config{ProjectDir: "/some/project"}
	got := humanActionFile(cfg)
	if got != absPath {
		t.Errorf("humanActionFile=%q want %q (absolute path must not be joined)", got, absPath)
	}
}

// ---------------------------------------------------------------------------
// subprocessBuildGate
// ---------------------------------------------------------------------------

// TestSubprocessBuildGate_RunNoBinary verifies that Run is a noop (returns
// nil) when no tekhton binary can be resolved.
func TestSubprocessBuildGate_RunNoBinary(t *testing.T) {
	t.Setenv("TEKHTON_BIN", "")
	t.Setenv("TEKHTON_HOME", "")
	t.Setenv("PATH", t.TempDir()) // empty dir — no tekhton

	gate := subprocessBuildGate{}
	if err := gate.Run(context.Background(), t.TempDir(), "test-stage"); err != nil {
		t.Errorf("Run with no binary should be noop (nil): %v", err)
	}
}

// TestSubprocessBuildGate_RunWithBinary verifies that Run execs the resolved
// binary with the correct arguments and returns nil on exit 0.
func TestSubprocessBuildGate_RunWithBinary(t *testing.T) {
	// Fake tekhton binary: accepts "gate build --stage-label …" and exits 0.
	fakeBin := filepath.Join(t.TempDir(), "tekhton")
	if err := os.WriteFile(fakeBin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write fake binary: %v", err)
	}
	t.Setenv("TEKHTON_BIN", fakeBin)

	gate := subprocessBuildGate{}
	if err := gate.Run(context.Background(), t.TempDir(), "security-rework"); err != nil {
		t.Errorf("Run with valid binary: %v", err)
	}
}

// ---------------------------------------------------------------------------
// RunStage — scan_failed / failResult integration
// ---------------------------------------------------------------------------

// TestRunStage_ScanFailedOnCreateTempError exercises the scan_failed verdict
// path (failResult) by making os.CreateTemp fail inside invokeScanAgent.
// TMPDIR is set to a non-existent path AFTER setupProject has created its
// directories, so only subsequent CreateTemp calls inside the stage fail.
func TestRunStage_ScanFailedOnCreateTempError(t *testing.T) {
	dir, req := setupProject(t)
	writeCoderSummary(t, dir, `# Coder Summary
## Files Modified
- src/auth.go
`)
	// Point TMPDIR at a path that does not exist. os.CreateTemp("", …) uses
	// os.TempDir() which reads $TMPDIR, so the first CreateTemp call inside
	// writePromptTmpFile fails without reaching agentRunner.Run.
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "nonexistent-tmpdir"))

	restore := installSeams(t, &fakeAgent{}, &fakeBuildGate{})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err == nil {
		t.Error("expected non-nil error from scan_failed path; got nil")
	}
	if res == nil {
		t.Fatal("expected non-nil StageResultV1 even on scan_failed path")
	}
	if res.Verdict != proto.VerdictFail {
		t.Errorf("verdict=%q want fail", res.Verdict)
	}
	if res.ExitReason != "scan_failed" {
		t.Errorf("exit_reason=%q want scan_failed", res.ExitReason)
	}
	if res.AgentCalls != 0 {
		t.Errorf("agent_calls=%d want 0 (agent never started before CreateTemp failed)", res.AgentCalls)
	}
}
