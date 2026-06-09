package provider_test

import (
	"context"
	"reflect"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// TestProviderInterface_MethodCount asserts the Provider interface has
// exactly three methods: Name, Tier, RunAgent.
func TestProviderInterface_MethodCount(t *testing.T) {
	iface := reflect.TypeOf((*provider.Provider)(nil)).Elem()
	if n := iface.NumMethod(); n != 3 {
		t.Errorf("Provider: want 3 methods, got %d", n)
	}
}

// TestTierConstants verifies the four tier string values match the spec.
func TestTierConstants(t *testing.T) {
	cases := []struct {
		name string
		got  string
		want string
	}{
		{"TierSubscription", provider.TierSubscription, "subscription"},
		{"TierAPI", provider.TierAPI, "api"},
		{"TierLocal", provider.TierLocal, "local"},
		{"TierUnknown", provider.TierUnknown, "unknown"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %q, want %q", c.name, c.got, c.want)
		}
	}
}

// TestTierCostRank verifies the rank ordering: local(0) < subscription(1) < api(2) < unknown(3).
func TestTierCostRank(t *testing.T) {
	cases := []struct {
		tier string
		want int
	}{
		{provider.TierLocal, 0},
		{provider.TierSubscription, 1},
		{provider.TierAPI, 2},
		{provider.TierUnknown, 3},
		{"", 3},        // empty falls through to default
		{"future", 3},  // unknown future tier
	}
	for _, c := range cases {
		if got := provider.TierCostRank(c.tier); got != c.want {
			t.Errorf("TierCostRank(%q) = %d, want %d", c.tier, got, c.want)
		}
	}
}

// TestTierCostRank_OrderProperty asserts local < subscription < api.
func TestTierCostRank_OrderProperty(t *testing.T) {
	if provider.TierCostRank(provider.TierLocal) >= provider.TierCostRank(provider.TierSubscription) {
		t.Error("local must rank cheaper than subscription")
	}
	if provider.TierCostRank(provider.TierSubscription) >= provider.TierCostRank(provider.TierAPI) {
		t.Error("subscription must rank cheaper than api")
	}
	if provider.TierCostRank(provider.TierAPI) >= provider.TierCostRank(provider.TierUnknown) {
		t.Error("api must rank cheaper than unknown")
	}
}

// TestResult_TierUsedField asserts provider.Result has a TierUsed string field.
func TestResult_TierUsedField(t *testing.T) {
	res := &provider.Result{TierUsed: provider.TierAPI}
	if res.TierUsed != provider.TierAPI {
		t.Errorf("TierUsed: want %q, got %q", provider.TierAPI, res.TierUsed)
	}
	// Zero value should be empty string (not set by single-provider invocations).
	var zero provider.Result
	if zero.TierUsed != "" {
		t.Errorf("TierUsed zero value: want empty string, got %q", zero.TierUsed)
	}
}

// TestProviderInterface_MethodNames asserts the exact method set.
func TestProviderInterface_MethodNames(t *testing.T) {
	iface := reflect.TypeOf((*provider.Provider)(nil)).Elem()
	have := make(map[string]bool, iface.NumMethod())
	for i := range iface.NumMethod() {
		have[iface.Method(i).Name] = true
	}
	for _, want := range []string{"Name", "Tier", "RunAgent"} {
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

func (s *stubProvider) Name() string  { return s.name }
func (s *stubProvider) Tier() string  { return provider.TierUnknown }
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
