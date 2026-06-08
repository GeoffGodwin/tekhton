package provider_test

import (
	"context"
	"reflect"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// TestProviderInterface_MethodCount asserts the Provider interface has
// exactly two methods.
func TestProviderInterface_MethodCount(t *testing.T) {
	iface := reflect.TypeOf((*provider.Provider)(nil)).Elem()
	if n := iface.NumMethod(); n != 2 {
		t.Errorf("Provider: want 2 methods, got %d", n)
	}
}

// TestProviderInterface_MethodNames asserts the exact method set.
func TestProviderInterface_MethodNames(t *testing.T) {
	iface := reflect.TypeOf((*provider.Provider)(nil)).Elem()
	have := make(map[string]bool, iface.NumMethod())
	for i := range iface.NumMethod() {
		have[iface.Method(i).Name] = true
	}
	for _, want := range []string{"Name", "RunAgent"} {
		if !have[want] {
			t.Errorf("Provider interface missing method: %s", want)
		}
	}
}

// TestOutcomeConstants asserts all Outcome values are distinct and
// OutcomeUnknown is the zero value.
func TestOutcomeConstants(t *testing.T) {
	if provider.OutcomeUnknown != 0 {
		t.Errorf("OutcomeUnknown must be 0 (iota zero), got %d", provider.OutcomeUnknown)
	}
	seen := map[provider.Outcome]string{}
	for _, c := range []struct {
		v    provider.Outcome
		name string
	}{
		{provider.OutcomeUnknown, "OutcomeUnknown"},
		{provider.OutcomeSuccess, "OutcomeSuccess"},
		{provider.OutcomeUpstreamError, "OutcomeUpstreamError"},
		{provider.OutcomeTimeout, "OutcomeTimeout"},
		{provider.OutcomeMaxTurns, "OutcomeMaxTurns"},
		{provider.OutcomeNullRun, "OutcomeNullRun"},
		{provider.OutcomeAborted, "OutcomeAborted"},
	} {
		if prev, dup := seen[c.v]; dup {
			t.Errorf("duplicate Outcome value %d: %s and %s", c.v, prev, c.name)
		}
		seen[c.v] = c.name
	}
}

// TestEventKindConstants asserts all EventKind values are distinct and
// EventUnknown is the zero value.
func TestEventKindConstants(t *testing.T) {
	if provider.EventUnknown != 0 {
		t.Errorf("EventUnknown must be 0 (iota zero), got %d", provider.EventUnknown)
	}
	seen := map[provider.EventKind]string{}
	for _, c := range []struct {
		v    provider.EventKind
		name string
	}{
		{provider.EventUnknown, "EventUnknown"},
		{provider.EventTurnStart, "EventTurnStart"},
		{provider.EventAssistantChunk, "EventAssistantChunk"},
		{provider.EventToolCall, "EventToolCall"},
		{provider.EventToolResult, "EventToolResult"},
		{provider.EventTurnEnd, "EventTurnEnd"},
		{provider.EventRunEnd, "EventRunEnd"},
	} {
		if prev, dup := seen[c.v]; dup {
			t.Errorf("duplicate EventKind value %d: %s and %s", c.v, prev, c.name)
		}
		seen[c.v] = c.name
	}
}

// stubProvider satisfies provider.Provider for compile-time and runtime checks.
type stubProvider struct{ name string }

func (s *stubProvider) Name() string { return s.name }
func (s *stubProvider) RunAgent(_ context.Context, _ *provider.Request) (*provider.Result, error) {
	return &provider.Result{Outcome: provider.OutcomeSuccess}, nil
}

// TestProviderAssignability confirms a concrete type can be assigned to
// provider.Provider and dispatches correctly.
func TestProviderAssignability(t *testing.T) {
	var p provider.Provider = &stubProvider{name: "stub"}
	if got := p.Name(); got != "stub" {
		t.Errorf("Name: want stub, got %s", got)
	}
	res, err := p.RunAgent(context.Background(), &provider.Request{})
	if err != nil {
		t.Fatalf("RunAgent: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome: want OutcomeSuccess, got %d", res.Outcome)
	}
}
