package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// TestStateUpdateCmd_FirstClassFields drives the Cobra Execute path for
// `tekhton state update --field K=V`, the lowest-coverage spot in state.go.
func TestStateUpdateCmd_FirstClassFields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	// Seed an existing snapshot so update is read-modify-write.
	if err := state.New(path).Update(func(s *proto.StateSnapshotV1) {
		s.ExitStage = "coder"
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	cmd := newStateUpdateCmd()
	cmd.SetArgs([]string{
		"--path", path,
		"--field", "exit_stage=tester",
		"--field", "review_cycle=4",
		"--field", "human_mode=true",
	})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("update: %v", err)
	}

	got, err := state.New(path).Read()
	if err != nil {
		t.Fatalf("read after update: %v", err)
	}
	if got.ExitStage != "tester" {
		t.Errorf("ExitStage: got %q, want tester", got.ExitStage)
	}
	if got.ReviewCycle != 4 {
		t.Errorf("ReviewCycle: got %d, want 4", got.ReviewCycle)
	}
	if got.Extra["human_mode"] != "true" {
		t.Errorf("Extra[human_mode]: got %q, want true", got.Extra["human_mode"])
	}
}

// TestStateUpdateCmd_MissingPath verifies the error path for state update.
func TestStateUpdateCmd_MissingPath(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "")
	cmd := newStateUpdateCmd()
	cmd.SetArgs([]string{"--field", "exit_stage=coder"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error when --path and env var are both absent")
	}
	if !strings.Contains(err.Error(), "state update") {
		t.Errorf("err: %v; want 'state update' substring", err)
	}
}

// TestStateUpdateCmd_BadFieldFormat exercises the parseFieldPairs failure
// branch reached through Cobra Execute.
func TestStateUpdateCmd_BadFieldFormat(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	cmd := newStateUpdateCmd()
	cmd.SetArgs([]string{"--path", path, "--field", "missing-equals"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("expected error for malformed --field, got nil")
	}
}

// TestStateClearCmd_RemovesFile drives `tekhton state clear` and confirms
// the file is gone afterwards.
func TestStateClearCmd_RemovesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	if err := state.New(path).Update(func(s *proto.StateSnapshotV1) {
		s.ExitStage = "tester"
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	cmd := newStateClearCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("clear: %v", err)
	}

	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Errorf("state file should be removed; stat err: %v", statErr)
	}
}

// TestStateClearCmd_AbsentFileIsNotAnError verifies clear is idempotent.
func TestStateClearCmd_AbsentFileIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "never_existed.json")
	cmd := newStateClearCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Errorf("clear on absent file: %v; want nil (idempotent)", err)
	}
}

// TestStateClearCmd_MissingPath exercises the missing-path error branch.
func TestStateClearCmd_MissingPath(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "")
	cmd := newStateClearCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err == nil {
		t.Fatal("expected error when --path and env var are both absent")
	}
}

// TestStateReadCmd_FullJSONOutput exercises the field-omitted branch (full
// snapshot JSON to stdout) of newStateReadCmd's RunE.
func TestStateReadCmd_FullJSONOutput(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	if err := state.New(path).Update(func(s *proto.StateSnapshotV1) {
		s.ExitStage = "review"
		s.MilestoneID = "m07"
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	cmd := newStateReadCmd()
	cmd.SetArgs([]string{"--path", path})
	// Capture stdout via os.Stdout pipe redirect since RunE uses fmt.Println.
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	oldStdout := os.Stdout
	os.Stdout = w
	t.Cleanup(func() { os.Stdout = oldStdout })

	execErr := cmd.Execute()
	w.Close()
	if execErr != nil {
		t.Fatalf("read: %v", execErr)
	}

	buf := make([]byte, 4096)
	n, _ := r.Read(buf)
	out := string(buf[:n])
	if !strings.Contains(out, `"exit_stage": "review"`) {
		t.Errorf("output missing exit_stage; got:\n%s", out)
	}
	if !strings.Contains(out, `"milestone_id": "m07"`) {
		t.Errorf("output missing milestone_id; got:\n%s", out)
	}
}
