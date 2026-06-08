package coder

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// TestRunContinuation_Default3Attempts asserts the load-bearing
// MAX_CONTINUATION_ATTEMPTS=3 default: with an agent that never produces
// COMPLETE and always reports substantive work, the loop runs exactly 3
// attempts and returns OutcomeNoMoreProgress.
func TestRunContinuation_Default3Attempts(t *testing.T) {
	dir := t.TempDir()
	summary := filepath.Join(dir, "CODER_SUMMARY.md")
	t.Setenv("CODER_SUMMARY_FILE", summary)
	// Seed a summary with IN PROGRESS so each attempt re-enters the loop.
	if err := os.WriteFile(summary, []byte("## Status: IN PROGRESS\n"), 0o644); err != nil {
		t.Fatalf("seed summary: %v", err)
	}

	var attempts int
	deps := &Deps{
		RunAgent: func(_ context.Context, _ *provider.Request) (*provider.Result, error) {
			attempts++
			return &provider.Result{TurnsUsed: 10}, nil
		},
		RenderPrompt: func(string, map[string]string) (string, error) { return "p", nil },
		IsSubstantiveWork: func() bool { return true },
		BuildContinuationContext: func(string, int, int, int, int) string { return "ctx" },
	}

	cfg := DefaultContinuationConfig()
	res, err := RunContinuation(context.Background(), cfg, deps)
	if err != nil {
		t.Fatalf("RunContinuation err = %v", err)
	}
	if attempts != 3 {
		t.Errorf("attempts = %d; want 3", attempts)
	}
	if res.AttemptsRun != 3 {
		t.Errorf("result.AttemptsRun = %d; want 3", res.AttemptsRun)
	}
	if res.Outcome != OutcomeNoMoreProgress {
		t.Errorf("Outcome = %q; want %q", res.Outcome, OutcomeNoMoreProgress)
	}
}

// TestRunContinuation_UpstreamShortCircuit asserts the loop returns after
// one attempt when the agent reports an UPSTREAM error, with
// OutcomeUpstreamError.
func TestRunContinuation_UpstreamShortCircuit(t *testing.T) {
	dir := t.TempDir()
	summary := filepath.Join(dir, "CODER_SUMMARY.md")
	t.Setenv("CODER_SUMMARY_FILE", summary)
	_ = os.WriteFile(summary, []byte("## Status: IN PROGRESS\n"), 0o644)

	var attempts int
	deps := &Deps{
		RunAgent: func(context.Context, *provider.Request) (*provider.Result, error) {
			attempts++
			return &provider.Result{
				TurnsUsed:     5,
				ErrorCategory: "UPSTREAM",
				ErrorMessage:  "quota_exhausted",
			}, nil
		},
		RenderPrompt: func(string, map[string]string) (string, error) { return "p", nil },
		IsSubstantiveWork: func() bool { return true },
		BuildContinuationContext: func(string, int, int, int, int) string { return "" },
	}

	res, err := RunContinuation(context.Background(), DefaultContinuationConfig(), deps)
	if err != nil {
		t.Fatalf("RunContinuation err = %v", err)
	}
	if attempts != 1 {
		t.Errorf("attempts = %d; want 1 (upstream short-circuit)", attempts)
	}
	if res.Outcome != OutcomeUpstreamError {
		t.Errorf("Outcome = %q; want %q", res.Outcome, OutcomeUpstreamError)
	}
}

// TestRunContinuation_CompleteSucceeds asserts the COMPLETE path exits the
// loop with OutcomeComplete.
func TestRunContinuation_CompleteSucceeds(t *testing.T) {
	dir := t.TempDir()
	summary := filepath.Join(dir, "CODER_SUMMARY.md")
	t.Setenv("CODER_SUMMARY_FILE", summary)
	_ = os.WriteFile(summary, []byte("## Status: COMPLETE\n"), 0o644)

	var attempts int
	deps := &Deps{
		RunAgent: func(context.Context, *provider.Request) (*provider.Result, error) {
			attempts++
			return &provider.Result{TurnsUsed: 3}, nil
		},
		RenderPrompt: func(string, map[string]string) (string, error) { return "p", nil },
		IsSubstantiveWork: func() bool { return true },
		BuildContinuationContext: func(string, int, int, int, int) string { return "" },
	}

	res, err := RunContinuation(context.Background(), DefaultContinuationConfig(), deps)
	if err != nil {
		t.Fatalf("RunContinuation err = %v", err)
	}
	if res.Outcome != OutcomeComplete {
		t.Errorf("Outcome = %q; want %q", res.Outcome, OutcomeComplete)
	}
	if attempts != 1 {
		t.Errorf("attempts = %d; want 1", attempts)
	}
}

// TestRunContinuation_DisabledNoop asserts cfg.Enabled=false returns
// immediately without invoking the agent.
func TestRunContinuation_DisabledNoop(t *testing.T) {
	cfg := DefaultContinuationConfig()
	cfg.Enabled = false
	var attempts int
	deps := &Deps{
		RunAgent: func(context.Context, *provider.Request) (*provider.Result, error) {
			attempts++
			return &provider.Result{}, nil
		},
	}
	res, err := RunContinuation(context.Background(), cfg, deps)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if attempts != 0 {
		t.Errorf("disabled: attempts = %d; want 0", attempts)
	}
	if res.Outcome != OutcomeNoMoreProgress {
		t.Errorf("disabled: Outcome = %q; want %q", res.Outcome, OutcomeNoMoreProgress)
	}
}

// TestRunContinuation_AgentErrorPropagates asserts agent errors propagate
// out of the loop.
func TestRunContinuation_AgentErrorPropagates(t *testing.T) {
	sentinel := errors.New("network")
	deps := &Deps{
		RunAgent: func(context.Context, *provider.Request) (*provider.Result, error) {
			return nil, sentinel
		},
		RenderPrompt: func(string, map[string]string) (string, error) { return "p", nil },
	}
	_, err := RunContinuation(context.Background(), DefaultContinuationConfig(), deps)
	if !errors.Is(err, sentinel) {
		t.Errorf("err = %v; want sentinel", err)
	}
}

// TestRunContinuation_PromptRenderErrorPropagates asserts render errors
// surface to the caller.
func TestRunContinuation_PromptRenderErrorPropagates(t *testing.T) {
	deps := &Deps{
		RunAgent: func(context.Context, *provider.Request) (*provider.Result, error) {
			return &provider.Result{}, nil
		},
		RenderPrompt: func(string, map[string]string) (string, error) {
			return "", fmt.Errorf("missing template")
		},
	}
	_, err := RunContinuation(context.Background(), DefaultContinuationConfig(), deps)
	if err == nil {
		t.Errorf("expected render error")
	}
}
