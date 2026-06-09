package claude

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// TestClaudeProvider_ContextCancelledWithPartialResult pins the
// (non-nil result, context.Canceled) path — supervisor completes a run AND
// returns context.Canceled (e.g. cancellation delivered just after the run
// finishes). The reviewer noted this specific error type was not pinned in
// cycle 1; callers must be able to use errors.Is(err, context.Canceled)
// rather than branching on result.Outcome for this case.
// See docs/v5-provider-seam.md § Outcome Mapping Table.
func TestClaudeProvider_ContextCancelledWithPartialResult(t *testing.T) {
	partialResult := loadFixture(t, "trivial_success")

	stub := &stubSup{result: partialResult, err: context.Canceled}
	cp := &Provider{Supervisor: stub}

	got, err := cp.RunAgent(context.Background(), &provider.Request{
		Prompt:   "context cancelled with partial result",
		MaxTurns: 10,
		Model:    "claude-3-5-sonnet-20241022",
		Label:    "context_cancelled_partial",
	})

	if err == nil {
		t.Fatal("want error, got nil")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("want errors.Is(err, context.Canceled) true, err = %v", err)
	}
	if got == nil {
		t.Fatal("want non-nil Result alongside context.Canceled, got nil — " +
			"partial result must be returned so callers can inspect TurnsUsed etc.")
	}
	if got.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want OutcomeSuccess (translated from trivial_success fixture), got %v", got.Outcome)
	}
}

// loadFixture reads a testdata/<name>.json file and unmarshals it as
// AgentResultV1. The test is skipped if the file does not exist.
func loadFixture(t *testing.T, name string) *proto.AgentResultV1 {
	t.Helper()
	path := filepath.Join("testdata", name+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("loadFixture %s: %v", name, err)
	}
	var v1 proto.AgentResultV1
	if err := json.Unmarshal(data, &v1); err != nil {
		t.Fatalf("loadFixture %s: unmarshal: %v", name, err)
	}
	return &v1
}

// TestClaudeProvider_ParityWithDirectSupervisor drives each outcome scenario
// through the Claude provider and verifies the translated Result matches the
// expected provider.Outcome and NullRun flag.
//
// The supervisor is stubbed so the test exercises the translation layer in
// isolation — the supervisor's own tests prove it talks to Claude correctly.
// Six fixtures cover every Outcome category.
func TestClaudeProvider_ParityWithDirectSupervisor(t *testing.T) {
	tests := []struct {
		name        string
		supErr      error
		wantOutcome provider.Outcome
		wantNullRun bool
		wantErr     bool
	}{
		{name: "trivial_success", wantOutcome: provider.OutcomeSuccess},
		{name: "multi_turn_with_tools", wantOutcome: provider.OutcomeSuccess},
		{name: "upstream_error", wantOutcome: provider.OutcomeUpstreamError},
		{name: "null_run", wantOutcome: provider.OutcomeNullRun, wantNullRun: true},
		{name: "max_turns_exhausted", wantOutcome: provider.OutcomeMaxTurns},
		{name: "context_cancelled", supErr: context.Canceled, wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var supResult *proto.AgentResultV1
			if tc.supErr == nil {
				supResult = loadFixture(t, tc.name)
			}

			stub := &stubSup{result: supResult, err: tc.supErr}
			cp := &Provider{Supervisor: stub}

			req := &provider.Request{
				Prompt:   "parity test prompt",
				MaxTurns: 10,
				Model:    "claude-3-5-sonnet-20241022",
				Label:    tc.name,
			}

			got, err := cp.RunAgent(context.Background(), req)

			if tc.wantErr {
				if err == nil {
					t.Error("want error, got nil")
				}
				// (nil, error) contract: when the supervisor returns context.Canceled,
				// RunAgent must return (nil, error) — callers must never receive a
				// partial Result alongside an error from a supervisor-level failure.
				if got != nil {
					t.Errorf("want nil Result when supervisor returns context.Canceled, got %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Outcome != tc.wantOutcome {
				t.Errorf("Outcome: want %d, got %d", tc.wantOutcome, got.Outcome)
			}
			if got.NullRun != tc.wantNullRun {
				t.Errorf("NullRun: want %v, got %v", tc.wantNullRun, got.NullRun)
			}
			if len(got.RawProviderData) == 0 {
				t.Error("RawProviderData: want non-empty JSON capture, got empty")
			}
		})
	}
}

// TestClaudeProvider_PartialCompletionErrorPath exercises the branch where
// the supervisor returns BOTH a non-nil AgentResultV1 AND a non-nil error.
// This is the only place in the provider where (non-nil Result, non-nil error)
// can legitimately arise — e.g. a partial run that completed some turns but
// then encountered a network interruption.
//
// The contract: RunAgent must propagate both the partial result AND the error
// to the caller. Callers that need to distinguish partial completion from a
// clean run must inspect err alongside Result.
func TestClaudeProvider_PartialCompletionErrorPath(t *testing.T) {
	partialResult := loadFixture(t, "trivial_success")
	partialErr := errors.New("partial: network interrupted after completion")

	stub := &stubSup{result: partialResult, err: partialErr}
	cp := &Provider{Supervisor: stub}

	got, err := cp.RunAgent(context.Background(), &provider.Request{
		Prompt:   "partial completion test",
		MaxTurns: 10,
		Model:    "claude-3-5-sonnet-20241022",
		Label:    "partial_completion",
	})

	if err == nil {
		t.Fatal("partial_completion: want error from supervisor, got nil")
	}
	if got == nil {
		t.Fatal("partial_completion: want non-nil Result alongside error, got nil — " +
			"the partial result must be returned so the caller can inspect turn count etc.")
	}
	if got.Outcome != provider.OutcomeSuccess {
		t.Errorf("partial_completion: Outcome: want OutcomeSuccess (translated from partial result), got %d", got.Outcome)
	}
	if len(got.RawProviderData) == 0 {
		t.Error("partial_completion: RawProviderData: must be populated even for partial results")
	}
}
