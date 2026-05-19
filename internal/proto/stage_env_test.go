package proto

import (
	"encoding/json"
	"testing"
)

func TestStageEnvProtoV1_Tag(t *testing.T) {
	if StageEnvProtoV1 != "tekhton.stage_env.v1" {
		t.Errorf("StageEnvProtoV1: got %q, want tekhton.stage_env.v1", StageEnvProtoV1)
	}
}

func TestStageEnvV1_EnsureProto_StampsTagWhenEmpty(t *testing.T) {
	s := &StageEnvV1{}
	s.EnsureProto()
	if s.Proto != StageEnvProtoV1 {
		t.Errorf("EnsureProto: got %q, want %q", s.Proto, StageEnvProtoV1)
	}
}

func TestStageEnvV1_EnsureProto_LeavesExistingTag(t *testing.T) {
	s := &StageEnvV1{Proto: "tekhton.stage_env.v999"}
	s.EnsureProto()
	if s.Proto != "tekhton.stage_env.v999" {
		t.Errorf("EnsureProto: overwrote existing proto %q", s.Proto)
	}
}

// TestStageEnvV1_RoundTrip covers the producer/consumer wire contract: the
// struct must encode to JSON and decode back without losing any field. Tests
// every group (runtime flags, log channel, config keys) so a new field
// added without serialization wiring fails red.
func TestStageEnvV1_RoundTrip(t *testing.T) {
	in := &StageEnvV1{
		Proto:            StageEnvProtoV1,
		MilestoneMode:    true,
		CurrentMilestone: "m26",
		Task:             "Stage and Finalize Env Contract",
		AutoAdvance:      true,
		AutoAdvanceLimit: 3,
		HumanMode:        false,
		HumanNotesTag:    "FEAT",
		LogDir:           "/tmp/logs",
		LogFile:          "/tmp/logs/20260519_120000_m26.log",
		Timestamp:        "20260519_120000",
		ConfigKeys: map[string]string{
			"PROJECT_NAME":          "tekhton",
			"CLAUDE_STANDARD_MODEL": "claude-opus-4-7",
			"ANALYZE_CMD":           "shellcheck tekhton.sh",
		},
	}

	b, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var out StageEnvV1
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if out.Proto != in.Proto {
		t.Errorf("Proto: got %q, want %q", out.Proto, in.Proto)
	}
	if out.MilestoneMode != in.MilestoneMode {
		t.Errorf("MilestoneMode: got %v, want %v", out.MilestoneMode, in.MilestoneMode)
	}
	if out.CurrentMilestone != in.CurrentMilestone {
		t.Errorf("CurrentMilestone: got %q, want %q", out.CurrentMilestone, in.CurrentMilestone)
	}
	if out.Task != in.Task {
		t.Errorf("Task: got %q, want %q", out.Task, in.Task)
	}
	if out.AutoAdvance != in.AutoAdvance {
		t.Errorf("AutoAdvance: got %v, want %v", out.AutoAdvance, in.AutoAdvance)
	}
	if out.AutoAdvanceLimit != in.AutoAdvanceLimit {
		t.Errorf("AutoAdvanceLimit: got %d, want %d", out.AutoAdvanceLimit, in.AutoAdvanceLimit)
	}
	if out.HumanMode != in.HumanMode {
		t.Errorf("HumanMode: got %v, want %v", out.HumanMode, in.HumanMode)
	}
	if out.HumanNotesTag != in.HumanNotesTag {
		t.Errorf("HumanNotesTag: got %q, want %q", out.HumanNotesTag, in.HumanNotesTag)
	}
	if out.LogDir != in.LogDir {
		t.Errorf("LogDir: got %q, want %q", out.LogDir, in.LogDir)
	}
	if out.LogFile != in.LogFile {
		t.Errorf("LogFile: got %q, want %q", out.LogFile, in.LogFile)
	}
	if out.Timestamp != in.Timestamp {
		t.Errorf("Timestamp: got %q, want %q", out.Timestamp, in.Timestamp)
	}
	if len(out.ConfigKeys) != len(in.ConfigKeys) {
		t.Fatalf("ConfigKeys size: got %d, want %d", len(out.ConfigKeys), len(in.ConfigKeys))
	}
	for k, v := range in.ConfigKeys {
		if out.ConfigKeys[k] != v {
			t.Errorf("ConfigKeys[%q]: got %q, want %q", k, out.ConfigKeys[k], v)
		}
	}
}
