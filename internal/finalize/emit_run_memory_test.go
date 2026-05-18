package finalize

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestEmitRunMemory_AppendsJSONLRecord(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	h := &EmitRunMemory{
		Git: func(_ string, _ ...string) ([]byte, error) {
			return []byte("a.go\nb.go\n"), nil
		},
	}
	in := &Input{
		ExitCode:   0,
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260517_120000",
		Milestone:  "m21",
		Result: &proto.RunResultV1{
			ElapsedSecs: 42,
			AgentCalls:  3,
		},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("EmitRunMemory.Run: %v", err)
	}
	path := filepath.Join(logDir, "RUN_MEMORY.jsonl")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read RUN_MEMORY: %v", err)
	}
	var rec runMemoryRecord
	if err := json.Unmarshal(data[:len(data)-1], &rec); err != nil {
		t.Fatalf("parse record: %v\n%s", err, data)
	}
	if rec.RunID != "run_20260517_120000" {
		t.Errorf("RunID = %q", rec.RunID)
	}
	if rec.Milestone != "m21" {
		t.Errorf("Milestone = %q", rec.Milestone)
	}
	if rec.Verdict != "PASS" {
		t.Errorf("Verdict = %q", rec.Verdict)
	}
	if rec.DurationSeconds != 42 {
		t.Errorf("DurationSeconds = %d", rec.DurationSeconds)
	}
	if rec.AgentCalls != 3 {
		t.Errorf("AgentCalls = %d", rec.AgentCalls)
	}
	wantFiles := []string{"a.go", "b.go"}
	if !strings.Contains(string(data), wantFiles[0]) || !strings.Contains(string(data), wantFiles[1]) {
		t.Errorf("expected files_touched to include %v; got %s", wantFiles, data)
	}
}

func TestEmitRunMemory_VerdictFailOnNonZeroExit(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	h := &EmitRunMemory{
		Git: func(_ string, _ ...string) ([]byte, error) {
			return nil, nil
		},
	}
	in := &Input{
		ExitCode:   1,
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260517_120000",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	data, _ := os.ReadFile(filepath.Join(logDir, "RUN_MEMORY.jsonl"))
	if !strings.Contains(string(data), `"verdict":"FAIL"`) {
		t.Errorf("expected FAIL verdict; got %s", data)
	}
}

func TestEmitRunMemory_PrunesAboveMaxEntries(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(logDir, "RUN_MEMORY.jsonl")
	// Seed with 5 entries.
	if err := os.WriteFile(path, []byte("a\nb\nc\nd\ne\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &EmitRunMemory{
		MaxEntries: 3,
		Git: func(_ string, _ ...string) ([]byte, error) {
			return nil, nil
		},
	}
	in := &Input{
		ExitCode:   0,
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260517_120000",
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var count int
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		count++
	}
	if count != 3 {
		t.Errorf("expected 3 lines after prune; got %d", count)
	}
}
