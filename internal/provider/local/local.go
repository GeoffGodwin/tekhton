// Package local is the qwen-local provider — a codex-delegation wrapper
// that routes agent calls to a local OpenAI-compatible endpoint (Ollama,
// llama.cpp, vLLM).
//
// V5 m17 — Scaffold: delegation struct, Name/Tier, RunAgent injection.
// The inner codex provider executes the proven exec/streaming/JSONL/outcome
// pipeline unchanged; local injects the model_provider config keys that
// codex's -c passthrough understands so it connects to the local endpoint.
package local

import (
	"context"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/codex"
)

const (
	defaultBaseURL    = "http://localhost:11434/v1"
	defaultModel      = "qwen2.5-coder:32b"
	defaultProviderID = "qwenlocal"
	defaultWireAPI    = "chat"
)

// Provider routes agent calls to a local OpenAI-compatible endpoint
// by injecting model_provider config keys into a delegated codex provider's
// -c passthrough. Tier returns TierLocal unconditionally.
type Provider struct {
	inner   provider.Provider
	baseURL string
	model   string
	id      string
	wireAPI string
}

// New constructs a Provider wrapping a real codex process pointed at the
// configured local endpoint. Returns an error when codex is not on PATH —
// the local provider delegates to codex for exec, streaming, JSONL decode,
// and outcome mapping; codex must be present for qwen-local to function.
func New() (*Provider, error) {
	inner, err := codex.New()
	if err != nil {
		return nil, fmt.Errorf("qwen-local provider: %w", err)
	}
	return newWithInner(inner), nil
}

// NewWithInner is the test seam — inject a stub inner provider without
// needing codex on PATH. Exported so package-level tests in local_test.go
// can reach it; production callers use New().
func NewWithInner(inner provider.Provider) *Provider {
	return newWithInner(inner)
}

func newWithInner(inner provider.Provider) *Provider {
	baseURL := os.Getenv("QWEN_LOCAL_BASE_URL")
	if baseURL == "" {
		baseURL = defaultBaseURL
	}
	model := os.Getenv("QWEN_LOCAL_MODEL")
	if model == "" {
		model = defaultModel
	}
	id := os.Getenv("QWEN_LOCAL_PROVIDER_ID")
	if id == "" {
		id = defaultProviderID
	}
	wireAPI := os.Getenv("QWEN_LOCAL_WIRE_API")
	if wireAPI == "" {
		wireAPI = defaultWireAPI
	}
	return &Provider{inner: inner, baseURL: baseURL, model: model, id: id, wireAPI: wireAPI}
}

// Name returns "qwen-local" — the canonical provider name used for routing,
// telemetry, and operator-facing banners.
func (p *Provider) Name() string { return "qwen-local" }

// Tier returns TierLocal unconditionally. Local endpoints have no quota
// probe or subscription check — cost rank 0 (cheapest) always applies.
func (p *Provider) Tier() string { return provider.TierLocal }

// RunAgent injects local endpoint config into the delegated request and
// forwards to the inner codex provider. The caller's ProviderSpecific map
// is never mutated; a fresh copy is passed to the inner provider.
func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
	r := *req
	r.Model = p.model
	r.ProviderSpecific = cloneAndInject(req.ProviderSpecific, map[string]string{
		"codex.config.model_provider":                            p.id,
		"codex.config.model_providers." + p.id + ".name":         "qwen-local",
		"codex.config.model_providers." + p.id + ".base_url":     p.baseURL,
		"codex.config.model_providers." + p.id + ".wire_api":     p.wireAPI,
	})
	return p.inner.RunAgent(ctx, &r)
}

// cloneAndInject returns a new map containing all entries from base plus the
// provided extras. base may be nil.
func cloneAndInject(base, extras map[string]string) map[string]string {
	out := make(map[string]string, len(base)+len(extras))
	for k, v := range base {
		out[k] = v
	}
	for k, v := range extras {
		out[k] = v
	}
	return out
}
