package runner_test

import (
	"context"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/runner"
)

// recordingEmitter captures causal events for assertions.
type recordingEmitter struct {
	events []struct {
		typ    string
		fields map[string]string
	}
}

func (r *recordingEmitter) Emit(typ string, fields map[string]string) {
	r.events = append(r.events, struct {
		typ    string
		fields map[string]string
	}{typ, fields})
}

func (r *recordingEmitter) fallthroughs() []map[string]string {
	var out []map[string]string
	for _, e := range r.events {
		if e.typ == "provider_fallthrough" {
			out = append(out, e.fields)
		}
	}
	return out
}

// TestChain_EmitsProviderFallthrough — m21 gap. When the chain abandons a
// provider on OutcomeUpstreamError for the next one, it emits exactly one
// provider_fallthrough event naming from/to.
func TestChain_EmitsProviderFallthrough(t *testing.T) {
	p1 := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	p2 := &fixedProvider{name: "qwen-local", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	rec := &recordingEmitter{}
	c := runner.NewChain(p1, p2)
	c.Causal = rec

	res, err := c.RunAgent(context.Background(), &provider.Request{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Fatalf("Outcome: want Success, got %v", res.Outcome)
	}

	ft := rec.fallthroughs()
	if len(ft) != 1 {
		t.Fatalf("want exactly 1 provider_fallthrough event, got %d", len(ft))
	}
	if ft[0]["from"] != "codex" {
		t.Errorf("from: want codex, got %q", ft[0]["from"])
	}
	if ft[0]["to"] != "qwen-local" {
		t.Errorf("to: want qwen-local, got %q", ft[0]["to"])
	}
}

// TestChain_NoFallthroughOnFirstSuccess — the first provider succeeding emits
// no fallthrough event.
func TestChain_NoFallthroughOnFirstSuccess(t *testing.T) {
	p1 := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	p2 := &fixedProvider{name: "qwen-local", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	rec := &recordingEmitter{}
	c := runner.NewChain(p1, p2)
	c.Causal = rec

	if _, err := c.RunAgent(context.Background(), &provider.Request{}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if n := len(rec.fallthroughs()); n != 0 {
		t.Errorf("want 0 fallthrough events on first-success, got %d", n)
	}
}

// TestChain_NilCausalSafe — a nil Causal emitter must not panic on fallthrough.
func TestChain_NilCausalSafe(t *testing.T) {
	p1 := &fixedProvider{name: "codex", tier: provider.TierSubscription, outcome: provider.OutcomeUpstreamError}
	p2 := &fixedProvider{name: "qwen-local", tier: provider.TierSubscription, outcome: provider.OutcomeSuccess}
	c := runner.NewChain(p1, p2) // Causal left nil
	if _, err := c.RunAgent(context.Background(), &provider.Request{}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
