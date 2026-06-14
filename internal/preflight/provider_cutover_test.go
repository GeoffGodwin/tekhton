package preflight

import (
	"context"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// cutoverWarnApplies — helper that drives the gate logic independently of the
// not-yet-implemented Run() body. Tests here verify the condition matrix so
// bugs in the predicate are caught before the full Run() integration.
// ---------------------------------------------------------------------------

func TestCutoverWarnApplies_NoClaudeInSpec_False(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":            "codex",
		"TEKHTON_CLAUDE_TIER": "api",
	}}
	if cutoverWarnApplies(in) {
		t.Error("warn should not apply when claude is absent from spec")
	}
}

func TestCutoverWarnApplies_LocalProviderOnly_False(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":            "qwen-local",
		"TEKHTON_CLAUDE_TIER": "api",
	}}
	if cutoverWarnApplies(in) {
		t.Error("warn should not apply for local-only spec")
	}
}

func TestCutoverWarnApplies_ClaudeInSpec_ApiTier_True(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":            "claude",
		"TEKHTON_CLAUDE_TIER": "api",
	}}
	if !cutoverWarnApplies(in) {
		t.Error("warn should apply when claude is in spec at api tier")
	}
}

func TestCutoverWarnApplies_ClaudeInChain_ApiTier_True(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":            "codex,claude",
		"TEKHTON_CLAUDE_TIER": "api",
	}}
	if !cutoverWarnApplies(in) {
		t.Error("warn should apply when claude appears in a mixed-chain spec at api tier")
	}
}

func TestCutoverWarnApplies_SubscriptionTier_False(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":            "claude",
		"TEKHTON_CLAUDE_TIER": "subscription",
	}}
	if cutoverWarnApplies(in) {
		t.Error("warn should not apply when tier is subscription (not metered)")
	}
}

func TestCutoverWarnApplies_LocalTier_False(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":            "claude",
		"TEKHTON_CLAUDE_TIER": "local",
	}}
	if cutoverWarnApplies(in) {
		t.Error("warn should not apply when tier is local")
	}
}

func TestCutoverWarnApplies_NoTierSet_False(t *testing.T) {
	// When TEKHTON_CLAUDE_TIER is unset, tier is unknown — don't warn
	// (the check needs explicit evidence of api-tier billing to warn).
	in := &Input{Env: map[string]string{
		"PROVIDER": "claude",
	}}
	if cutoverWarnApplies(in) {
		t.Error("warn should not apply when TEKHTON_CLAUDE_TIER is unset (tier unknown)")
	}
}

func TestCutoverWarnApplies_AllowPaidFallback_False(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":                     "claude",
		"TEKHTON_CLAUDE_TIER":          "api",
		"PROVIDER_ALLOW_PAID_FALLBACK": "true",
	}}
	if cutoverWarnApplies(in) {
		t.Error("warn should not apply when PROVIDER_ALLOW_PAID_FALLBACK=true")
	}
}

func TestCutoverWarnApplies_PreJune15Override_False(t *testing.T) {
	in := &Input{Env: map[string]string{
		"PROVIDER":                   "claude",
		"TEKHTON_CLAUDE_TIER":        "api",
		"TEKHTON_CLAUDE_PRE_JUNE_15": "true",
	}}
	if cutoverWarnApplies(in) {
		t.Error("warn should not apply when TEKHTON_CLAUDE_PRE_JUNE_15=true")
	}
}

func TestCutoverWarnApplies_TierApiCaseInsensitive(t *testing.T) {
	for _, tier := range []string{"API", "Api", "aPi"} {
		in := &Input{Env: map[string]string{
			"PROVIDER":            "claude",
			"TEKHTON_CLAUDE_TIER": tier,
		}}
		if !cutoverWarnApplies(in) {
			t.Errorf("warn should apply for tier %q (case-insensitive api match)", tier)
		}
	}
}

// ---------------------------------------------------------------------------
// ProviderCutoverCheck.Run() — integration tests against the actual Check.
// These tests fail until the Run() body is implemented (m23 Goal 2 scaffold).
// ---------------------------------------------------------------------------

func runProviderCutover(t *testing.T, env map[string]string) []Finding {
	t.Helper()
	in := &Input{Env: env}
	return ProviderCutoverCheck{}.Run(context.Background(), in).Findings
}

