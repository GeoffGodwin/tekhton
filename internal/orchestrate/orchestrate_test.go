package orchestrate

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeRunner drives RunAttempt with a scripted sequence of StageOutcomes.
// Each call pops the next outcome; if outcomes is empty, it returns the last
// one. Useful for exercising the loop's iteration / safety-bound behavior.
type fakeRunner struct {
	outcomes []StageOutcome
	err      error
	calls    int
}

func (f *fakeRunner) RunStages(ctx context.Context, req *proto.AttemptRequestV1, attempt int) (StageOutcome, error) {
	f.calls++
	if f.err != nil {
		return StageOutcome{}, f.err
	}
	if len(f.outcomes) == 0 {
		return StageOutcome{Success: true, AgentCalls: 1}, nil
	}
	o := f.outcomes[0]
	if len(f.outcomes) > 1 {
		f.outcomes = f.outcomes[1:]
	}
	return o, nil
}

func validRequest() *proto.AttemptRequestV1 {
	return &proto.AttemptRequestV1{
		Proto:                   proto.AttemptRequestProtoV1,
		Task:                    "Implement Milestone 12",
		ProjectDir:              "/tmp/fake-project",
		MaxPipelineAttempts:     5,
		AutonomousTimeoutSecs:   7200,
		MaxAutonomousAgentCalls: 200,
	}
}

func TestRunAttemptSuccessFirstTry(t *testing.T) {
	runner := &fakeRunner{
		outcomes: []StageOutcome{{Success: true, AgentCalls: 3, TurnsUsed: 42}},
	}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSuccess {
		t.Fatalf("Outcome = %q; want success", res.Outcome)
	}
	if res.Recovery != "" {
		t.Fatalf("Recovery = %q; want empty on success", res.Recovery)
	}
	if res.Attempts != 1 {
		t.Fatalf("Attempts = %d; want 1", res.Attempts)
	}
	if res.AgentCalls != 3 {
		t.Fatalf("AgentCalls = %d; want 3", res.AgentCalls)
	}
	if res.TotalTurns != 42 {
		t.Fatalf("TotalTurns = %d; want 42", res.TotalTurns)
	}
}

func TestRunAttemptIteratesOnRecoverable(t *testing.T) {
	// First two attempts fail with build errors that should retry; third succeeds.
	runner := &fakeRunner{
		outcomes: []StageOutcome{
			{BuildErrorsPresent: true, BuildClassification: "code_dominant", AgentCalls: 2, TurnsUsed: 10},
			{BuildErrorsPresent: true, BuildClassification: "code_dominant", AgentCalls: 2, TurnsUsed: 12},
			{Success: true, AgentCalls: 1, TurnsUsed: 5},
		},
	}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSuccess {
		t.Fatalf("Outcome = %q; want success", res.Outcome)
	}
	if res.Attempts != 3 {
		t.Fatalf("Attempts = %d; want 3", res.Attempts)
	}
	if res.AgentCalls != 5 {
		t.Fatalf("AgentCalls = %d; want 5", res.AgentCalls)
	}
	if res.TotalTurns != 27 {
		t.Fatalf("TotalTurns = %d; want 27", res.TotalTurns)
	}
}

func TestRunAttemptStopsOnSaveExit(t *testing.T) {
	runner := &fakeRunner{
		outcomes: []StageOutcome{{
			ErrorCategory:    "PIPELINE",
			ErrorSubcategory: "internal",
			ErrorMessage:     "internal bug",
			AgentCalls:       1,
		}},
	}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeFailureSaveExit {
		t.Fatalf("Outcome = %q; want failure_save_exit", res.Outcome)
	}
	if res.Recovery != proto.RecoverySaveExit {
		t.Fatalf("Recovery = %q; want save_exit", res.Recovery)
	}
	if res.ErrorCategory != "PIPELINE" {
		t.Fatalf("ErrorCategory = %q; want PIPELINE", res.ErrorCategory)
	}
	if runner.calls != 1 {
		t.Fatalf("runner.calls = %d; want 1 (no retries on save_exit)", runner.calls)
	}
}

