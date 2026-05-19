package runner

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/config"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestStageEnvUniformity is the m26 acceptance criterion: every stage
// returned by defaultStageOrder() must receive an IDENTICAL composed env.
// Failure mode this guards: a future patch that re-introduces per-stage
// env curation (the legacy 85b00ac shape) would let one stage see
// MILESTONE_MODE while another doesn't, silently re-creating the unbound-
// variable cascade m26 closed.
func TestStageEnvUniformity_AllStagesSameKeys(t *testing.T) {
	cfg := &config.Config{Values: map[string]string{
		"PROJECT_NAME":          "tekhton",
		"CLAUDE_STANDARD_MODEL": "claude-opus-4-7",
		"ANALYZE_CMD":           "shellcheck tekhton.sh",
		"INTAKE_MAX_TURNS":      "10",
	}}
	r := New(nil)
	r.Env = NewEnvBuilder(cfg, LogContext{Dir: "/tmp/logs", Timestamp: "20260519_120000"})

	req := &proto.RunRequestV1{
		Mode:       proto.RunModeMilestone,
		Milestone:  "m26",
		Task:       "stage env contract",
		ProjectDir: "/tmp/p",
	}
	pr := r.buildPipelineRequest(req)
	if pr.StageEnv == nil {
		t.Fatal("buildPipelineRequest produced nil StageEnv")
	}

	stages := defaultStageOrder()
	if len(pr.StageEnv) != len(stages) {
		t.Fatalf("StageEnv covers %d stages, expected %d (%v)",
			len(pr.StageEnv), len(stages), stages)
	}

	// Capture the key set of the first stage; every other stage must
	// have the same set of keys AND the same values.
	first := pr.StageEnv[stages[0]]
	if first == nil {
		t.Fatalf("StageEnv missing entry for stage %q", stages[0])
	}
	for _, stage := range stages[1:] {
		env := pr.StageEnv[stage]
		if env == nil {
			t.Errorf("StageEnv missing entry for stage %q", stage)
			continue
		}
		if len(env) != len(first) {
			t.Errorf("stage %q has %d keys; %q has %d (env not uniform)",
				stage, len(env), stages[0], len(first))
		}
		for k, v := range first {
			if got, ok := env[k]; !ok {
				t.Errorf("stage %q missing key %q present in %q", stage, k, stages[0])
			} else if got != v {
				t.Errorf("stage %q[%q] = %q; %q[%q] = %q (values diverged)",
					stage, k, got, stages[0], k, v)
			}
		}
	}
}

// TestStageEnvUniformity_RuntimeFlagsPresent confirms the smoking-gun
// keys (the ones whose absence under set -u caused the m20-m22 dogfood
// to actually crash) are reachable in every stage env after buildPipelineRequest.
func TestStageEnvUniformity_RuntimeFlagsPresent(t *testing.T) {
	r := New(nil)
	r.Env = NewEnvBuilder(nil, LogContext{})
	pr := r.buildPipelineRequest(&proto.RunRequestV1{
		Mode:      proto.RunModeMilestone,
		Milestone: "m26",
		Task:      "stage env contract",
	})
	must := []string{"MILESTONE_MODE", "_CURRENT_MILESTONE", "TASK",
		"AUTO_ADVANCE", "HUMAN_MODE", "HUMAN_NOTES_TAG"}
	for _, stage := range defaultStageOrder() {
		env := pr.StageEnv[stage]
		for _, key := range must {
			if _, ok := env[key]; !ok {
				t.Errorf("stage %q missing required runtime-flag key %q",
					stage, key)
			}
		}
		if env["MILESTONE_MODE"] != "true" {
			t.Errorf("stage %q MILESTONE_MODE: got %q, want true",
				stage, env["MILESTONE_MODE"])
		}
		if env["_CURRENT_MILESTONE"] != "m26" {
			t.Errorf("stage %q _CURRENT_MILESTONE: got %q, want m26",
				stage, env["_CURRENT_MILESTONE"])
		}
	}
}
