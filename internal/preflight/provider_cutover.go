package preflight

import (
	"context"
	"strings"
)

// ProviderCutoverCheck warns when the active provider spec includes claude
// at the api (metered) tier without an explicit paid-tier opt-in override.
// It fires pre-run so operators learn about billing exposure before the
// first stage dispatches, not mid-milestone.
//
// Acceptance criteria (m23 Goal 2):
//   - One WARN block listing all affected stages (not one per stage).
//   - Suppressed when PROVIDER=codex (or any spec without claude).
//   - Suppressed when PROVIDER_ALLOW_PAID_FALLBACK=true.
//   - Suppressed when TEKHTON_CLAUDE_PRE_JUNE_15=true (explicit pre-cutover opt-out).
//   - Severity warn; PREFLIGHT_FAIL_ON_WARN=true escalates to blocking.
//
// NOTE: This file is a scaffold stub. Run() is not yet implemented.
// Tests in provider_cutover_test.go document expected behaviour and
// currently FAIL — see BUG entries in .tekhton/TESTER_REPORT.md.
type ProviderCutoverCheck struct{}

// Name returns the canonical check name. Must be added to checkOrder in
// orchestrator.go before the check executes in production runs.
func (ProviderCutoverCheck) Name() string { return "provider_cutover" }

// Run examines the resolved provider spec for billing-tier exposure.
// TODO: implement m23 Goal 2.
func (ProviderCutoverCheck) Run(_ context.Context, in *Input) Result {
	_ = in // suppress unused-var lint until implementation lands
	return Result{}
}

// cutoverWarnApplies returns true when the provider spec and tier combination
// requires a billing-exposure warning. Extracted for unit-testability.
//
// Conditions:
//   - spec includes "claude"
//   - TEKHTON_CLAUDE_TIER == "api" (metered, not subscription or local)
//   - PROVIDER_ALLOW_PAID_FALLBACK != "true"
//   - TEKHTON_CLAUDE_PRE_JUNE_15 != "true"
func cutoverWarnApplies(in *Input) bool {
	if !providerSpecIncludesClaude(in.GetenvDefault("PROVIDER", "codex,claude")) {
		return false
	}
	if !strings.EqualFold(in.GetenvDefault("TEKHTON_CLAUDE_TIER", ""), "api") {
		return false
	}
	if in.GetenvDefault("PROVIDER_ALLOW_PAID_FALLBACK", "false") == "true" {
		return false
	}
	if in.GetenvDefault("TEKHTON_CLAUDE_PRE_JUNE_15", "false") == "true" {
		return false
	}
	return true
}
