package finalize

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestCausalLogFinalize_EmitsPipelineEndEventAndArchives(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, ".claude", "logs", "CAUSAL_LOG.jsonl")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logPath, []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	h := &CausalLogFinalize{
		Path:      logPath,
		Retention: 5,
		Cap:       0,
	}
	in := &Input{
		ExitCode:    0,
		Disposition: proto.RunDispositionSuccess,
		ProjectDir:  dir,
		Timestamp:   "20260517_120000",
		Milestone:   "m21",
		Result:      &proto.RunResultV1{RunID: "run_test"},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("CausalLogFinalize.Run: %v", err)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if !strings.Contains(string(data), `"type":"pipeline_end"`) {
		t.Errorf("expected pipeline_end event; got %s", data)
	}
	if !strings.Contains(string(data), `"exit_code":0`) {
		t.Errorf("expected exit_code in verdict; got %s", data)
	}

	archive := filepath.Join(dir, ".claude", "logs", "runs", "CAUSAL_LOG_run_test.jsonl")
	if _, err := os.Stat(archive); err != nil {
		t.Errorf("expected archive at %s; stat err=%v", archive, err)
	}
}

func TestCausalLogFinalize_RespectsDisableFlag(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CAUSAL_LOG_ENABLED", "false")
	h := &CausalLogFinalize{}
	in := &Input{
		ProjectDir: dir,
		Timestamp:  "ts",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Errorf("disabled causal log should not error; got %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, ".claude", "logs", "CAUSAL_LOG.jsonl")); err == nil {
		t.Errorf("expected no log file when disabled")
	}
}

func TestCausalLogFinalize_FailureExitCodeReportsFailedStatus(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, ".claude", "logs", "CAUSAL_LOG.jsonl")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		t.Fatal(err)
	}
	h := &CausalLogFinalize{Path: logPath}
	in := &Input{
		ExitCode:    1,
		Disposition: proto.RunDispositionFailure,
		ProjectDir:  dir,
		Timestamp:   "20260517_120000",
		Milestone:   "m21",
		Result:      &proto.RunResultV1{RunID: "run_fail"},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if !strings.Contains(string(data), `"status":"failed"`) {
		t.Errorf("expected failed status in verdict; got %s", data)
	}
}
