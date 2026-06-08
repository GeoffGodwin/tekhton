package coder

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/coder/buildfix"
	"github.com/geoffgodwin/tekhton/internal/coder/prerun"
	"github.com/geoffgodwin/tekhton/internal/coder/scout"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fixtureExpected captures the JSON shape under
// internal/stages/coder/testdata/fixtures/<scenario>/expected.json.
//
// Only the fields the parity assertions touch are decoded. The comment
// field is documentation for fixture maintainers.
type fixtureExpected struct {
	Comment                       string `json:"comment"`
	PrerunStatus                  string `json:"prerun_status"`
	PrerunAttempts                int    `json:"prerun_attempts"`
	ScoutInvoked                  bool   `json:"scout_invoked"`
	ScoutRecommendedCoder         int    `json:"scout_recommended_coder"`
	AgentInvoked                  bool   `json:"agent_invoked"`
	AgentTemplate                 string `json:"agent_template"`
	CompletionGateInvoked         bool   `json:"completion_gate_invoked"`
	BuildGateInvoked              bool   `json:"build_gate_invoked"`
	BuildFixInvoked               bool   `json:"buildfix_invoked"`
	BuildFixDecision              string `json:"buildfix_decision"`
	BuildFixOutcome               string `json:"buildfix_outcome"`
	BuildFixAttempts              int    `json:"buildfix_attempts"`
	BuildFixProgressGateFailures  int    `json:"buildfix_progress_gate_failures"`
	Verdict                       string `json:"verdict"`
	ExitReason                    string `json:"exit_reason"`
}

func loadOrchestratorFixture(t *testing.T, scenario string) fixtureExpected {
	t.Helper()
	path := filepath.Join("testdata", "fixtures", scenario, "expected.json")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("fixture %s: read expected.json: %v", scenario, err)
	}
	var exp fixtureExpected
	if err := json.Unmarshal(b, &exp); err != nil {
		t.Fatalf("fixture %s: decode expected.json: %v", scenario, err)
	}
	return exp
}

// orchestratorRecorder threads through Deps and captures every sub-package
// invocation. Tests construct one per scenario, drive Run, and assert the
// recorded sequence matches the fixture's expectations.
type orchestratorRecorder struct {
	prerunCalled    bool
	scoutCalled     bool
	agentCalled     bool
	completionCalled bool
	buildGateCalled bool
	buildFixCalled  bool

	agentLabel       string
	agentTemplate    string
	prerunStatus     prerun.Status
	prerunAttempts   int
	scoutRecCoder    int
	buildFixDecision buildfix.Decision
	buildFixOutcome  buildfix.Outcome
	buildFixAttempts int
	buildFixGateFail int
}

// newRecordingDeps returns a Deps populated with recording stubs for every
// sub-package the parity tests exercise. The seedFn lets each scenario pre-
// configure recorder state (prerun status, scout recommendation, buildfix
// outcome, etc.) before Run dispatches.
func (rec *orchestratorRecorder) newDeps(seedFn func(rec *orchestratorRecorder)) *Deps {
	if seedFn != nil {
		seedFn(rec)
	}
	deps := DefaultDeps()
	deps.PrerunRun = func(ctx context.Context, cfg *prerun.Config) (*prerun.Result, error) {
		rec.prerunCalled = true
		return &prerun.Result{Status: rec.prerunStatus, Attempts: rec.prerunAttempts}, nil
	}
	deps.ScoutRun = func(ctx context.Context, cfg *scout.Config) (*scout.Result, error) {
		rec.scoutCalled = true
		return &scout.Result{
			Estimate: &scout.Estimate{RecommendedCoder: rec.scoutRecCoder},
		}, nil
	}
	deps.RunAgent = func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		rec.agentCalled = true
		rec.agentLabel = req.Label
		return &proto.AgentResultV1{TurnsUsed: 10}, nil
	}
	deps.RenderPrompt = func(name string, vars map[string]string) (string, error) {
		if rec.agentTemplate == "" {
			rec.agentTemplate = name
		}
		return "prompt-body", nil
	}
	deps.RunCompletionGate = func(ctx context.Context) error {
		rec.completionCalled = true
		return nil
	}
	deps.RunBuildGate = func(ctx context.Context, label string) error {
		rec.buildGateCalled = true
		if rec.buildFixDecision != "" {
			// signal failure so orchestrator delegates to BuildFixRun
			return errSimulatedBuildFail
		}
		return nil
	}
	deps.BuildFixRun = func(ctx context.Context, cfg *buildfix.LoopConfig, paths *buildfix.Paths) (*buildfix.LoopResult, error) {
		rec.buildFixCalled = true
		return &buildfix.LoopResult{
			Outcome:              rec.buildFixOutcome,
			Attempts:             rec.buildFixAttempts,
			Classification:       rec.buildFixDecision,
			ProgressGateFailures: rec.buildFixGateFail,
		}, nil
	}
	deps.IsSubstantiveWork = func() bool { return true }
	return deps
}

