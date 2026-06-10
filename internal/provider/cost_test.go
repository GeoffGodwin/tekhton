package provider_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// TestDefaultEstimator_SubscriptionTierIsZero verifies that subscription-tier
// results cost $0 regardless of token usage. This is the primary happy path
// for subscription operators who should never see a cost charged.
func TestDefaultEstimator_SubscriptionTierIsZero(t *testing.T) {
	dir := t.TempDir()
	writeDefaultRates(t, dir)
	t.Setenv("TEKHTON_COST_RATES_FILE", filepath.Join(dir, "costrates.json"))

	est := provider.NewDefaultEstimator()
	res := &provider.Result{
		TierUsed: provider.TierSubscription,
	}
	// Embed token counts directly in the result to simulate a real run.
	res.TokenUsage.InputTokens = 50_000
	res.TokenUsage.OutputTokens = 10_000

	got := est.EstimateCents(res, "codex", provider.TierSubscription)
	if got != 0 {
		t.Errorf("EstimateCents(subscription): want 0, got %d", got)
	}
}

// TestDefaultEstimator_LocalTierIsZero verifies local-tier results cost $0.
func TestDefaultEstimator_LocalTierIsZero(t *testing.T) {
	dir := t.TempDir()
	writeDefaultRates(t, dir)
	t.Setenv("TEKHTON_COST_RATES_FILE", filepath.Join(dir, "costrates.json"))

	est := provider.NewDefaultEstimator()
	res := &provider.Result{TierUsed: provider.TierLocal}
	res.TokenUsage.InputTokens = 100_000
	res.TokenUsage.OutputTokens = 50_000

	got := est.EstimateCents(res, "qwen", provider.TierLocal)
	if got != 0 {
		t.Errorf("EstimateCents(local): want 0, got %d", got)
	}
}

// TestDefaultEstimator_APITierIsNonZero verifies that api-tier results with
// non-zero token usage produce a positive cost. This is the primary observable
// behavior operators rely on to see dollars charged.
func TestDefaultEstimator_APITierIsNonZero(t *testing.T) {
	dir := t.TempDir()
	writeDefaultRates(t, dir)
	t.Setenv("TEKHTON_COST_RATES_FILE", filepath.Join(dir, "costrates.json"))

	est := provider.NewDefaultEstimator()
	res := &provider.Result{TierUsed: provider.TierAPI}
	res.TokenUsage.InputTokens = 1_000_000  // 1M input tokens at claude:api = 300 cents
	res.TokenUsage.OutputTokens = 0

	got := est.EstimateCents(res, "claude", provider.TierAPI)
	if got <= 0 {
		t.Errorf("EstimateCents(api, 1M input): want >0, got %d", got)
	}
}

// TestDefaultEstimator_ClaudeAPIRate verifies the exact cent calculation for
// the claude:api tier rate: 300 input-cents/1M, 1500 output-cents/1M.
func TestDefaultEstimator_ClaudeAPIRate(t *testing.T) {
	dir := t.TempDir()
	writeDefaultRates(t, dir)
	t.Setenv("TEKHTON_COST_RATES_FILE", filepath.Join(dir, "costrates.json"))

	est := provider.NewDefaultEstimator()
	res := &provider.Result{TierUsed: provider.TierAPI}
	// 1M input tokens → 300 cents; 1M output tokens → 1500 cents; total = 1800 cents
	res.TokenUsage.InputTokens = 1_000_000
	res.TokenUsage.OutputTokens = 1_000_000

	got := est.EstimateCents(res, "claude", provider.TierAPI)
	want := int64(1800) // 300 + 1500
	if got != want {
		t.Errorf("EstimateCents(claude:api, 1M in/out): want %d cents, got %d", want, got)
	}
}

// TestDefaultEstimator_CodexAPIRate verifies the codex:api rate:
// 200 input-cents/1M, 800 output-cents/1M.
func TestDefaultEstimator_CodexAPIRate(t *testing.T) {
	dir := t.TempDir()
	writeDefaultRates(t, dir)
	t.Setenv("TEKHTON_COST_RATES_FILE", filepath.Join(dir, "costrates.json"))

	est := provider.NewDefaultEstimator()
	res := &provider.Result{TierUsed: provider.TierAPI}
	res.TokenUsage.InputTokens = 1_000_000
	res.TokenUsage.OutputTokens = 1_000_000

	got := est.EstimateCents(res, "codex", provider.TierAPI)
	want := int64(1000) // 200 + 800
	if got != want {
		t.Errorf("EstimateCents(codex:api, 1M in/out): want %d cents, got %d", want, got)
	}
}

