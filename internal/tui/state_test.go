package tui

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestStateSaveAtomicRoundTrip(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "tui_status.json")

	st := NewState()
	st.Payload.Milestone = "m23"
	st.Payload.StageLabel = "Coder"
	st.AllocateLifecycleID("Coder")
	st.PipelineStartTS = 1000

	if err := st.SaveAtomic(path); err != nil {
		t.Fatalf("SaveAtomic: %v", err)
	}

	loaded, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.Payload.Milestone != "m23" {
		t.Errorf("milestone: got %q, want m23", loaded.Payload.Milestone)
	}
	if loaded.Payload.CurrentLifecycleID != "Coder#1" {
		t.Errorf("lifecycle id: got %q, want Coder#1", loaded.Payload.CurrentLifecycleID)
	}
	if loaded.PipelineStartTS != 1000 {
		t.Errorf("pipeline start ts: got %d", loaded.PipelineStartTS)
	}
	if loaded.CycleCounters["Coder"] != 1 {
		t.Errorf("cycle counter: got %d", loaded.CycleCounters["Coder"])
	}
}

func TestStateLoadMissingFile(t *testing.T) {
	tmp := t.TempDir()
	_, err := Load(filepath.Join(tmp, "missing.json"))
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("got %v, want ErrNotFound", err)
	}
}

func TestStateAtomicityUnderFault(t *testing.T) {
	// Pre-populate destination with garbage. SaveAtomic must either succeed
	// (in which case destination is valid JSON) or fail (leaving the garbage
	// in place untouched), but never write a partial file.
	tmp := t.TempDir()
	path := filepath.Join(tmp, "tui_status.json")
	if err := os.WriteFile(path, []byte("GARBAGE_NOT_JSON"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	st := NewState()
	st.Payload.Milestone = "m23"
	if err := st.SaveAtomic(path); err != nil {
		t.Fatalf("SaveAtomic: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readback: %v", err)
	}
	if len(data) == 0 || data[0] != '{' {
		t.Errorf("destination should hold the new JSON after atomic rename, got: %s", string(data))
	}
	// Tmp file must be cleaned up.
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("tmpfile should not persist after rename, stat err: %v", err)
	}
}

func TestStateLoadLegacyBareShape(t *testing.T) {
	// Legacy bare-payload shape (pre-m23). Loader must accept it.
	tmp := t.TempDir()
	path := filepath.Join(tmp, "tui_status.json")
	legacy := `{"version":1,"milestone":"m22","stage_label":"Coder","stages_complete":[]}`
	if err := os.WriteFile(path, []byte(legacy), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	st, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if st.Payload.Milestone != "m22" {
		t.Errorf("milestone: got %q, want m22", st.Payload.Milestone)
	}
	if st.Payload.StageLabel != "Coder" {
		t.Errorf("stage_label: got %q", st.Payload.StageLabel)
	}
}

func TestStateEncodeEnvelopeShape(t *testing.T) {
	st := NewState()
	st.Payload.Milestone = "m23"
	st.Payload.RunID = "20260525_120000"
	data, err := st.Encode()
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	// Spot-check that the proto field is present at the root.
	if string(data[0]) != "{" {
		t.Fatalf("encode should produce JSON object, got: %s", string(data))
	}
	// Decode back through the proto envelope to verify shape.
	var env proto.TUIStatusV1Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("envelope decode: %v", err)
	}
	if env.Proto != proto.TUIStatusV1 {
		t.Errorf("proto: got %q, want %q", env.Proto, proto.TUIStatusV1)
	}
	if env.Payload.Milestone != "m23" {
		t.Errorf("payload milestone: got %q", env.Payload.Milestone)
	}
}
