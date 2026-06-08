package buildfix

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
)

// TestRun_M130MixedUncertainSaveExit pins the M130 amendment C semantic:
// when BUILD_FIX_CLASSIFICATION_REQUIRED=true and the decision is
// mixed_uncertain, attempt 1's failed gate transitions to save_exit
// (Outcome=exhausted, StateExit populated) after exactly one attempt
// instead of running MaxAttempts=3.
func TestRun_M130MixedUncertainSaveExit(t *testing.T) {
	f := &loopFake{
		classifyReturn:    DecisionMixedUncertain,
		gateReturns:       []bool{false},
		runAgentExitCodes: []int{1},
		runAgentTurns:     []int{20},
	}
	cfg := DefaultConfig()
	cfg.ClassificationRequired = true

	result, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "t"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Attempts != 1 {
		t.Fatalf("Attempts = %d, want 1 (M130 save_exit)", result.Attempts)
	}
	if result.Outcome != OutcomeExhausted {
		t.Fatalf("Outcome = %q, want %q", result.Outcome, OutcomeExhausted)
	}
	if result.StateExit == nil || result.StateExit.ExitReason != "build_failure" {
		t.Fatalf("StateExit = %+v, want ExitReason=build_failure", result.StateExit)
	}
	if result.Classification != DecisionMixedUncertain {
		t.Fatalf("Classification = %q, want mixed_uncertain", result.Classification)
	}
}

// TestRun_ProgressStallEarlyBail pins BUILD_FIX_REQUIRE_PROGRESS=true.
// Two failed attempts with identical error counts AND identical tails →
// Outcome=no_progress after exactly 2 attempts, ProgressGateFailures=1.
func TestRun_ProgressStallEarlyBail(t *testing.T) {
	f := &loopFake{
		classifyReturn:    DecisionCodeDominant,
		gateReturns:       []bool{false, false},
		runAgentExitCodes: []int{1, 1},
		runAgentTurns:     []int{20, 25},
		countErrors:       []int{5},
		errorTails:        []string{"same tail text"},
	}
	cfg := DefaultConfig()

	result, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "t"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Attempts != 2 {
		t.Fatalf("Attempts = %d, want 2", result.Attempts)
	}
	if result.Outcome != OutcomeNoProgress {
		t.Fatalf("Outcome = %q, want %q", result.Outcome, OutcomeNoProgress)
	}
	if result.ProgressGateFailures != 1 {
		t.Fatalf("ProgressGateFailures = %d, want 1", result.ProgressGateFailures)
	}
	if result.StateExit == nil || result.StateExit.ExitReason != "build_failure" {
		t.Fatalf("StateExit = %+v, want ExitReason=build_failure", result.StateExit)
	}
}

// TestRun_UnrecognizedTokenWarnsAndProceeds pins the "unrecognized routing
// token" warn line: an unknown decision falls through the switch arm and
// the loop proceeds with the unrecognized decision threaded into the
// report. A real-world example would be a future M127 token added
// upstream that the m39.3 loop has not been updated to recognize.
func TestRun_UnrecognizedTokenWarnsAndProceeds(t *testing.T) {
	const oddToken Decision = "future_token_unknown_to_m39_3"
	var warnLines []string
	f := &loopFake{
		classifyReturn:    oddToken,
		gateReturns:       []bool{true},
		runAgentExitCodes: []int{0},
		runAgentTurns:     []int{10},
	}
	deps := f.deps()
	deps.Warn = func(format string, args ...any) { warnLines = append(warnLines, format) }
	cfg := DefaultConfig()

	result, err := Run(context.Background(), &cfg, deps, &Paths{Task: "t"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	matched := false
	for _, l := range warnLines {
		if strings.Contains(l, "unrecognized routing token") {
			matched = true
			break
		}
	}
	if !matched {
		t.Fatalf("warn lines = %v, want one containing 'unrecognized routing token'", warnLines)
	}
	if result.Outcome != OutcomePassed {
		t.Fatalf("Outcome = %q, want %q", result.Outcome, OutcomePassed)
	}
}

// TestRun_AlwaysExportsStats pins the milestone acceptance criterion: the
// M128 stats are exported via ExportStats on every exit path. We probe
// the four code paths (disabled / noncode / progress-stall / passed) and
// assert each leaves LoopResult.Outcome non-empty.
func TestRun_AlwaysExportsStats(t *testing.T) {
	probe := func(name string, classify Decision, configure func(*Config), agentExit, agentTurns int, gates []bool, counts []int, tails []string) {
		t.Run(name, func(t *testing.T) {
			f := &loopFake{
				classifyReturn:    classify,
				gateReturns:       gates,
				runAgentExitCodes: []int{agentExit},
				runAgentTurns:     []int{agentTurns},
				countErrors:       counts,
				errorTails:        tails,
			}
			cfg := DefaultConfig()
			if configure != nil {
				configure(&cfg)
			}
			result, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "t"})
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if result.Outcome == "" {
				t.Fatalf("Outcome empty — ExportStats not called on %s path", name)
			}
		})
	}
	probe("disabled", DecisionCodeDominant, func(c *Config) { c.Enabled = false }, 0, 0, nil, nil, nil)
	probe("noncode_dominant", DecisionNoncodeDominant, nil, 0, 0, nil, nil, nil)
	probe("passed", DecisionCodeDominant, nil, 0, 10, []bool{true}, nil, nil)
	probe("no_progress",
		DecisionCodeDominant,
		nil,
		1,
		20,
		[]bool{false, false},
		[]int{5},
		[]string{"tail"},
	)
}

// TestRun_ClassifyOnceNotPerAttempt asserts the Watch For invariant: the
// routing decision is fixed at loop entry, NOT re-derived per attempt.
// Even though ReadRawErrors returns different content on subsequent calls,
// classification must remain pinned to the entry value.
func TestRun_ClassifyOnceNotPerAttempt(t *testing.T) {
	f := &loopFake{
		classifyReturn: DecisionCodeDominant,
		rawErrorsByCall: []string{
			"initial error stream",
			"different error stream after attempt 1",
			"different error stream after attempt 2",
		},
		gateReturns:       []bool{false, false, false},
		runAgentExitCodes: []int{1, 1, 1},
		runAgentTurns:     []int{20, 25, 30},
		countErrors:       []int{5, 3, 2},
		errorTails:        []string{"a", "b", "c"},
	}
	cfg := DefaultConfig()

	result, err := Run(context.Background(), &cfg, f.deps(), &Paths{Task: "t"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := atomic.LoadInt32(&f.classifyCalls); got != 1 {
		t.Fatalf("Classify calls = %d, want 1 (fixed at loop entry)", got)
	}
	if result.Classification != DecisionCodeDominant {
		t.Fatalf("Classification = %q, want code_dominant", result.Classification)
	}
	for i, r := range f.appendReports {
		if r.Classification != DecisionCodeDominant {
			t.Fatalf("AppendReport row %d Classification = %q, want code_dominant", i, r.Classification)
		}
	}
}