// driveOrchestrator builds an orchestrator with a seeded CODER_SUMMARY.md,
// wires recording deps, and runs the stage. Returns the recorder and the
// stage result so each test can assert against both.
func driveOrchestrator(t *testing.T, scenario string, exp fixtureExpected, scoutEnabled bool, seedFn func(rec *orchestratorRecorder)) (*orchestratorRecorder, *proto.StageResultV1) {
	t.Helper()

	dir := t.TempDir()
	summary := filepath.Join(dir, "CODER_SUMMARY.md")
	if err := os.WriteFile(summary, []byte("## Status: COMPLETE\n"), 0o644); err != nil {
		t.Fatalf("seed summary: %v", err)
	}
	t.Setenv("CODER_SUMMARY_FILE", summary)
	if scoutEnabled {
		t.Setenv("HUMAN_NOTE_COUNT", "1")
		t.Setenv("NOTES_SHOULD_CLAIM", "true")
		t.Setenv("DYNAMIC_TURNS_ENABLED", "true")
		t.Setenv("ESTIMATED_TURNS", "0")
	} else {
		t.Setenv("HUMAN_NOTE_COUNT", "0")
		t.Setenv("NOTES_SHOULD_CLAIM", "false")
		t.Setenv("SCOUT_CACHED", "true")
	}

	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "parity-" + scenario,
		ResultFile: "/dev/null",
	}
	o := newOrchestrator(req)

	rec := &orchestratorRecorder{}
	o.withDeps(rec.newDeps(seedFn))

	res, err := o.Run(context.Background())
	if err != nil {
		t.Fatalf("Run err: %v", err)
	}
	return rec, res
}

func assertOrchestratorParity(t *testing.T, scenario string, exp fixtureExpected, rec *orchestratorRecorder, res *proto.StageResultV1) {
	t.Helper()
	if rec.prerunCalled != true {
		t.Errorf("%s: prerunCalled=%v; want true (orchestrator always calls prerun)", scenario, rec.prerunCalled)
	}
	if rec.scoutCalled != exp.ScoutInvoked {
		t.Errorf("%s: scoutCalled=%v; want %v", scenario, rec.scoutCalled, exp.ScoutInvoked)
	}
	if rec.agentCalled != exp.AgentInvoked {
		t.Errorf("%s: agentCalled=%v; want %v", scenario, rec.agentCalled, exp.AgentInvoked)
	}
	if exp.AgentTemplate != "" && rec.agentTemplate != exp.AgentTemplate {
		t.Errorf("%s: agentTemplate=%q; want %q", scenario, rec.agentTemplate, exp.AgentTemplate)
	}
	if rec.completionCalled != exp.CompletionGateInvoked {
		t.Errorf("%s: completionCalled=%v; want %v", scenario, rec.completionCalled, exp.CompletionGateInvoked)
	}
	if rec.buildGateCalled != exp.BuildGateInvoked {
		t.Errorf("%s: buildGateCalled=%v; want %v", scenario, rec.buildGateCalled, exp.BuildGateInvoked)
	}
	if rec.buildFixCalled != exp.BuildFixInvoked {
		t.Errorf("%s: buildFixCalled=%v; want %v", scenario, rec.buildFixCalled, exp.BuildFixInvoked)
	}
	if exp.BuildFixDecision != "" && string(rec.buildFixDecision) != exp.BuildFixDecision {
		t.Errorf("%s: buildFixDecision=%q; want %q", scenario, rec.buildFixDecision, exp.BuildFixDecision)
	}
	if exp.BuildFixOutcome != "" && string(rec.buildFixOutcome) != exp.BuildFixOutcome {
		t.Errorf("%s: buildFixOutcome=%q; want %q", scenario, rec.buildFixOutcome, exp.BuildFixOutcome)
	}
	if string(res.Verdict) != exp.Verdict {
		t.Errorf("%s: verdict=%q; want %q", scenario, res.Verdict, exp.Verdict)
	}
	if res.ExitReason != exp.ExitReason {
		t.Errorf("%s: exitReason=%q; want %q", scenario, res.ExitReason, exp.ExitReason)
	}
}