func TestRunAttemptRespectsMaxAttempts(t *testing.T) {
	// Always return a recoverable failure so the loop iterates until the
	// attempt cap trips.
	runner := &fakeRunner{
		outcomes: []StageOutcome{{
			BuildErrorsPresent:  true,
			BuildClassification: "code_dominant",
			AgentCalls:          1,
		}},
	}
	cfg := DefaultConfig()
	cfg.MaxPipelineAttempts = 3
	l := New(runner, cfg)
	req := validRequest()
	req.MaxPipelineAttempts = 0 // let cfg win
	res, err := l.RunAttempt(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSafetyBound {
		t.Fatalf("Outcome = %q; want safety_bound", res.Outcome)
	}
	if res.Attempts != 3 {
		t.Fatalf("Attempts = %d; want 3 (capped)", res.Attempts)
	}
}

func TestRunAttemptRespectsAgentCallCap(t *testing.T) {
	runner := &fakeRunner{
		outcomes: []StageOutcome{{
			BuildErrorsPresent:  true,
			BuildClassification: "code_dominant",
			AgentCalls:          50,
		}},
	}
	cfg := DefaultConfig()
	cfg.MaxAutonomousAgentCalls = 100
	l := New(runner, cfg)
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSafetyBound {
		t.Fatalf("Outcome = %q; want safety_bound", res.Outcome)
	}
	if res.AgentCalls < 100 {
		t.Fatalf("AgentCalls = %d; want >= cap", res.AgentCalls)
	}
}

func TestRunAttemptRespectsWallClockTimeout(t *testing.T) {
	now := time.Unix(0, 0)
	cfg := DefaultConfig()
	cfg.AutonomousTimeoutSecs = 100

	runner := &fakeRunner{
		outcomes: []StageOutcome{{Success: false, BuildErrorsPresent: true, BuildClassification: "code_dominant", AgentCalls: 1}},
	}
	l := New(runner, cfg)
	// Advance time by more than the timeout on each call so the second
	// safety-bound check (top of loop, attempt 2) trips.
	step := 0
	l.now = func() time.Time {
		t := now.Add(time.Duration(step) * 200 * time.Second)
		step++
		return t
	}

	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSafetyBound {
		t.Fatalf("Outcome = %q; want safety_bound", res.Outcome)
	}
}

func TestRunAttemptCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	runner := &fakeRunner{
		outcomes: []StageOutcome{{Success: true}},
	}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(ctx, validRequest())
	if !errors.Is(err, ErrAttemptCanceled) {
		t.Fatalf("err = %v; want ErrAttemptCanceled", err)
	}
	if res.Recovery != proto.RecoverySaveExit {
		t.Fatalf("Recovery = %q; want save_exit", res.Recovery)
	}
}

func TestRunAttemptStageRunnerError(t *testing.T) {
	runner := &fakeRunner{err: errors.New("stage runner crashed")}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err == nil {
		t.Fatalf("expected error from stage runner")
	}
	if res.Outcome != proto.AttemptOutcomeFailureSaveExit {
		t.Fatalf("Outcome = %q; want failure_save_exit", res.Outcome)
	}
}

func TestRunAttemptInvalidRequest(t *testing.T) {
	cases := []struct {
		name string
		req  *proto.AttemptRequestV1
	}{
		{"nil", nil},
		{"missing proto", &proto.AttemptRequestV1{Task: "x", ProjectDir: "/tmp"}},
		{"missing task", &proto.AttemptRequestV1{Proto: proto.AttemptRequestProtoV1, ProjectDir: "/tmp"}},
		{"missing project_dir", &proto.AttemptRequestV1{Proto: proto.AttemptRequestProtoV1, Task: "x"}},
	}
	l := New(&fakeRunner{}, DefaultConfig())
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := l.RunAttempt(context.Background(), tc.req)
			if err == nil {
				t.Fatalf("expected validation error for %s", tc.name)
			}
		})
	}
}

