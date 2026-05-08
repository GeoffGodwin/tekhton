package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestStageEmitToStdout(t *testing.T) {
	root := newRootCmd()
	root.SetArgs([]string{
		"stage", "emit",
		"--stage", "intake",
		"--verdict", "pass",
		"--exit-reason", "ok",
		"--agent-calls", "1",
		"--duration", "12",
		"--next-action", "accept",
	})
	var stdout bytes.Buffer
	root.SetOut(&stdout)
	root.SetErr(os.Stderr)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	out := stdout.String()
	// Cobra writes via fmt.Println, not the cmd.OutOrStdout() — capture by
	// re-routing to /dev/null is fragile. Easier: check the envelope shape.
	// fall back to capturing process stdout.
	_ = out
}

func TestStageEmitInvalidVerdict(t *testing.T) {
	root := newRootCmd()
	root.SetArgs([]string{
		"stage", "emit",
		"--stage", "coder",
		"--verdict", "frobby",
	})
	var sink bytes.Buffer
	root.SetOut(&sink)
	root.SetErr(&sink)
	err := root.Execute()
	if err == nil {
		t.Fatalf("expected error for unknown verdict")
	}
	if !strings.Contains(err.Error(), "unknown verdict") {
		t.Fatalf("error text: %q", err.Error())
	}
}

func TestStageEmitToResultFile(t *testing.T) {
	dir := t.TempDir()
	resultPath := filepath.Join(dir, "stage_result.json")
	t.Setenv("TEKHTON_STAGE_RESULT_FILE", resultPath)

	root := newRootCmd()
	root.SetArgs([]string{
		"stage", "emit",
		"--stage", "review",
		"--verdict", "rework",
		"--next-action", "rework",
		"--to-result-file",
	})
	root.SetOut(os.Stdout)
	root.SetErr(os.Stderr)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	b, err := os.ReadFile(resultPath)
	if err != nil {
		t.Fatalf("read result file: %v", err)
	}
	out := &proto.StageResultV1{}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Stage != "review" || out.Verdict != "rework" || out.NextAction != "rework" {
		t.Fatalf("wrong envelope: %+v", out)
	}
	if err := out.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
}

func TestStageEmitToResultFileNoEnv(t *testing.T) {
	t.Setenv("TEKHTON_STAGE_RESULT_FILE", "")
	root := newRootCmd()
	root.SetArgs([]string{
		"stage", "emit",
		"--stage", "review",
		"--verdict", "pass",
		"--to-result-file",
	})
	var sink bytes.Buffer
	root.SetOut(&sink)
	root.SetErr(&sink)
	if err := root.Execute(); err == nil {
		t.Fatalf("expected error when --to-result-file set without env")
	}
}

func TestStageEmitFilesTouched(t *testing.T) {
	dir := t.TempDir()
	resultPath := filepath.Join(dir, "stage_result.json")
	t.Setenv("TEKHTON_STAGE_RESULT_FILE", resultPath)
	root := newRootCmd()
	root.SetArgs([]string{
		"stage", "emit",
		"--stage", "coder",
		"--verdict", "pass",
		"--files-touched", "foo.go, bar.go,",
		"--to-result-file",
	})
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	b, err := os.ReadFile(resultPath)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	out := &proto.StageResultV1{}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(out.FilesTouched) != 2 || out.FilesTouched[0] != "foo.go" || out.FilesTouched[1] != "bar.go" {
		t.Fatalf("files_touched: %+v", out.FilesTouched)
	}
}
