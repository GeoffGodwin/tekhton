package claude

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

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
				// (nil, error) contract: pre-first-turn cancellation must return
				// a nil Result so callers never see a partial result alongside an error.
				if got != nil {
					t.Errorf("want nil Result on pre-first-turn cancellation, got %+v", got)
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