// TestDefaultEstimator_ZeroTokensIsZero verifies that api-tier with zero
// tokens produces zero cost (no work → no charge).
func TestDefaultEstimator_ZeroTokensIsZero(t *testing.T) {
	dir := t.TempDir()
	writeDefaultRates(t, dir)
	t.Setenv("TEKHTON_COST_RATES_FILE", filepath.Join(dir, "costrates.json"))

	est := provider.NewDefaultEstimator()
	res := &provider.Result{TierUsed: provider.TierAPI}
	// Zero tokens.
	res.TokenUsage.InputTokens = 0
	res.TokenUsage.OutputTokens = 0

	got := est.EstimateCents(res, "claude", provider.TierAPI)
	if got != 0 {
		t.Errorf("EstimateCents(api, 0 tokens): want 0, got %d", got)
	}
}

// TestDefaultEstimator_UnknownRateIsZero verifies that an unrecognized
// provider:tier key returns 0 (refuse-to-guess policy from the spec).
func TestDefaultEstimator_UnknownRateIsZero(t *testing.T) {
	dir := t.TempDir()
	writeDefaultRates(t, dir)
	t.Setenv("TEKHTON_COST_RATES_FILE", filepath.Join(dir, "costrates.json"))

	est := provider.NewDefaultEstimator()
	res := &provider.Result{TierUsed: provider.TierAPI}
	res.TokenUsage.InputTokens = 500_000
	res.TokenUsage.OutputTokens = 100_000

	// "future-provider" is not in costrates.json; should return 0.
	got := est.EstimateCents(res, "future-provider", provider.TierAPI)
	if got != 0 {
		t.Errorf("EstimateCents(unknown provider): want 0, got %d", got)
	}
}

// TestDefaultRatesFile_ParsesCleanly verifies that the embedded costrates.json
// parses successfully and contains the four required entries.
func TestDefaultRatesFile_ParsesCleanly(t *testing.T) {
	// Load costrates.json from the project root (relative to this test file).
	data, err := os.ReadFile(filepath.Join("costrates.json"))
	if err != nil {
		t.Fatalf("costrates.json not found: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("costrates.json is not valid JSON: %v", err)
	}
	required := []string{"claude:api", "codex:api", "codex:subscription", "claude:subscription"}
	for _, key := range required {
		if _, ok := raw[key]; !ok {
			t.Errorf("costrates.json missing required key %q", key)
		}
	}
}

// TestCostRatesEnvOverride verifies that TEKHTON_COST_RATES_FILE loads a
// custom rates file instead of the embedded default.
func TestCostRatesEnvOverride(t *testing.T) {
	dir := t.TempDir()
	custom := map[string]any{
		"claude:api": map[string]any{
			"input_cents_per_1m":  int64(100),
			"output_cents_per_1m": int64(200),
		},
	}
	data, err := json.Marshal(custom)
	if err != nil {
		t.Fatalf("marshal custom rates: %v", err)
	}
	ratesFile := filepath.Join(dir, "custom_rates.json")
	if err := os.WriteFile(ratesFile, data, 0o644); err != nil {
		t.Fatalf("write custom rates: %v", err)
	}
	t.Setenv("TEKHTON_COST_RATES_FILE", ratesFile)

	est := provider.NewDefaultEstimator()
	res := &provider.Result{TierUsed: provider.TierAPI}
	res.TokenUsage.InputTokens = 1_000_000
	res.TokenUsage.OutputTokens = 1_000_000

	got := est.EstimateCents(res, "claude", provider.TierAPI)
	want := int64(300) // 100 + 200 from custom file
	if got != want {
		t.Errorf("EstimateCents with custom rates: want %d, got %d", want, got)
	}
}

// TestCostEstimatorInterface verifies that DefaultEstimator implements the
// CostEstimator interface (compile-time check via assignment).
func TestCostEstimatorInterface(t *testing.T) {
	var _ provider.CostEstimator = provider.NewDefaultEstimator()
}

// writeDefaultRates writes the canonical test rate table to dir/costrates.json.
// Matches the rates specified in the m14 milestone design.
func writeDefaultRates(t *testing.T, dir string) {
	t.Helper()
	rates := map[string]any{
		"claude:api": map[string]any{
			"input_cents_per_1m":  int64(300),
			"output_cents_per_1m": int64(1500),
		},
		"codex:api": map[string]any{
			"input_cents_per_1m":  int64(200),
			"output_cents_per_1m": int64(800),
		},
		"codex:subscription": map[string]any{
			"input_cents_per_1m":  int64(0),
			"output_cents_per_1m": int64(0),
		},
		"claude:subscription": map[string]any{
			"input_cents_per_1m":  int64(0),
			"output_cents_per_1m": int64(0),
		},
	}
	data, err := json.Marshal(rates)
	if err != nil {
		t.Fatalf("marshal test rates: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "costrates.json"), data, 0o644); err != nil {
		t.Fatalf("write test rates: %v", err)
	}
}
