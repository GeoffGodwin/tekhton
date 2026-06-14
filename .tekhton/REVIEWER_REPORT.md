## Test Audit Report

### Audit Summary
Tests audited: 2 files, 26 test functions (10 cutoverWarnApplies unit tests,
7 ProviderCutoverCheck.Run() integration tests, 9 bash structural assertions in
tests/test_no_claude_e2e_structure.sh)
Verdict: CONCERNS

### Findings

#### INTEGRITY: Syntax check condition can produce a false PASS without verifying syntax
- File: tests/test_no_claude_e2e_structure.sh:37
- Issue: The guard `if [[ -x "$E2E_SCRIPT" ]] || bash -n "$E2E_SCRIPT" 2>/dev/null`
  short-circuits on the executable bit. When the script file is executable the `bash -n`
  branch is never evaluated, and the test emits `pass "e2e script has valid bash syntax"`
  without having verified any syntax. An executable script with bash parse errors would
  produce a false PASS on this assertion.
- Severity: HIGH
- Action: Replace the condition with `bash -n "$E2E_SCRIPT" 2>/dev/null` alone. The
  executable bit tells us nothing about syntax validity; `bash -n` is the correct tool.

#### INTEGRITY: Test name overpromises what its assertion verifies
- File: internal/preflight/provider_cutover_test.go:228-234
- Issue: `TestProviderCutover_WarnMentionsEnvKeys` asserts only `f.Detail == ""` (Detail
  is non-empty). The name says the WARN block must "mention suppression env keys" but any
  single-character Detail satisfies the check. When Run() is eventually implemented, a
  Detail of "billing exposure detected" would pass this test even though neither
  PROVIDER_ALLOW_PAID_FALLBACK nor TEKHTON_CLAUDE_PRE_JUNE_15 appears — the operator
  would have no guidance on how to resolve the warning.
- Severity: MEDIUM
- Action: Strengthen the assertion. Both suppression knobs are named in provider_cutover.go
  comments (lines 15-17). Assert `strings.Contains(f.Detail, "PROVIDER_ALLOW_PAID_FALLBACK")
  || strings.Contains(f.Detail, "TEKHTON_CLAUDE_PRE_JUNE_15")` to match the stated intent.

#### COVERAGE: "Silent" integration tests are vacuously true against a no-op stub
- File: internal/preflight/provider_cutover_test.go:167-213
- Issue: TestProviderCutover_NoClaudeInSpec_Silent, _AllowPaidFallback_Silent,
  _PreJune15Override_Silent, and _SubscriptionTier_Silent all assert `len(got) == 0`.
  Because Run() currently returns Result{} unconditionally, these four tests pass regardless
  of whether the suppression logic is correct. An implementation that emits a WARN for
  every input would still pass them. They provide no discriminating coverage until the
  WARN-path tests (currently FAIL) are also green.
- Severity: MEDIUM
- Action: Acceptable as intentional scaffold — the TESTER_REPORT.md documents this
  correctly as a known limitation. When Run() is implemented, run the full suite immediately
  so the silent tests acquire discriminating power alongside the WARN-path tests.

#### SCOPE: ProviderCutoverCheck is absent from checkOrder; no test guards the registration
- File: internal/preflight/provider_cutover_test.go (all integration tests)
- Issue: orchestrator.go:141 lists checkOrder as [foundation, ui_audit, env, claude_env,
  test_cmd, services_infer, services]. ProviderCutoverCheck is not registered. The source
  file (provider_cutover.go:27-28) says it "Must be added to checkOrder in orchestrator.go
  before the check executes in production runs." The integration tests call
  ProviderCutoverCheck{}.Run() directly and bypass the orchestrator, so they will pass even
  if the check is never wired in and therefore never fires in production.
- Severity: MEDIUM
- Action: When implementing Run() for m23 Goal 2, add "provider_cutover" to checkOrder
  and its factory to goNativeChecks. Extend orchestrator_test.go's order-mismatch guard
  to assert the new entry is present, using the same pattern as the existing seven checks.

#### ISOLATION: One helper test exposes ambient os.Getenv fallback for unset key
- File: internal/preflight/provider_cutover_test.go:74-82
- Issue: TestCutoverWarnApplies_NoTierSet_False sets only PROVIDER in Env and omits
  TEKHTON_CLAUDE_TIER. GetenvDefault checks in.Env first (miss), then falls back to
  os.Getenv("TEKHTON_CLAUDE_TIER"). If TEKHTON_CLAUDE_TIER=api is present in the CI
  environment the function returns true and the test fails unexpectedly. This is consistent
  with the broader Input design (all preflight checks share this fallback pattern), so it
  is a systemic low-risk concern rather than a test-specific error.
- Severity: LOW
- Action: No change required for normal CI environments. If a future environment sets
  TEKHTON_CLAUDE_TIER, fix by adding `"TEKHTON_CLAUDE_TIER": ""` explicitly to the Env
  map to shadow the ambient value.