func TestSplitClassReturnsSaveExitWithSplitRecovery(t *testing.T) {
	// Split is currently driven by bash (m11/m14 territory). The Go loop
	// returns failure_save_exit with Recovery=split so the bash front-end
	// can run the split and resume.
	runner := &fakeRunner{
		outcomes: []StageOutcome{{
			ErrorCategory:    "AGENT_SCOPE",
			ErrorSubcategory: "max_turns",
			AgentCalls:       1,
		}},
	}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Recovery != proto.RecoverySplit {
		t.Fatalf("Recovery = %q; want split", res.Recovery)
	}
	if res.Outcome != proto.AttemptOutcomeFailureSaveExit {
		t.Fatalf("Outcome = %q; want failure_save_exit", res.Outcome)
	}
}

func TestRequestOverridesApply(t *testing.T) {
	// The bash front-end can override per-pipeline-conf bounds via the
	// request envelope. Verify the override path.
	runner := &fakeRunner{
		outcomes: []StageOutcome{{
			BuildErrorsPresent:  true,
			BuildClassification: "code_dominant",
			AgentCalls:          1,
		}},
	}
	cfg := DefaultConfig()
	cfg.MaxPipelineAttempts = 100 // loop default
	l := New(runner, cfg)

	req := validRequest()
	req.MaxPipelineAttempts = 2 // request override

	res, err := l.RunAttempt(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSafetyBound {
		t.Fatalf("Outcome = %q; want safety_bound (request override should cap at 2)", res.Outcome)
	}
}

func TestEnvGateRetryGuardSticks(t *testing.T) {
	// First iter: env/test_infra primary should produce retry_ui_gate_env.
	// Second iter: same primary cause should NOT retry again — the persistent
	// guard mirrors _ORCH_ENV_GATE_RETRIED in the bash recovery dispatch.
	runner := &fakeRunner{
		outcomes: []StageOutcome{
			{
				ErrorCategory: "ENVIRONMENT",
				PrimaryCat:    "ENVIRONMENT",
				PrimarySub:    "test_infra",
				AgentCalls:    1,
			},
			{
				ErrorCategory: "ENVIRONMENT",
				PrimaryCat:    "ENVIRONMENT",
				PrimarySub:    "test_infra",
				AgentCalls:    1,
			},
		},
	}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Second attempt's classifier should have fallen through to save_exit.
	if res.Outcome != proto.AttemptOutcomeFailureSaveExit {
		t.Fatalf("Outcome = %q; want failure_save_exit on second iter", res.Outcome)
	}
	if res.Attempts != 2 {
		t.Fatalf("Attempts = %d; want 2", res.Attempts)
	}
}

func TestSetGuardSetters(t *testing.T) {
	// SetEnvGateRetried / SetMixedBuildRetried are CLI-flag driven; assert
	// they prime the guards visibly via classification.
	l := New(nil, DefaultConfig())

	l.SetEnvGateRetried(true)
	out := l.Classify(StageOutcome{
		PrimaryCat: "ENVIRONMENT",
		PrimarySub: "test_infra",
	}, DefaultConfig())
	if out == proto.RecoveryRetryUIGateEnv {
		t.Fatalf("env gate retried guard not honored: got %q", out)
	}

	l = New(nil, DefaultConfig())
	l.SetMixedBuildRetried(true)
	out = l.Classify(StageOutcome{
		BuildErrorsPresent:  true,
		BuildClassification: "mixed_uncertain",
	}, DefaultConfig())
	if out != proto.RecoverySaveExit {
		t.Fatalf("mixed build retried guard not honored: got %q", out)
	}
}

func TestProtoEnvelopeStamped(t *testing.T) {
	runner := &fakeRunner{outcomes: []StageOutcome{{Success: true, AgentCalls: 1}}}
	l := New(runner, DefaultConfig())
	res, err := l.RunAttempt(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Proto != proto.AttemptResultProtoV1 {
		t.Fatalf("Proto = %q; want %q", res.Proto, proto.AttemptResultProtoV1)
	}
}