// TestParity_Fixtures drives all 8 fixtures through the orchestrator and
// asserts each captured invocation sequence matches the recorded
// expectations. The fixtures are the m39.1, m39.2, and m39.3 sub-package
// scenarios promoted to orchestration-level coverage per the m39.4 design.
func TestParity_Fixtures(t *testing.T) {
	cases := []struct {
		scenario     string
		scoutEnabled bool
		seed         func(rec *orchestratorRecorder)
	}{
		{
			scenario:     "coder-clean-baseline",
			scoutEnabled: false,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusClean
			},
		},
		{
			scenario:     "coder-prerun-fix-succeeds",
			scoutEnabled: false,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusFixed
				rec.prerunAttempts = 1
			},
		},
		{
			scenario:     "coder-prerun-fix-fails",
			scoutEnabled: false,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusFixFailed
				rec.prerunAttempts = 1
			},
		},
		{
			scenario:     "coder-scout-trivial",
			scoutEnabled: true,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusClean
				rec.scoutRecCoder = 20
			},
		},
		{
			scenario:     "coder-scout-large-with-split",
			scoutEnabled: true,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusClean
				rec.scoutRecCoder = 120
			},
		},
		{
			scenario:     "coder-buildfix-code-dominant-passes",
			scoutEnabled: false,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusClean
				rec.buildFixDecision = buildfix.DecisionCodeDominant
				rec.buildFixOutcome = buildfix.OutcomePassed
				rec.buildFixAttempts = 1
			},
		},
		{
			scenario:     "coder-buildfix-mixed-uncertain-retry",
			scoutEnabled: false,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusClean
				rec.buildFixDecision = buildfix.DecisionMixedUncertain
				rec.buildFixOutcome = "save_exit"
				rec.buildFixAttempts = 1
			},
		},
		{
			scenario:     "coder-buildfix-progress-stalls",
			scoutEnabled: false,
			seed: func(rec *orchestratorRecorder) {
				rec.prerunStatus = prerun.StatusClean
				rec.buildFixDecision = buildfix.DecisionCodeDominant
				rec.buildFixOutcome = buildfix.OutcomeNoProgress
				rec.buildFixAttempts = 2
				rec.buildFixGateFail = 1
			},
		},
	}

	for _, c := range cases {
		t.Run(c.scenario, func(t *testing.T) {
			exp := loadOrchestratorFixture(t, c.scenario)
			rec, res := driveOrchestrator(t, c.scenario, exp, c.scoutEnabled, c.seed)
			assertOrchestratorParity(t, c.scenario, exp, rec, res)
		})
	}
}

// errSimulatedBuildFail is a sentinel returned by the recording RunBuildGate
// stub when the test fixture declares a build-fix decision. Drives the
// orchestrator's runBuildGate → BuildFixRun fallback.
var errSimulatedBuildFail = parityBuildErr("simulated build gate failure")

type parityBuildErr string

func (e parityBuildErr) Error() string { return string(e) }
