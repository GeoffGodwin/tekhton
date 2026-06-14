package supervisor

// m21 probe-gating tests: chain-membership gate and paid-tier degradation.
//
// Primary observable behavior: when claude is absent from the effective
// provider spec, NO claude invocation fires during a quota pause. When
// claude is present but its tier is "api" and QUOTA_PROBE_ALLOW_PAID is
// unset, the zero-turn and fallback probe layers are disabled (degraded
// to version-only, which is free). With QUOTA_PROBE_ALLOW_PAID=true the
// pre-m21 layered probe behavior is restored.
//
// These tests use the internal probe(ctx, kind, runner) seam to inject a
// recording runner so no network call is ever made. The gate logic lives
// in the public Probe() method per the m21 spec
// ("Applies to both the Go probe (internal/supervisor/quota_probe.go) and
// the bash legacy probe").

import (
	"context"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// recordingRunner records whether it was called and with which kind.
type recordingRunner struct {
	called bool
	kinds  []ProbeKind
	// result to return when called
	exitCode int
	stderr   string
	err      error
}

func (r *recordingRunner) run(_ context.Context, kind ProbeKind, _ string) (int, string, error) {
	r.called = true
	r.kinds = append(r.kinds, kind)
	return r.exitCode, r.stderr, r.err
}

// ---------------------------------------------------------------------------
// Goal 1a — chain-membership gate: claude absent from PROVIDER spec
// ---------------------------------------------------------------------------

// TestProbe_ChainMembershipGate_RunnerNotCalledWhenClaudeAbsent asserts that
// when the effective PROVIDER spec does not contain "claude", the probe runner
// is never invoked — acceptance criterion 1 of m21.
func TestProbe_ChainMembershipGate_RunnerNotCalledWhenClaudeAbsent(t *testing.T) {
	t.Setenv("PROVIDER", "codex") // no claude in spec
	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeVersion, rec.run)

	if rec.called {
		t.Error("probe runner was called even though claude is absent from PROVIDER spec")
	}
}

// TestProbe_ChainMembershipGate_LocalProviderNotCalled asserts the same gate
// with a local-provider-only spec (qwen-local — no claude either).
func TestProbe_ChainMembershipGate_LocalProviderNotCalled(t *testing.T) {
	t.Setenv("PROVIDER", "qwen-local")
	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeVersion, rec.run)

	if rec.called {
		t.Error("probe runner was called for qwen-local-only spec")
	}
}

// TestProbe_ChainMembershipGate_RunnerCalledWhenClaudePresent asserts that
// when claude IS in the spec the gate does not fire and the runner is called —
// the happy path that must remain working.
func TestProbe_ChainMembershipGate_RunnerCalledWhenClaudePresent(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeVersion, rec.run)

	if !rec.called {
		t.Error("probe runner was NOT called even though claude is in PROVIDER spec")
	}
}

// TestProbe_ChainMembershipGate_ClaudeInMultiProviderSpec asserts that
// "codex,claude" triggers the runner (claude is present in a multi-provider
// spec).
func TestProbe_ChainMembershipGate_ClaudeInMultiProviderSpec(t *testing.T) {
	t.Setenv("PROVIDER", "codex,claude")
	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeVersion, rec.run)

	if !rec.called {
		t.Error("probe runner was NOT called even though claude is in multi-provider spec")
	}
}

// TestProbe_ChainMembershipGate_DefaultSpecIncludesClaude asserts that the
// default spec ("codex,claude" when PROVIDER is unset) keeps the runner active.
func TestProbe_ChainMembershipGate_DefaultSpecIncludesClaude(t *testing.T) {
	t.Setenv("PROVIDER", "") // unset → default "codex,claude"
	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeVersion, rec.run)

	if !rec.called {
		t.Error("probe runner was NOT called for default spec (should include claude)")
	}
}

// ---------------------------------------------------------------------------
// Goal 1b — paid-tier gate: claude in spec but tier == api
// ---------------------------------------------------------------------------

// TestProbe_PaidTier_ZeroTurnSkippedWithoutAllowPaid asserts that when
// TEKHTON_CLAUDE_TIER=api and QUOTA_PROBE_ALLOW_PAID is unset, the
// ProbeZeroTurn kind does not reach the runner — acceptance criterion 2.
func TestProbe_PaidTier_ZeroTurnSkippedWithoutAllowPaid(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	t.Setenv("TEKHTON_CLAUDE_TIER", "api")
	// QUOTA_PROBE_ALLOW_PAID intentionally not set

	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeZeroTurn, rec.run)

	if rec.called {
		t.Error("zero-turn probe runner was called with api tier and QUOTA_PROBE_ALLOW_PAID unset")
	}
}

