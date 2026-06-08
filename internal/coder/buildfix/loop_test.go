package buildfix

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
)

// TestRun_DisabledFlag pins the cfg.Enabled=false branch: no agent
// invocation, OutcomeNotRun, StateExit.ExitReason=build_failure.
func TestRun_DisabledFlag(t *testing.T) {
	f := &loopFake{classifyReturn: DecisionCodeDominant}
	cfg := DefaultConfig()
	cfg.Enabled = false

	result, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "build feature"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Outcome != OutcomeNotRun {
		t.Fatalf("Outcome = %q, want %q", result.Outcome, OutcomeNotRun)
	}
	if len(f.runAgentLabels) != 0 {
		t.Fatalf("RunAgent was called %d times, want 0", len(f.runAgentLabels))
	}
	if result.StateExit == nil || result.StateExit.ExitReason != "build_failure" {
		t.Fatalf("StateExit = %+v, want ExitReason=build_failure", result.StateExit)
	}
}

// TestRun_NoncodeDominantEnvFailure pins the noncode_dominant short-
// circuit. DriftHumanActionAppend must be called once with source=
// "build_gate" and the description must mention the routing tag. StateExit
// .ExitReason must be env_failure.
func TestRun_NoncodeDominantEnvFailure(t *testing.T) {
	f := &loopFake{classifyReturn: DecisionNoncodeDominant}
	cfg := DefaultConfig()

	result, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "t"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Outcome != OutcomeNotRun {
		t.Fatalf("Outcome = %q, want %q", result.Outcome, OutcomeNotRun)
	}
	if len(f.runAgentLabels) != 0 {
		t.Fatalf("noncode_dominant invoked agent %d times, want 0", len(f.runAgentLabels))
	}
	if len(f.driftAppends) != 1 {
		t.Fatalf("DriftHumanActionAppend called %d times, want 1", len(f.driftAppends))
	}
	if !strings.HasPrefix(f.driftAppends[0], "build_gate|") {
		t.Fatalf("DriftHumanActionAppend source = %q, want build_gate", f.driftAppends[0])
	}
	if !strings.Contains(f.driftAppends[0], "routing=noncode_dominant") {
		t.Fatalf("DriftHumanActionAppend description missing routing tag: %s", f.driftAppends[0])
	}
	if result.StateExit == nil || result.StateExit.ExitReason != "env_failure" {
		t.Fatalf("StateExit = %+v, want ExitReason=env_failure", result.StateExit)
	}
}

// TestRun_MixedUncertainEmitsDiagOnce verifies EmitRoutingDiagnosis is
// called exactly once (at loop entry, not per-attempt). The fake's gate
// returns true on attempt 1 so the loop exits after one invocation.
func TestRun_MixedUncertainEmitsDiagOnce(t *testing.T) {
	f := &loopFake{
		classifyReturn:    DecisionMixedUncertain,
		gateReturns:       []bool{true},
		runAgentExitCodes: []int{0},
		runAgentTurns:     []int{10},
	}
	cfg := DefaultConfig()

	result, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "t"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := atomic.LoadInt32(&f.emitDiagCalls); got != 1 {
		t.Fatalf("EmitRoutingDiagnosis calls = %d, want 1", got)
	}
	if result.Outcome != OutcomePassed {
		t.Fatalf("Outcome = %q, want %q", result.Outcome, OutcomePassed)
	}
}

// TestRun_LabelFormatPreserved pins the agent label format byte-
// identically with the bash version. Operators grep logs for this string
// — drift would silently break observability.
func TestRun_LabelFormatPreserved(t *testing.T) {
	cases := []struct {
		decision Decision
		want     string
	}{
		{DecisionCodeDominant, "Coder (build fix — code_dominant)"},
		{DecisionMixedUncertain, "Coder (build fix — mixed_uncertain)"},
		{DecisionUnknownOnly, "Coder (build fix — unknown_only)"},
	}
	for _, c := range cases {
		t.Run(string(c.decision), func(t *testing.T) {
			f := &loopFake{
				classifyReturn:    c.decision,
				gateReturns:       []bool{true},
				runAgentExitCodes: []int{0},
				runAgentTurns:     []int{10},
			}
			cfg := DefaultConfig()
			if _, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "t"}); err != nil {
				t.Fatalf("Run: %v", err)
			}
			if len(f.runAgentLabels) == 0 {
				t.Fatalf("RunAgent not invoked")
			}
			if f.runAgentLabels[0] != c.want {
				t.Fatalf("RunAgent label = %q, want %q", f.runAgentLabels[0], c.want)
			}
		})
	}
}
