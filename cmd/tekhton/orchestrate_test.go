package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// runRoot drives the Cobra root with the given argv and returns
// (stdout, stderr, err). Mirrors the pattern in supervise_test.go.
func runRoot(t *testing.T, stdin string, args ...string) (string, string, error) {
	t.Helper()
	cmd := newRootCmd()
	cmd.SetArgs(args)
	cmd.SetIn(strings.NewReader(stdin))
	var out, errOut bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&errOut)
	err := cmd.Execute()
	return out.String(), errOut.String(), err
}

func TestOrchestrateClassifyCodeDominantBuild(t *testing.T) {
	in := `{"build_errors_present": true, "build_classification": "code_dominant"}`
	out, _, err := runRoot(t, in, "orchestrate", "classify")
	if err != nil {
		t.Fatalf("classify: %v", err)
	}
	if got := strings.TrimSpace(out); got != proto.RecoveryRetryCoderBuild {
		t.Fatalf("classify output = %q; want %q", got, proto.RecoveryRetryCoderBuild)
	}
}

func TestOrchestrateClassifyMixedBuildSecondAttempt(t *testing.T) {
	// First attempt: mixed_uncertain → retry. Second attempt (guard set) →
	// save_exit. Verify the --mixed-build-retried flag drives the second-attempt
	// branch.
	in := `{"build_errors_present": true, "build_classification": "mixed_uncertain"}`
	out, _, err := runRoot(t, in, "orchestrate", "classify", "--mixed-build-retried")
	if err != nil {
		t.Fatalf("classify: %v", err)
	}
	if got := strings.TrimSpace(out); got != proto.RecoverySaveExit {
		t.Fatalf("classify output = %q; want %q", got, proto.RecoverySaveExit)
	}
}

func TestOrchestrateClassifyEnvGateRetriedFlag(t *testing.T) {
	// env/test_infra primary cause normally returns retry_ui_gate_env, but
	// not when the guard is already set.
	in := `{"primary_cat": "ENVIRONMENT", "primary_sub": "test_infra", "error_category": "ENVIRONMENT"}`
	out, _, err := runRoot(t, in, "orchestrate", "classify", "--env-gate-retried")
	if err != nil {
		t.Fatalf("classify: %v", err)
	}
	if got := strings.TrimSpace(out); got != proto.RecoverySaveExit {
		t.Fatalf("classify output = %q; want save_exit (env-gate guard set)", got)
	}
}

func TestOrchestrateClassifyEmptyOutcomeRejected(t *testing.T) {
	_, _, err := runRoot(t, "", "orchestrate", "classify")
	if err == nil {
		t.Fatalf("classify with empty stdin: expected error")
	}
}

func TestOrchestrateClassifyMalformedJSON(t *testing.T) {
	_, _, err := runRoot(t, "{not json", "orchestrate", "classify")
	if err == nil {
		t.Fatalf("classify with bad JSON: expected error")
	}
}

func TestOrchestrateRunAttemptNoStagesSuccess(t *testing.T) {
	req := proto.AttemptRequestV1{
		Proto:      proto.AttemptRequestProtoV1,
		Task:       "Implement Milestone 12",
		ProjectDir: "/tmp/fake-project",
	}
	body, _ := json.Marshal(req)
	out, _, err := runRoot(t, string(body), "orchestrate", "run-attempt", "--no-stages")
	if err != nil {
		t.Fatalf("run-attempt --no-stages: %v", err)
	}
	var res proto.AttemptResultV1
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if res.Outcome != proto.AttemptOutcomeSuccess {
		t.Fatalf("Outcome = %q; want success", res.Outcome)
	}
	if res.Proto != proto.AttemptResultProtoV1 {
		t.Fatalf("Proto = %q; want %q", res.Proto, proto.AttemptResultProtoV1)
	}
}

func TestOrchestrateRunAttemptInvalidEnvelope(t *testing.T) {
	// Missing project_dir.
	body := `{"proto": "tekhton.attempt.request.v1", "task": "x"}`
	_, _, err := runRoot(t, body, "orchestrate", "run-attempt", "--no-stages")
	if err == nil {
		t.Fatalf("run-attempt: expected validation error")
	}
}

func TestOrchestrateRunAttemptStubRunnerSavesExit(t *testing.T) {
	// Without --no-stages, the default stub runner returns a PIPELINE error
	// flagging that stage execution is not yet wired in m12. The loop should
	// classify that as save_exit and exit 1.
	req := proto.AttemptRequestV1{
		Proto:      proto.AttemptRequestProtoV1,
		Task:       "test",
		ProjectDir: "/tmp/fake-project",
	}
	body, _ := json.Marshal(req)
	out, _, err := runRoot(t, string(body), "orchestrate", "run-attempt")
	if err == nil {
		t.Fatalf("expected exit error for stub runner")
	}
	var res proto.AttemptResultV1
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if res.Recovery != proto.RecoverySaveExit {
		t.Fatalf("Recovery = %q; want save_exit", res.Recovery)
	}
}