// TestProbe_PaidTier_FallbackSkippedWithoutAllowPaid asserts that the
// ProbeFallback (which burns real API quota) does not run when
// TEKHTON_CLAUDE_TIER=api and QUOTA_PROBE_ALLOW_PAID is unset.
func TestProbe_PaidTier_FallbackSkippedWithoutAllowPaid(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	t.Setenv("TEKHTON_CLAUDE_TIER", "api")
	// QUOTA_PROBE_ALLOW_PAID not set

	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeFallback, rec.run)

	if rec.called {
		t.Error("fallback probe runner was called with api tier and QUOTA_PROBE_ALLOW_PAID unset")
	}
}

// TestProbe_PaidTier_VersionProbeAllowedWithoutAllowPaid asserts that the
// free ProbeVersion layer may still run even when TEKHTON_CLAUDE_TIER=api and
// QUOTA_PROBE_ALLOW_PAID is unset — only the costly kinds are blocked.
// Acceptance criterion 2 says "The free `claude --version` liveness layer
// may still run."
func TestProbe_PaidTier_VersionProbeAllowedWithoutAllowPaid(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	t.Setenv("TEKHTON_CLAUDE_TIER", "api")
	// QUOTA_PROBE_ALLOW_PAID not set

	sup, _, _ := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeVersion, rec.run)

	if !rec.called {
		t.Error("version probe runner was NOT called; version probe should remain active even at api tier")
	}
}

// TestProbe_PaidTier_AllProbesRunWithAllowPaid asserts that with
// QUOTA_PROBE_ALLOW_PAID=true the pre-m21 layered probe behavior is
// fully restored — acceptance criterion 3.
func TestProbe_PaidTier_AllProbesRunWithAllowPaid(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	t.Setenv("TEKHTON_CLAUDE_TIER", "api")
	t.Setenv("QUOTA_PROBE_ALLOW_PAID", "true")

	for _, kind := range []ProbeKind{ProbeVersion, ProbeZeroTurn, ProbeFallback} {
		t.Run(kind.String(), func(t *testing.T) {
			sup, _, _ := newSupForTest(t)
			rec := &recordingRunner{exitCode: 0}

			sup.probe(context.Background(), kind, rec.run)

			if !rec.called {
				t.Errorf("probe kind %s was NOT called with QUOTA_PROBE_ALLOW_PAID=true", kind)
			}
		})
	}
}

// TestProbe_PaidTier_SubscriptionTierAllProbesRun asserts that when claude's
// tier is subscription (not api), ALL probe kinds run regardless of
// QUOTA_PROBE_ALLOW_PAID — the gate only activates for the api tier.
func TestProbe_PaidTier_SubscriptionTierAllProbesRun(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	t.Setenv("TEKHTON_CLAUDE_TIER", "subscription")
	// QUOTA_PROBE_ALLOW_PAID not set (would block api tier, but not subscription)

	for _, kind := range []ProbeKind{ProbeVersion, ProbeZeroTurn, ProbeFallback} {
		t.Run(kind.String(), func(t *testing.T) {
			sup, _, _ := newSupForTest(t)
			rec := &recordingRunner{exitCode: 0}

			sup.probe(context.Background(), kind, rec.run)

			if !rec.called {
				t.Errorf("kind %s was NOT called at subscription tier — gate should only block api", kind)
			}
		})
	}
}

// TestProbe_PaidTier_DegradedModeLogsWarning asserts that when the paid-tier
// gate degrades the probe mode, a log line is emitted to the causal log
// describing the degraded state — "Log one line explaining the degraded probe
// mode" per m21 design. The test also verifies the runner was NOT called,
// confirming the probe was actually skipped (not just annotated).
func TestProbe_PaidTier_DegradedModeLogsWarning(t *testing.T) {
	t.Setenv("PROVIDER", "claude")
	t.Setenv("TEKHTON_CLAUDE_TIER", "api")
	// QUOTA_PROBE_ALLOW_PAID not set → degraded mode; ZeroTurn must be skipped

	sup, _, logPath := newSupForTest(t)
	rec := &recordingRunner{exitCode: 0}

	sup.probe(context.Background(), ProbeZeroTurn, rec.run)

	// The probe runner must NOT have been called (it was degraded/skipped).
	if rec.called {
		t.Error("probe runner was called in degraded mode (expected skip, got invocation)")
	}

	// The causal log must contain a degraded-mode indicator — either the
	// word "degraded" or a reference to QUOTA_PROBE_ALLOW_PAID.
	body := readQuotaLog(t, logPath)
	if !strings.Contains(body, "degraded") && !strings.Contains(body, "QUOTA_PROBE_ALLOW_PAID") {
		t.Errorf("causal log missing degraded-mode indicator; got:\n%s", body)
	}
}
