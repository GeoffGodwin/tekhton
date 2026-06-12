package runner

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// sanitizeLabel converts an agent label to a PROVIDER_<LABEL> env-key suffix.
// Non-alphanumeric characters become '_'; letters are uppercased.
// Example: "Test Fix (attempt 2)" → "TEST_FIX__ATTEMPT_2_"
func sanitizeLabel(label string) string {
	var b strings.Builder
	for _, r := range label {
		switch {
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r)
		case r >= 'a' && r <= 'z':
			b.WriteRune(r - 32)
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	return b.String()
}

// ProviderFromRequest resolves the provider to use for a supervise request.
// Resolution order:
//  1. req.Provider field — named provider, bypasses env vars entirely.
//  2. PROVIDER_<LABEL>=, PROVIDER=, default "codex,claude" via ResolveProvider.
//
// An unknown provider name in req.Provider wraps proto.ErrInvalidRequest so
// the CLI layer maps it to exitUsage.
func ProviderFromRequest(req *proto.AgentRequestV1) (provider.Provider, error) {
	if req.Provider != "" {
		p, err := constructProvider(req.Provider)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", proto.ErrInvalidRequest, err)
		}
		return p, nil
	}
	return ResolveProvider(sanitizeLabel(req.Label))
}

// BridgeToProviderRequest converts a proto.AgentRequestV1 envelope to a
// provider.Request. Reads the prompt file from disk (provider.Request.Prompt
// is the content, not the path). Returns an error if the file cannot be read.
func BridgeToProviderRequest(req *proto.AgentRequestV1) (*provider.Request, error) {
	content, err := os.ReadFile(req.PromptFile)
	if err != nil {
		return nil, fmt.Errorf("supervise_bridge: read prompt_file: %w", err)
	}
	var timeout time.Duration
	if req.TimeoutSecs > 0 {
		timeout = time.Duration(req.TimeoutSecs) * time.Second
	}
	return &provider.Request{
		Prompt:       string(content),
		MaxTurns:     req.MaxTurns,
		Model:        req.Model,
		Label:        req.Label,
		Timeout:      timeout,
		WorkingDir:   req.WorkingDir,
		AllowedTools: req.AllowedTools,
	}, nil
}

// BridgeFromProviderResult converts a provider.Result back to a
// proto.AgentResultV1 envelope for emission on stdout.
//
// When RawProviderData is a valid proto.AgentResultV1 JSON (set by the claude
// provider), that is used directly for full fidelity. Otherwise the result is
// synthesized from provider.Result fields. A nil res produces a fatal error
// envelope — callers should prefer not calling this with nil.
func BridgeFromProviderResult(res *provider.Result, req *proto.AgentRequestV1) *proto.AgentResultV1 {
	if res == nil {
		return &proto.AgentResultV1{
			Proto:    proto.AgentResultProtoV1,
			Label:    req.Label,
			RunID:    req.RunID,
			ExitCode: 1,
			Outcome:  proto.OutcomeFatalError,
		}
	}
	if len(res.RawProviderData) > 0 {
		var v1 proto.AgentResultV1
		if err := json.Unmarshal(res.RawProviderData, &v1); err == nil {
			v1.Label = req.Label
			if req.RunID != "" {
				v1.RunID = req.RunID
			}
			return &v1
		}
	}
	return &proto.AgentResultV1{
		Proto:            proto.AgentResultProtoV1,
		Label:            req.Label,
		RunID:            req.RunID,
		ExitCode:         res.ExitCode,
		TurnsUsed:        res.TurnsUsed,
		Outcome:          bridgeProviderOutcome(res.Outcome),
		ErrorCategory:    res.ErrorCategory,
		ErrorSubcategory: res.ErrorSubcategory,
		ErrorMessage:     res.ErrorMessage,
	}
}

func bridgeProviderOutcome(o provider.Outcome) string {
	switch o {
	case provider.OutcomeSuccess, provider.OutcomeNullRun:
		return proto.OutcomeSuccess
	case provider.OutcomeMaxTurns:
		return proto.OutcomeTurnExhausted
	case provider.OutcomeTimeout:
		return proto.OutcomeActivityTimeout
	case provider.OutcomeUpstreamError:
		return proto.OutcomeTransientError
	default:
		return proto.OutcomeFatalError
	}
}

// ProtoAgentRunner adapts a provider.Provider to the proto-level AgentRunner
// interface used by internal/tester/tdd and internal/test_audit. Callers
// inject this via tdd.SetAgentRunner / testaudit.SetAgentRunner so those
// packages receive a resolved provider without importing the runner package.
type ProtoAgentRunner struct {
	P provider.Provider
}

// Run implements the AgentRunner interface expected by tdd and test_audit:
//
//	Run(ctx, *proto.AgentRequestV1) (*proto.AgentResultV1, error)
//
// It bridges the request to provider.Request, calls P.RunAgent, and converts
// the result back to proto.AgentResultV1.
func (r *ProtoAgentRunner) Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	provReq, err := BridgeToProviderRequest(req)
	if err != nil {
		return nil, err
	}
	provRes, runErr := r.P.RunAgent(ctx, provReq)
	res := BridgeFromProviderResult(provRes, req)
	return res, runErr
}
