package runner_test

import (
	"context"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/runner"
)

// recordingProvider captures the request it received so tests can assert
// per-provider profile application.
type recordingProvider struct {
	name    string
	tier    string
	outcome provider.Outcome
	gotReq  *provider.Request
}

func (r *recordingProvider) Name() string { return r.name }
func (r *recordingProvider) Tier() string { return r.tier }
func (r *recordingProvider) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	r.gotReq = req
	return &provider.Result{Outcome: r.outcome}, nil
}

// TestChain_AppliesProfilePerProvider — m22 acceptance #6. In a codex,qwen-local
// chain, a fallthrough to qwen-local applies qwen-local's profile (turn scale +
// reinforcement); the codex attempt (zero profile) is unchanged.
func TestChain_AppliesProfilePerProvider(t *testing.T) {
	t.Setenv("PROJECT_DIR", t.TempDir()) // no override files
	t.Setenv("CHARS_PER_TOKEN", "4")

	codex := &recordingProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	qwen := &recordingProvider{name: "qwen-local", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(codex, qwen)

	if _, err := c.RunAgent(context.Background(), &provider.Request{MaxTurns: 20, Prompt: "body"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// codex: zero profile → unchanged.
	if codex.gotReq.MaxTurns != 20 {
		t.Errorf("codex MaxTurns: want 20 (no profile), got %d", codex.gotReq.MaxTurns)
	}
	if codex.gotReq.Prompt != "body" {
		t.Errorf("codex prompt altered (should not be): %q", codex.gotReq.Prompt)
	}
	// qwen-local: factor 1.5 → 30, reinforcement prepended.
	if qwen.gotReq.MaxTurns != 30 {
		t.Errorf("qwen-local MaxTurns: want 30 (×1.5), got %d", qwen.gotReq.MaxTurns)
	}
	if !strings.HasPrefix(qwen.gotReq.Prompt, "IMPORTANT") {
		t.Errorf("qwen-local prompt not reinforced: %q", qwen.gotReq.Prompt)
	}
}

// TestAsKV_ProviderContextPct — m22 acceptance #7. The first-choice provider's
// profile ContextBudgetPct is exported as TEKHTON_PROVIDER_CONTEXT_PCT; a
// provider with no profile budget exports nothing.
func TestAsKV_ProviderContextPct(t *testing.T) {
	t.Setenv("PROJECT_DIR", t.TempDir())
	t.Setenv("CHARS_PER_TOKEN", "4")
	b := runner.NewEnvBuilder(nil, runner.LogContext{})

	kv := b.AsKV(&proto.StageEnvV1{ConfigKeys: map[string]string{"PROVIDER": "qwen-local"}})
	if !hasKV(kv, "TEKHTON_PROVIDER_CONTEXT_PCT=25") {
		t.Errorf("want TEKHTON_PROVIDER_CONTEXT_PCT=25 for qwen-local; got %v", kv)
	}

	kv2 := b.AsKV(&proto.StageEnvV1{ConfigKeys: map[string]string{"PROVIDER": "codex"}})
	for _, e := range kv2 {
		if strings.HasPrefix(e, "TEKHTON_PROVIDER_CONTEXT_PCT=") {
			t.Errorf("codex (zero profile) must not export TEKHTON_PROVIDER_CONTEXT_PCT; got %q", e)
		}
	}

	// First-choice in a chain spec wins.
	kv3 := b.AsKV(&proto.StageEnvV1{ConfigKeys: map[string]string{"PROVIDER": "qwen-local,codex"}})
	if !hasKV(kv3, "TEKHTON_PROVIDER_CONTEXT_PCT=25") {
		t.Errorf("first-choice qwen-local should export budget; got %v", kv3)
	}
}

func hasKV(kv []string, want string) bool {
	for _, e := range kv {
		if e == want {
			return true
		}
	}
	return false
}
