package buildfix

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// fixtureExpected captures the JSON shape under
// internal/coder/testdata/buildfix/<scenario>/expected.json. Only the
// fields the parity tests assert against are decoded — the comment field
// is documentation for fixture maintainers.
type fixtureExpected struct {
	Comment                      string `json:"comment"`
	Decision                     string `json:"decision"`
	Outcome                      string `json:"outcome"`
	Attempts                     int    `json:"attempts"`
	ClassificationRequired       bool   `json:"classification_required"`
	ExpectedStateExitReason      string `json:"expected_state_exit_reason"`
	ExpectedLabel                string `json:"expected_label"`
	ExpectedProgressGateFailures int    `json:"expected_progress_gate_failures"`
}

func loadFixture(t *testing.T, scenario string) (rawErrors string, exp fixtureExpected) {
	t.Helper()
	base := filepath.Join("..", "testdata", "buildfix", scenario)
	rawBytes, err := os.ReadFile(filepath.Join(base, "raw_errors.txt"))
	if err != nil {
		t.Fatalf("fixture %s: read raw_errors.txt: %v", scenario, err)
	}
	expBytes, err := os.ReadFile(filepath.Join(base, "expected.json"))
	if err != nil {
		t.Fatalf("fixture %s: read expected.json: %v", scenario, err)
	}
	if err := json.Unmarshal(expBytes, &exp); err != nil {
		t.Fatalf("fixture %s: decode expected.json: %v", scenario, err)
	}
	return string(rawBytes), exp
}

// TestParity_CodeDominantPasses drives the code-dominant-passes fixture
// through the live loop: the agent's first attempt fixes the build, the
// gate passes, Outcome=passed.
func TestParity_CodeDominantPasses(t *testing.T) {
	rawErrors, exp := loadFixture(t, "code-dominant-passes")

	f := &loopFake{
		rawErrorsByCall:   []string{rawErrors},
		gateReturns:       []bool{true},
		runAgentExitCodes: []int{0},
		runAgentTurns:     []int{15},
	}
	// Drive the actual Classify path so the fixture's raw stream
	// classifies live (not via the loopFake's classifyReturn).
	deps := f.deps()
	deps.Classify = Classify

	cfg := DefaultConfig()
	result, err := Run(context.Background(), &cfg, deps, &Paths{Task: "code-dominant"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	assertOutcome(t, exp, result)
	assertLabel(t, exp, f.runAgentLabels)
	assertClassification(t, exp, result)
}

// TestParity_MixedUncertainRetry drives the mixed-uncertain-retry
// fixture. Raw errors = 5 code + 5 noncode → Classify returns
// mixed_uncertain. cfg.ClassificationRequired=true → save_exit after one
// failed attempt.
func TestParity_MixedUncertainRetry(t *testing.T) {
	rawErrors, exp := loadFixture(t, "mixed-uncertain-retry")

	f := &loopFake{
		rawErrorsByCall:   []string{rawErrors},
		gateReturns:       []bool{false},
		runAgentExitCodes: []int{1},
		runAgentTurns:     []int{20},
	}
	deps := f.deps()
	deps.Classify = Classify

	cfg := DefaultConfig()
	cfg.ClassificationRequired = exp.ClassificationRequired
	result, err := Run(context.Background(), &cfg, deps, &Paths{Task: "mixed"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	assertOutcome(t, exp, result)
	assertLabel(t, exp, f.runAgentLabels)
	assertClassification(t, exp, result)
	assertStateExit(t, exp, result)
}

// TestParity_ProgressStalls drives the progress-stalls fixture. The
// raw errors stay constant across attempts → ProgressSignal=unchanged
// at attempt 2 → no_progress bail with ProgressGateFailures=1.
func TestParity_ProgressStalls(t *testing.T) {
	rawErrors, exp := loadFixture(t, "progress-stalls")

	f := &loopFake{
		rawErrorsByCall:   []string{rawErrors, rawErrors, rawErrors},
		gateReturns:       []bool{false, false},
		runAgentExitCodes: []int{1, 1},
		runAgentTurns:     []int{20, 25},
		countErrors:       []int{5},
		errorTails:        []string{"same tail"},
	}
	deps := f.deps()
	deps.Classify = Classify

	cfg := DefaultConfig()
	result, err := Run(context.Background(), &cfg, deps, &Paths{Task: "stalls"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	assertOutcome(t, exp, result)
	assertClassification(t, exp, result)
	if result.ProgressGateFailures != exp.ExpectedProgressGateFailures {
		t.Fatalf("ProgressGateFailures = %d, want %d", result.ProgressGateFailures, exp.ExpectedProgressGateFailures)
	}
	assertStateExit(t, exp, result)
}

func assertOutcome(t *testing.T, exp fixtureExpected, result *LoopResult) {
	t.Helper()
	if string(result.Outcome) != exp.Outcome {
		t.Fatalf("Outcome = %q, want %q", result.Outcome, exp.Outcome)
	}
	if result.Attempts != exp.Attempts {
		t.Fatalf("Attempts = %d, want %d", result.Attempts, exp.Attempts)
	}
}

func assertLabel(t *testing.T, exp fixtureExpected, labels []string) {
	t.Helper()
	if exp.ExpectedLabel == "" {
		return
	}
	if len(labels) == 0 {
		t.Fatalf("no agent invocation — wanted label %q", exp.ExpectedLabel)
	}
	if labels[0] != exp.ExpectedLabel {
		t.Fatalf("agent label = %q, want %q", labels[0], exp.ExpectedLabel)
	}
}

func assertClassification(t *testing.T, exp fixtureExpected, result *LoopResult) {
	t.Helper()
	if exp.Decision == "" {
		return
	}
	if string(result.Classification) != exp.Decision {
		t.Fatalf("Classification = %q, want %q", result.Classification, exp.Decision)
	}
}

func assertStateExit(t *testing.T, exp fixtureExpected, result *LoopResult) {
	t.Helper()
	if exp.ExpectedStateExitReason == "" {
		return
	}
	if result.StateExit == nil {
		t.Fatalf("StateExit = nil, want ExitReason=%q", exp.ExpectedStateExitReason)
	}
	if result.StateExit.ExitReason != exp.ExpectedStateExitReason {
		t.Fatalf("StateExit.ExitReason = %q, want %q", result.StateExit.ExitReason, exp.ExpectedStateExitReason)
	}
}
