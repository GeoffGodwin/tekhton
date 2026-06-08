package prerun

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Test fakes live in fakes_test.go to keep this file focused on
// assertions. See recordingDeps + recordingDeps.toDeps there.

// TestRun_DisabledSkips verifies that Enabled=false short-circuits to
// StatusSkipped without invoking the agent (a non-nil RunAgent that
// panics would crash the test if Run mistakenly called it).
func TestRun_DisabledSkips(t *testing.T) {
	cfg := &Config{Enabled: false, TestCmd: "go test ./..."}
	deps := &Deps{
		RunAgent: func(context.Context, *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			t.Fatal("RunAgent must not be invoked when Enabled=false")
			return nil, nil
		},
	}

	res, err := Run(context.Background(), cfg, deps)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Status != StatusSkipped {
		t.Fatalf("status = %q, want %q", res.Status, StatusSkipped)
	}
	if res.Attempts != 0 {
		t.Fatalf("attempts = %d, want 0", res.Attempts)
	}
}

// TestRun_EmptyTestCmdSkips covers TestCmd == "" and TestCmd == "true".
func TestRun_EmptyTestCmdSkips(t *testing.T) {
	rows := []struct {
		name    string
		testCmd string
	}{
		{"empty", ""},
		{"literal-true", "true"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			cfg := &Config{Enabled: true, TestCmd: row.testCmd}
			deps := &Deps{
				RunAgent: func(context.Context, *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
					t.Fatal("RunAgent must not be invoked when TestCmd is no-op")
					return nil, nil
				},
			}
			res, err := Run(context.Background(), cfg, deps)
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if res.Status != StatusSkipped {
				t.Fatalf("status = %q, want %q", res.Status, StatusSkipped)
			}
		})
	}
}

// TestRun_DedupShortCircuits verifies that when TestDedupCanSkip returns
// true the orchestrator skips TEST_CMD AND the agent.
func TestRun_DedupShortCircuits(t *testing.T) {
	rec := &recordingDeps{dedupCanSkip: true, testCmdExit: 1}
	deps := rec.toDeps()
	// Replace RunAgent with a fail-fast; the dedup path must not invoke it.
	deps.RunAgent = func(context.Context, *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		t.Fatal("RunAgent must not be invoked when dedup short-circuits")
		return nil, nil
	}
	deps.RunTestCmd = func(context.Context, string) (string, int, error) {
		t.Fatal("RunTestCmd must not be invoked when dedup short-circuits")
		return "", 0, nil
	}

	res, err := Run(context.Background(), &Config{Enabled: true, TestCmd: "go test"}, deps)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Status != StatusClean {
		t.Fatalf("status = %q, want %q", res.Status, StatusClean)
	}
	if got := strings.Join(rec.emitted, ","); !strings.Contains(got, "test_dedup_skip|prerun_check") {
		t.Fatalf("expected test_dedup_skip emit, got %q", got)
	}
}

// TestRun_CleanPassRecordsDedup verifies that when TEST_CMD passes
// pre-coder the orchestrator records the dedup fingerprint AND returns
// StatusClean.
func TestRun_CleanPassRecordsDedup(t *testing.T) {
	rec := &recordingDeps{testCmdExit: 0, testCmdOutput: "ok"}
	res, err := Run(context.Background(),
		&Config{Enabled: true, TestCmd: "go test"}, rec.toDeps())
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Status != StatusClean {
		t.Fatalf("status = %q, want %q", res.Status, StatusClean)
	}
	if rec.dedupRecord != 1 {
		t.Fatalf("dedup record calls = %d, want 1", rec.dedupRecord)
	}
	if rec.agentCalls != 0 {
		t.Fatalf("agent calls = %d, want 0", rec.agentCalls)
	}
}

// TestRun_FixSucceedsRecapturesBaseline verifies the load-bearing
// delete-before-capture ordering on the StatusFixed path.
func TestRun_FixSucceedsRecapturesBaseline(t *testing.T) {
	rec := &recordingDeps{
		testCmdOutput: "FAIL TestFoo\nFAIL TestBar",
		testCmdExit:   1,
		// Verify call #1 (after the fix agent) passes.
		verifyExits:   []int{0},
		verifyOutputs: []string{"PASS"},
	}
	cfg := &Config{Enabled: true, TestCmd: "go test", Milestone: "m39.1"}
	res, err := Run(context.Background(), cfg, rec.toDeps())
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Status != StatusFixed {
		t.Fatalf("status = %q, want %q", res.Status, StatusFixed)
	}
	if res.Attempts != 1 {
		t.Fatalf("attempts = %d, want 1", res.Attempts)
	}
	if !res.BaselineReCaptured {
		t.Fatalf("BaselineReCaptured = false, want true")
	}
	if rec.captureMilestone != "m39.1" {
		t.Fatalf("capture milestone = %q, want m39.1", rec.captureMilestone)
	}
	if len(rec.callOrder) < 2 || rec.callOrder[0] != "delete" || rec.callOrder[1] != "capture" {
		t.Fatalf("call order = %v, want [delete, capture, ...]", rec.callOrder)
	}
}