// TestProviderCutover_ClaudeApiTier_EmitsWarn is the primary happy-path test:
// when the operator has claude in the spec at api tier with no override, they
// must see exactly one WARN block before the first stage dispatches.
func TestProviderCutover_ClaudeApiTier_EmitsWarn(t *testing.T) {
	got := runProviderCutover(t, map[string]string{
		"PROVIDER":            "claude",
		"TEKHTON_CLAUDE_TIER": "api",
	})
	if len(got) == 0 {
		t.Fatal("expected one WARN finding when claude is at api tier; got none")
	}
	// Exactly one block — not one per stage.
	warnCount := 0
	for _, f := range got {
		if f.Status == StatusWarn {
			warnCount++
		}
	}
	if warnCount != 1 {
		t.Errorf("expected exactly 1 WARN finding; got %d (findings: %+v)", warnCount, got)
	}
}

// TestProviderCutover_ClaudeInChain_ApiTier_EmitsWarn — claude as fallback
// in a mixed chain must also trigger the warning.
func TestProviderCutover_ClaudeInChain_ApiTier_EmitsWarn(t *testing.T) {
	got := runProviderCutover(t, map[string]string{
		"PROVIDER":            "codex,claude",
		"TEKHTON_CLAUDE_TIER": "api",
	})
	if len(got) == 0 {
		t.Fatal("expected WARN for codex,claude chain at api tier; got none")
	}
}

// TestProviderCutover_NoClaudeInSpec_Silent confirms the check does not emit
// any finding when claude is absent from the spec.
func TestProviderCutover_NoClaudeInSpec_Silent(t *testing.T) {
	got := runProviderCutover(t, map[string]string{
		"PROVIDER":            "codex",
		"TEKHTON_CLAUDE_TIER": "api",
	})
	if len(got) != 0 {
		t.Errorf("expected no findings for codex-only spec; got %+v", got)
	}
}

// TestProviderCutover_AllowPaidFallback_Silent confirms PROVIDER_ALLOW_PAID_FALLBACK
// suppresses the warning (explicit operator opt-in to billing).
func TestProviderCutover_AllowPaidFallback_Silent(t *testing.T) {
	got := runProviderCutover(t, map[string]string{
		"PROVIDER":                     "claude",
		"TEKHTON_CLAUDE_TIER":          "api",
		"PROVIDER_ALLOW_PAID_FALLBACK": "true",
	})
	if len(got) != 0 {
		t.Errorf("expected no findings with PROVIDER_ALLOW_PAID_FALLBACK=true; got %+v", got)
	}
}

// TestProviderCutover_PreJune15Override_Silent confirms the opt-out flag
// silences the warning for projects that haven't finished the cutover.
func TestProviderCutover_PreJune15Override_Silent(t *testing.T) {
	got := runProviderCutover(t, map[string]string{
		"PROVIDER":                   "claude",
		"TEKHTON_CLAUDE_TIER":        "api",
		"TEKHTON_CLAUDE_PRE_JUNE_15": "true",
	})
	if len(got) != 0 {
		t.Errorf("expected no findings with TEKHTON_CLAUDE_PRE_JUNE_15=true; got %+v", got)
	}
}

// TestProviderCutover_SubscriptionTier_Silent confirms subscription-tier
// projects (Codex Pro, ChatGPT Plus) are not warned about billing.
func TestProviderCutover_SubscriptionTier_Silent(t *testing.T) {
	got := runProviderCutover(t, map[string]string{
		"PROVIDER":            "claude",
		"TEKHTON_CLAUDE_TIER": "subscription",
	})
	if len(got) != 0 {
		t.Errorf("expected no findings at subscription tier; got %+v", got)
	}
}

// TestProviderCutover_WarnMentionsEnvKeys ensures the WARN block names the
// suppression knobs so operators know what to set.
func TestProviderCutover_WarnMentionsEnvKeys(t *testing.T) {
	got := runProviderCutover(t, map[string]string{
		"PROVIDER":            "claude",
		"TEKHTON_CLAUDE_TIER": "api",
	})
	if len(got) == 0 {
		t.Fatal("expected WARN finding; got none")
	}
	var warnSeen bool
	for _, f := range got {
		if f.Status != StatusWarn {
			continue
		}
		warnSeen = true
		// The detail must NAME the suppression keys so the operator knows how
		// to resolve the warning — not merely be non-empty.
		if !strings.Contains(f.Detail, "PROVIDER_ALLOW_PAID_FALLBACK") {
			t.Errorf("WARN Detail must name PROVIDER_ALLOW_PAID_FALLBACK; got: %q", f.Detail)
		}
		if !strings.Contains(f.Detail, "TEKHTON_CLAUDE_PRE_JUNE_15") {
			t.Errorf("WARN Detail must name TEKHTON_CLAUDE_PRE_JUNE_15; got: %q", f.Detail)
		}
	}
	if !warnSeen {
		t.Error("expected a StatusWarn finding")
	}
}
