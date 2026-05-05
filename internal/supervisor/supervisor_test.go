package supervisor

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// ---------------------------------------------------------------------------
// Run — validation rejection paths only. The success path (real subprocess
// + stdout decode + activity timer) lives in run_test.go where the
// fake_agent.sh fixture is available.
// ---------------------------------------------------------------------------

func TestSupervisor_Run_NilRequestRejected(t *testing.T) {
	sup := New(nil, nil)
	_, err := sup.Run(context.Background(), nil)
	if err == nil {
		t.Fatal("expected error for nil request, got nil")
	}
}

func TestSupervisor_Run_RejectsInvalidRequest(t *testing.T) {
	sup := New(nil, nil)
	cases := []struct {
		name string
		req  *proto.AgentRequestV1
	}{
		{"missing proto", &proto.AgentRequestV1{Label: "c", Model: "m", PromptFile: "/p"}},
		{"wrong proto", &proto.AgentRequestV1{Proto: "tekhton.agent.request.v999", Label: "c", Model: "m", PromptFile: "/p"}},
		{"missing label", &proto.AgentRequestV1{Proto: proto.AgentRequestProtoV1, Model: "m", PromptFile: "/p"}},
		{"missing model", &proto.AgentRequestV1{Proto: proto.AgentRequestProtoV1, Label: "c", PromptFile: "/p"}},
		{"missing prompt_file", &proto.AgentRequestV1{Proto: proto.AgentRequestProtoV1, Label: "c", Model: "m"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := sup.Run(context.Background(), tc.req)
			if err == nil {
				t.Fatal("expected error, got nil")
			}
			if !errors.Is(err, proto.ErrInvalidRequest) {
				t.Errorf("error not wrapped in ErrInvalidRequest: %v", err)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// AgentSpec ↔ proto round-trip
// ---------------------------------------------------------------------------

func TestAgentSpec_ToProto(t *testing.T) {
	spec := &AgentSpec{
		RunID:           "rid",
		Label:           "tester",
		Model:           "claude-haiku-4-5-20251001",
		MaxTurns:        15,
		PromptFile:      "/tmp/p",
		WorkingDir:      "/tmp/w",
		Timeout:         30 * time.Minute,
		ActivityTimeout: 10 * time.Minute,
		Env:             map[string]string{"K": "V"},
	}
	p := spec.ToProto()
	if p.Proto != proto.AgentRequestProtoV1 {
		t.Errorf("Proto: got %q", p.Proto)
	}
	if p.TimeoutSecs != 1800 {
		t.Errorf("TimeoutSecs: got %d, want 1800", p.TimeoutSecs)
	}
	if p.ActivityTimeoutSecs != 600 {
		t.Errorf("ActivityTimeoutSecs: got %d, want 600", p.ActivityTimeoutSecs)
	}
	if p.EnvOverrides["K"] != "V" {
		t.Errorf("EnvOverrides: got %v", p.EnvOverrides)
	}
}

func TestAgentSpec_ToProto_NilReturnsNil(t *testing.T) {
	var spec *AgentSpec
	if got := spec.ToProto(); got != nil {
		t.Errorf("nil spec.ToProto() should be nil, got %v", got)
	}
}

func TestFromProto_DurationConversion(t *testing.T) {
	p := &proto.AgentResultV1{
		Proto:      proto.AgentResultProtoV1,
		RunID:      "rid",
		Label:      "coder",
		ExitCode:   0,
		TurnsUsed:  3,
		DurationMs: 65000,
		Outcome:    proto.OutcomeSuccess,
	}
	r := FromProto(p)
	if r.Duration != 65*time.Second {
		t.Errorf("Duration: got %v, want 65s", r.Duration)
	}
	if r.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: got %q", r.Outcome)
	}
}

func TestFromProto_NilReturnsNil(t *testing.T) {
	if got := FromProto(nil); got != nil {
		t.Errorf("FromProto(nil): got %v, want nil", got)
	}
}

// ---------------------------------------------------------------------------
// Error taxonomy mapping
// ---------------------------------------------------------------------------

func TestCategoryTransient_UpstreamDefaultsTransient(t *testing.T) {
	cases := []struct {
		sub  string
		want bool
	}{
		{SubcatAPIRateLimit, true},
		{SubcatAPIOverloaded, true},
		{SubcatAPI500, true},
		{SubcatAPIAuth, false}, // V3: auth failures are NOT transient
		{SubcatAPITimeout, true},
		{SubcatAPIUnknown, true},
	}
	for _, tc := range cases {
		t.Run(tc.sub, func(t *testing.T) {
			if got := CategoryTransient(CategoryUpstream, tc.sub); got != tc.want {
				t.Errorf("CategoryTransient(UPSTREAM, %s): got %v, want %v", tc.sub, got, tc.want)
			}
		})
	}
}

func TestCategoryTransient_Environment(t *testing.T) {
	if !CategoryTransient(CategoryEnvironment, SubcatOOM) {
		t.Error("OOM should be transient (V3 parity)")
	}
	if !CategoryTransient(CategoryEnvironment, SubcatNetwork) {
		t.Error("network should be transient (V3 parity)")
	}
	if CategoryTransient(CategoryEnvironment, SubcatDiskFull) {
		t.Error("disk_full should NOT be transient (V3 parity)")
	}
	if CategoryTransient(CategoryEnvironment, SubcatPermissions) {
		t.Error("permissions should NOT be transient (V3 parity)")
	}
}

func TestCategoryTransient_UnknownCategoryNotTransient(t *testing.T) {
	if CategoryTransient("MYSTERY", "anything") {
		t.Error("unknown category must be conservative (return false)")
	}
}

// ---------------------------------------------------------------------------
// New + binary configuration
// ---------------------------------------------------------------------------

func TestNew_AcceptsNilSeams(t *testing.T) {
	sup := New(nil, nil)
	if sup == nil {
		t.Fatal("New returned nil")
	}
}

func TestNew_DefaultsToClaudeBinary(t *testing.T) {
	t.Setenv(AgentBinaryEnv, "")
	sup := New(nil, nil)
	if sup.binary != defaultBinary {
		t.Errorf("binary: got %q, want %q", sup.binary, defaultBinary)
	}
}

func TestNew_HonorsEnvOverride(t *testing.T) {
	t.Setenv(AgentBinaryEnv, "/path/to/fake_agent.sh")
	sup := New(nil, nil)
	if sup.binary != "/path/to/fake_agent.sh" {
		t.Errorf("binary: got %q, want /path/to/fake_agent.sh", sup.binary)
	}
}

func TestSetBinary_OverridesAfterConstruction(t *testing.T) {
	sup := New(nil, nil)
	sup.SetBinary("/tmp/fake")
	if sup.binary != "/tmp/fake" {
		t.Errorf("binary: got %q, want /tmp/fake", sup.binary)
	}
}

