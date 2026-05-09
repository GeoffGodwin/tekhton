package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestStageEmitToStdout(t *testing.T) {
	// stage.go writes the envelope via fmt.Println, which goes to os.Stdout
	// directly (not cobra's cmd.OutOrStdout()). Redirect os.Stdout through a
	// pipe so the test can read what was printed.
	origStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	defer func() { os.Stdout = origStdout }()

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
	root.SetOut(io.Discard)
	root.SetErr(os.Stderr)
	execErr := root.Execute()
	_ = w.Close()
	out, _ := io.ReadAll(r)
	if execErr != nil {
		t.Fatalf("Execute: %v", execErr)
	}

	res := &proto.StageResultV1{}
	if err := json.Unmarshal(bytes.TrimSpace(out), res); err != nil {
		t.Fatalf("unmarshal stdout %q: %v", string(out), err)
	}
	if res.Proto != proto.StageResultProtoV1 {
		t.Fatalf("proto: got %q want %q", res.Proto, proto.StageResultProtoV1)
	}
	if res.Stage != "intake" || res.Verdict != "pass" {
		t.Fatalf("stage/verdict: got %q/%q want intake/pass", res.Stage, res.Verdict)
	}
	if res.ExitReason != "ok" || res.NextAction != "accept" {
		t.Fatalf("reason/next: got %q/%q want ok/accept", res.ExitReason, res.NextAction)
	}
	if res.AgentCalls != 1 || res.DurationSec != 12 {
		t.Fatalf("counts: agent_calls=%d duration_sec=%d (want 1/12)", res.AgentCalls, res.DurationSec)
	}
	if err := res.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
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
