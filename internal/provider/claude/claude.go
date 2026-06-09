// Package claude is the Claude CLI provider implementation. It wraps
// internal/supervisor/ without modifying it. m01 ships this as the
// reference implementation; m02 retires direct supervisor calls from
// stages so the supervisor becomes purely internal to this package.
package claude

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// supervisorRunner is the subset of *supervisor.Supervisor used by Provider.
// Defined as an interface so parity tests can inject a stub without
// modifying the supervisor package.
type supervisorRunner interface {
	Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
}

// Compile-time assertions.
var (
	_ supervisorRunner  = (*supervisor.Supervisor)(nil)
	_ provider.Provider = (*Provider)(nil)
)

// Provider implements provider.Provider against the Claude CLI via the
// supervisor package.
type Provider struct {
	// Supervisor is the underlying process runner. Production callers use
	// a *supervisor.Supervisor via New; tests inject a stub directly:
	//   &Provider{Supervisor: &stubSup{...}}
	Supervisor supervisorRunner
}

// New constructs a Claude provider backed by sup. The supervisor's causal-log
// and state-store arguments may be nil; it degrades gracefully.
func New(sup *supervisor.Supervisor) *Provider {
	return &Provider{Supervisor: sup}
}

// Name returns the provider's canonical name.
func (p *Provider) Name() string { return "claude" }

// Tier returns the cost tier of this Claude provider invocation.
//
// Post-2026-06-15: Anthropic switched `claude --print` to API-metered
// pricing regardless of Max subscription. Every invocation costs at
// API rates (~15x prior subscription cost). Tier returns TierAPI.
//
// Operators who are verifiably pre-June-15 OR have grandfathered
// subscription access can set TEKHTON_CLAUDE_PRE_JUNE_15=true to
// override. This is intentionally an env, not a config file knob,
// to keep it explicit + per-environment.
func (p *Provider) Tier() string {
	if os.Getenv("TEKHTON_CLAUDE_PRE_JUNE_15") == "true" {
		return provider.TierSubscription
	}
	return provider.TierAPI
}

// RunAgent translates req into a supervisor invocation, runs it, and
// returns the translated provider.Result. When req.EventChan is non-nil,
// RunAgent emits EventTurnStart before the run, then EventTurnEnd and
// EventRunEnd after, and closes the channel. Callers that set EventChan
// MUST consume it concurrently or ensure it is sufficiently buffered:
//
//	for ev := range ch { ... }
//
// The prompt is written to a temp file (the supervisor requires a file
// path). The file is removed before RunAgent returns.
func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
	if req == nil {
		return nil, errors.New("claude provider: nil request")
	}
	if p.Supervisor == nil {
		return nil, errors.New("claude provider: nil supervisor")
	}
	if req.EventChan != nil {
		defer close(req.EventChan)
	}

	promptPath, cleanup, err := writePromptFile(req.Prompt)
	if err != nil {
		return nil, fmt.Errorf("claude provider: %w", err)
	}
	defer cleanup()

	if req.EventChan != nil {
		req.EventChan <- provider.Event{
			Kind:      provider.EventTurnStart,
			Timestamp: time.Now(),
			Turn:      1,
		}
	}

	spec := &supervisor.AgentSpec{
		Label:      labelOrDefault(req.Label),
		Model:      req.Model,
		MaxTurns:   req.MaxTurns,
		PromptFile: promptPath,
		Timeout:    req.Timeout,
		WorkingDir: req.WorkingDir,
	}
	protoReq := spec.ToProto()
	if req.AllowedTools != "" {
		protoReq.AllowedTools = req.AllowedTools
	}
	v1, supErr := p.Supervisor.Run(ctx, protoReq)

	if req.EventChan != nil {
		turnsUsed := 0
		if v1 != nil {
			turnsUsed = v1.TurnsUsed
		}
		req.EventChan <- provider.Event{
			Kind:      provider.EventTurnEnd,
			Timestamp: time.Now(),
			Turn:      turnsUsed,
		}
		req.EventChan <- provider.Event{
			Kind:      provider.EventRunEnd,
			Timestamp: time.Now(),
		}
	}

	if supErr != nil {
		if v1 != nil {
			return translateResult(v1), supErr
		}
		return nil, fmt.Errorf("claude provider: supervisor: %w", supErr)
	}
	if v1 == nil {
		return nil, errors.New("claude provider: supervisor returned nil result without error")
	}
	return translateResult(v1), nil
}

// translateResult converts a supervisor wire result to a provider.Result.
func translateResult(v1 *proto.AgentResultV1) *provider.Result {
	res := supervisor.FromProto(v1)
	raw, _ := json.Marshal(v1)
	return &provider.Result{
		Outcome:          translateOutcome(res),
		TurnsUsed:        res.TurnsUsed,
		ExitCode:         res.ExitCode,
		ErrorCategory:    res.ErrorCategory,
		ErrorSubcategory: res.ErrorSubcategory,
		ErrorMessage:     res.ErrorMessage,
		NullRun:          res.IsNullRun(),
		RawProviderData:  raw,
	}
}

// translateOutcome maps the supervisor's outcome vocabulary to provider.Outcome.
// This mapping table is the contract for m02–m08 implementers.
// OutcomeUnknown is the safety net for unrecognised categories — stages treat
// it as a failure warranting investigation, never as success.
func translateOutcome(res *supervisor.AgentResult) provider.Outcome {
	if res.IsNullRun() {
		return provider.OutcomeNullRun
	}
	if res.ErrorCategory == supervisor.CategoryUpstream {
		return provider.OutcomeUpstreamError
	}
	switch res.Outcome {
	case proto.OutcomeActivityTimeout:
		return provider.OutcomeTimeout
	case proto.OutcomeTurnExhausted:
		return provider.OutcomeMaxTurns
	case proto.OutcomeSuccess:
		return provider.OutcomeSuccess
	}
	if res.ExitCode == 0 {
		return provider.OutcomeSuccess
	}
	return provider.OutcomeUnknown
}

// writePromptFile writes prompt to a temp file and returns its path.
// The returned cleanup removes the file; callers MUST defer it.
func writePromptFile(prompt string) (path string, cleanup func(), err error) {
	f, ferr := os.CreateTemp("", "tekhton-provider-*.prompt")
	if ferr != nil {
		return "", nil, fmt.Errorf("writing prompt file: %w", ferr)
	}
	if _, werr := f.WriteString(prompt); werr != nil {
		f.Close()
		os.Remove(f.Name())
		return "", nil, fmt.Errorf("writing prompt file: %w", werr)
	}
	if cerr := f.Close(); cerr != nil {
		os.Remove(f.Name())
		return "", nil, fmt.Errorf("writing prompt file: %w", cerr)
	}
	path = f.Name()
	return path, func() { os.Remove(path) }, nil
}

// labelOrDefault returns label if non-empty, otherwise "agent".
func labelOrDefault(label string) string {
	if label == "" {
		return "agent"
	}
	return label
}
