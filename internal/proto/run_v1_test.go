package proto

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestRunRequestValidateOK(t *testing.T) {
	r := &RunRequestV1{
		Proto:       RunRequestProtoV1,
		Mode:        RunModeTask,
		Task:        "echo hello",
		ProjectDir:  "/proj",
		TekhtonHome: "/home",
	}
	if err := r.Validate(); err != nil {
		t.Fatalf("validate task ok: %v", err)
	}
}

func TestRunRequestValidateRejects(t *testing.T) {
	tests := []struct {
		name    string
		mut     func(*RunRequestV1)
		wantSub string
	}{
		{"nil_proto", func(r *RunRequestV1) { r.Proto = "" }, "missing proto"},
		{"wrong_proto", func(r *RunRequestV1) { r.Proto = "tekhton.run.request.v0" }, "wrong proto"},
		{"unknown_mode", func(r *RunRequestV1) { r.Mode = "weird" }, "unknown mode"},
		{"task_no_task", func(r *RunRequestV1) { r.Task = "" }, "task mode requires non-empty task"},
		{"missing_proj", func(r *RunRequestV1) { r.ProjectDir = "" }, "missing project_dir"},
		{"missing_home", func(r *RunRequestV1) { r.TekhtonHome = "" }, "missing tekhton_home"},
		{"neg_timeout", func(r *RunRequestV1) { r.AutonomousTimeoutSecs = -1 }, "autonomous_timeout_secs"},
		{"neg_attempts", func(r *RunRequestV1) { r.MaxPipelineAttempts = -1 }, "max_pipeline_attempts"},
		{"neg_calls", func(r *RunRequestV1) { r.MaxAutonomousAgentCalls = -1 }, "max_autonomous_agent_calls"},
		{"neg_aa_limit", func(r *RunRequestV1) { r.AutoAdvanceLimit = -1 }, "auto_advance_limit"},
		{"aa_no_milestone", func(r *RunRequestV1) { r.AutoAdvance = true }, "auto-advance requires milestone"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := &RunRequestV1{
				Proto:       RunRequestProtoV1,
				Mode:        RunModeTask,
				Task:        "x",
				ProjectDir:  "/p",
				TekhtonHome: "/h",
			}
			tc.mut(r)
			err := r.Validate()
			if err == nil {
				t.Fatalf("want error, got nil")
			}
			if !errors.Is(err, ErrInvalidRunRequest) {
				t.Fatalf("want sentinel ErrInvalidRunRequest; got %v", err)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("error %q missing %q", err.Error(), tc.wantSub)
			}
		})
	}
}

func TestRunRequestMilestoneOK(t *testing.T) {
	r := &RunRequestV1{
		Proto:       RunRequestProtoV1,
		Mode:        RunModeMilestone,
		Milestone:   "m99",
		AutoAdvance: true,
		ProjectDir:  "/p",
		TekhtonHome: "/h",
	}
	if err := r.Validate(); err != nil {
		t.Fatalf("milestone+aa ok: %v", err)
	}
}

func TestRunRequestMilestoneNoID(t *testing.T) {
	r := &RunRequestV1{
		Proto:       RunRequestProtoV1,
		Mode:        RunModeMilestone,
		ProjectDir:  "/p",
		TekhtonHome: "/h",
	}
	if err := r.Validate(); err == nil {
		t.Fatalf("want error for empty milestone id")
	}
}

func TestRunRequestEnsureProto(t *testing.T) {
	r := &RunRequestV1{}
	r.EnsureProto()
	if r.Proto != RunRequestProtoV1 {
		t.Fatalf("proto not stamped: %q", r.Proto)
	}
	res := &RunResultV1{}
	res.EnsureProto()
	if res.Proto != RunResultProtoV1 {
		t.Fatalf("result proto not stamped: %q", res.Proto)
	}
}

func TestRunResultMarshalRoundTrip(t *testing.T) {
	res := &RunResultV1{
		Proto:       RunResultProtoV1,
		Disposition: RunDispositionFailure,
		Attempts:    3,
		AgentCalls:  17,
		ElapsedSecs: 42,
		Recovery:    "save_exit",
	}
	b, err := res.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got RunResultV1
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Disposition != res.Disposition || got.Attempts != res.Attempts {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}

func TestIsKnownRunMode(t *testing.T) {
	for _, m := range []string{RunModeTask, RunModeHuman, RunModeMilestone, RunModeResume} {
		if !IsKnownRunMode(m) {
			t.Fatalf("expected known: %s", m)
		}
	}
	if IsKnownRunMode("nonsense") {
		t.Fatalf("expected unknown")
	}
}