// TestRun_FixExhausts verifies that the default MaxAttempts=1 means a
// failing verify after the first attempt routes to StatusFixFailed.
func TestRun_FixExhausts(t *testing.T) {
	rec := &recordingDeps{
		testCmdOutput: "FAIL TestFoo",
		testCmdExit:   1,
		verifyExits:   []int{1}, // still failing after the attempt
		verifyOutputs: []string{"FAIL TestFoo"},
	}
	// Config{} → defaults apply.
	cfg := &Config{Enabled: true, TestCmd: "go test"}
	res, err := Run(context.Background(), cfg, rec.toDeps())
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Status != StatusFixFailed {
		t.Fatalf("status = %q, want %q", res.Status, StatusFixFailed)
	}
	if res.Attempts != 1 {
		t.Fatalf("attempts = %d, want 1 (default MaxAttempts)", res.Attempts)
	}
	if res.BaselineReCaptured {
		t.Fatalf("BaselineReCaptured = true, want false on fix_failed")
	}
	if rec.captureCalls != 0 {
		t.Fatalf("capture should not run when fix exhausts; got %d", rec.captureCalls)
	}
}

// TestRun_ConfigDefaultsApplied verifies the milestone-acceptance criteria:
// Config{} produces MaxAttempts=1 and MaxTurns=20 inside the orchestrator.
func TestRun_ConfigDefaultsApplied(t *testing.T) {
	var seenMaxTurns int
	rec := &recordingDeps{
		testCmdOutput: "FAIL",
		testCmdExit:   1,
		verifyExits:   []int{1},
	}
	deps := rec.toDeps()
	// Wrap RunAgent to capture the MaxTurns the orchestrator forwarded.
	deps.RunAgent = func(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		seenMaxTurns = req.MaxTurns
		return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}, nil
	}

	cfg := &Config{Enabled: true, TestCmd: "go test"} // Config{} except Enabled+TestCmd
	res, _ := Run(context.Background(), cfg, deps)

	// MaxAttempts=1 default → exactly one attempt.
	if res.Attempts != 1 {
		t.Fatalf("attempts = %d, want 1 (default MaxAttempts)", res.Attempts)
	}
	// MaxTurns=20 default → forwarded into the AgentRequestV1.
	if seenMaxTurns != 20 {
		t.Fatalf("agent MaxTurns = %d, want 20 (default MaxTurns)", seenMaxTurns)
	}
}

// TestRun_FixFailedEmitsExhaustedEvent verifies the milestone acceptance
// criterion that prerun_fix_end emit on the exhausted path contains
// "exhausted".
func TestRun_FixFailedEmitsExhaustedEvent(t *testing.T) {
	rec := &recordingDeps{
		testCmdOutput: "FAIL",
		testCmdExit:   1,
		verifyExits:   []int{1},
	}
	_, _ = Run(context.Background(),
		&Config{Enabled: true, TestCmd: "go test"}, rec.toDeps())

	found := false
	for _, e := range rec.emitted {
		if strings.HasPrefix(e, "prerun_fix_end|") && strings.Contains(e, "exhausted") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected prerun_fix_end with 'exhausted', got %v", rec.emitted)
	}
}

// TestRun_AgentInvocationErrorIsNonFatal verifies the bash version's
// degrade-and-continue behavior on agent runner errors: the loop still
// runs verify-after-attempt and routes through the normal path.
func TestRun_AgentInvocationErrorIsNonFatal(t *testing.T) {
	rec := &recordingDeps{
		testCmdOutput: "FAIL TestFoo",
		testCmdExit:   1,
		verifyExits:   []int{0}, // verify passes even though agent errored
		verifyOutputs: []string{"PASS"},
		agentErr:      errors.New("network blip"),
	}
	res, err := Run(context.Background(),
		&Config{Enabled: true, TestCmd: "go test"}, rec.toDeps())
	if err != nil {
		t.Fatalf("Run should never return non-nil err: %v", err)
	}
	if res.Status != StatusFixed {
		t.Fatalf("status = %q, want %q (verify passes after attempt)", res.Status, StatusFixed)
	}
}

// TestRun_BaselineDepsOptional verifies that omitting CaptureTestBaseline
// degrades gracefully on the fixed path — no panic, BaselineReCaptured
// stays false.
func TestRun_BaselineDepsOptional(t *testing.T) {
	rec := &recordingDeps{
		testCmdOutput: "FAIL",
		testCmdExit:   1,
		verifyExits:   []int{0},
		verifyOutputs: []string{"PASS"},
	}
	deps := rec.toDeps()
	deps.CaptureTestBaseline = nil // unset

	res, err := Run(context.Background(),
		&Config{Enabled: true, TestCmd: "go test"}, deps)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if res.Status != StatusFixed {
		t.Fatalf("status = %q, want fixed", res.Status)
	}
	if res.BaselineReCaptured {
		t.Fatalf("BaselineReCaptured = true, want false (capture dep unset)")
	}
}
