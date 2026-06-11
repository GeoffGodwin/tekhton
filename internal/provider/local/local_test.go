package local_test

import (
	"context"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/local"
)

// stubInner is a test double for the inner codex provider.
type stubInner struct {
	gotReq *provider.Request
	result *provider.Result
	err    error
}

func (s *stubInner) Name() string { return "stub" }
func (s *stubInner) Tier() string { return provider.TierAPI }
func (s *stubInner) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	clone := *req
	s.gotReq = &clone
	return s.result, s.err
}

func TestProvider_Name(t *testing.T) {
	p := local.NewWithInner(&stubInner{})
	if got := p.Name(); got != "qwen-local" {
		t.Errorf("Name: want qwen-local, got %q", got)
	}
}

func TestProvider_Tier(t *testing.T) {
	p := local.NewWithInner(&stubInner{})
	if got := p.Tier(); got != provider.TierLocal {
		t.Errorf("Tier: want %q, got %q", provider.TierLocal, got)
	}
}

// TestProvider_TierCostRank asserts local ranks cheaper than subscription and api.
func TestProvider_TierCostRank(t *testing.T) {
	localRank := provider.TierCostRank(provider.TierLocal)
	subRank := provider.TierCostRank(provider.TierSubscription)
	apiRank := provider.TierCostRank(provider.TierAPI)
	if localRank >= subRank {
		t.Errorf("TierLocal cost rank (%d) should be < TierSubscription (%d)", localRank, subRank)
	}
	if localRank >= apiRank {
		t.Errorf("TierLocal cost rank (%d) should be < TierAPI (%d)", localRank, apiRank)
	}
}

func TestProvider_RunAgent_InjectsEndpointConfig(t *testing.T) {
	t.Setenv("QWEN_LOCAL_BASE_URL", "http://test-host:11434/v1")
	t.Setenv("QWEN_LOCAL_MODEL", "test-model:7b")
	t.Setenv("QWEN_LOCAL_PROVIDER_ID", "testprovider")
	t.Setenv("QWEN_LOCAL_WIRE_API", "chat")

	stub := &stubInner{result: &provider.Result{Outcome: provider.OutcomeSuccess}}
	p := local.NewWithInner(stub)

	origPS := map[string]string{"existing": "value"}
	req := &provider.Request{Prompt: "test", ProviderSpecific: origPS}

	res, err := p.RunAgent(context.Background(), req)
	if err != nil {
		t.Fatalf("RunAgent: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want Success, got %v", res.Outcome)
	}
	if stub.gotReq.Model != "test-model:7b" {
		t.Errorf("Model: want test-model:7b, got %q", stub.gotReq.Model)
	}
	baseURLKey := "codex.config.model_providers.testprovider.base_url"
	if got := stub.gotReq.ProviderSpecific[baseURLKey]; got != "http://test-host:11434/v1" {
		t.Errorf("ProviderSpecific[%s]: want http://test-host:11434/v1, got %q", baseURLKey, got)
	}
	wireAPIKey := "codex.config.model_providers.testprovider.wire_api"
	if got := stub.gotReq.ProviderSpecific[wireAPIKey]; got != "chat" {
		t.Errorf("ProviderSpecific[%s]: want chat, got %q", wireAPIKey, got)
	}
	// Existing caller key must flow through to the delegated request.
	if got := stub.gotReq.ProviderSpecific["existing"]; got != "value" {
		t.Errorf("delegated ProviderSpecific[existing]: want value, got %q", got)
	}
}

// TestProvider_RunAgent_PreservesCallerMap asserts the caller's ProviderSpecific
// map is not mutated when RunAgent injects the local endpoint keys.
func TestProvider_RunAgent_PreservesCallerMap(t *testing.T) {
	stub := &stubInner{result: &provider.Result{Outcome: provider.OutcomeSuccess}}
	p := local.NewWithInner(stub)

	origPS := map[string]string{"existing": "value"}
	if _, err := p.RunAgent(context.Background(), &provider.Request{
		Prompt: "test", ProviderSpecific: origPS,
	}); err != nil {
		t.Fatalf("RunAgent: %v", err)
	}
	if _, injected := origPS["codex.config.model_provider"]; injected {
		t.Error("RunAgent mutated the caller's ProviderSpecific map")
	}
	if v := origPS["existing"]; v != "value" {
		t.Errorf("origPS[existing] lost: want value, got %q", v)
	}
}

// TestProvider_RunAgent_DefaultConfig asserts that defaults apply when
// QWEN_LOCAL_* env vars are absent.
func TestProvider_RunAgent_DefaultConfig(t *testing.T) {
	t.Setenv("QWEN_LOCAL_BASE_URL", "")
	t.Setenv("QWEN_LOCAL_MODEL", "")
	t.Setenv("QWEN_LOCAL_PROVIDER_ID", "")
	t.Setenv("QWEN_LOCAL_WIRE_API", "")

	stub := &stubInner{result: &provider.Result{Outcome: provider.OutcomeSuccess}}
	p := local.NewWithInner(stub)

	if _, err := p.RunAgent(context.Background(), &provider.Request{Prompt: "test"}); err != nil {
		t.Fatalf("RunAgent: %v", err)
	}
	if stub.gotReq.Model != "qwen2.5-coder:32b" {
		t.Errorf("Model: want qwen2.5-coder:32b, got %q", stub.gotReq.Model)
	}
	baseURLKey := "codex.config.model_providers.qwenlocal.base_url"
	if got := stub.gotReq.ProviderSpecific[baseURLKey]; got != "http://localhost:11434/v1" {
		t.Errorf("ProviderSpecific[%s]: want http://localhost:11434/v1, got %q", baseURLKey, got)
	}
	wireAPIKey := "codex.config.model_providers.qwenlocal.wire_api"
	if got := stub.gotReq.ProviderSpecific[wireAPIKey]; got != "chat" {
		t.Errorf("ProviderSpecific[%s]: want chat, got %q", wireAPIKey, got)
	}
}

// TestProvider_RunAgent_DelegatesOutcome asserts the inner provider's outcome
// is returned unchanged via the delegation path.
func TestProvider_RunAgent_DelegatesOutcome(t *testing.T) {
	for _, outcome := range []provider.Outcome{
		provider.OutcomeSuccess,
		provider.OutcomeMaxTurns,
		provider.OutcomeUpstreamError,
	} {
		stub := &stubInner{result: &provider.Result{Outcome: outcome}}
		p := local.NewWithInner(stub)
		res, err := p.RunAgent(context.Background(), &provider.Request{Prompt: "x"})
		if err != nil {
			t.Fatalf("outcome %v: RunAgent error: %v", outcome, err)
		}
		if res.Outcome != outcome {
			t.Errorf("outcome %v: got %v", outcome, res.Outcome)
		}
	}
}
