## Planned Tests
- [x] `internal/supervisor/quota_probe_test.go` — m21 probe gating: chain-membership gate and paid-tier degradation
- [x] `internal/runner/provider_chain_test.go` — m21 paid-fallback gate: block/allow tests + update existing fallthrough tests
- [x] `internal/preflight/claude_env_test.go` — m21 skip-when-claude-not-in-spec for version check
- [x] `tests/test_quota_probe_gating.sh` — bash probe gating under PATH-shim claude

## Test Run Results
Passed: 20  Failed: 13

### internal/supervisor/quota_probe_test.go (new file)
- PASS: TestProbe_ChainMembershipGate_RunnerCalledWhenClaudePresent
- PASS: TestProbe_ChainMembershipGate_ClaudeInMultiProviderSpec
- PASS: TestProbe_ChainMembershipGate_DefaultSpecIncludesClaude
- PASS: TestProbe_PaidTier_VersionProbeAllowedWithoutAllowPaid
- PASS: TestProbe_PaidTier_AllProbesRunWithAllowPaid/ProbeVersion
- PASS: TestProbe_PaidTier_AllProbesRunWithAllowPaid/ProbeZeroTurn
- PASS: TestProbe_PaidTier_AllProbesRunWithAllowPaid/ProbeFallback
- PASS: TestProbe_PaidTier_SubscriptionTierAllProbesRun/ProbeVersion
- PASS: TestProbe_PaidTier_SubscriptionTierAllProbesRun/ProbeZeroTurn
- PASS: TestProbe_PaidTier_SubscriptionTierAllProbesRun/ProbeFallback
- FAIL: TestProbe_ChainMembershipGate_RunnerNotCalledWhenClaudeAbsent — gate not implemented
- FAIL: TestProbe_ChainMembershipGate_LocalProviderNotCalled — gate not implemented
- FAIL: TestProbe_PaidTier_ZeroTurnSkippedWithoutAllowPaid — gate not implemented
- FAIL: TestProbe_PaidTier_FallbackSkippedWithoutAllowPaid — gate not implemented
- FAIL: TestProbe_PaidTier_DegradedModeLogsWarning — gate not implemented; log missing "degraded"/"QUOTA_PROBE_ALLOW_PAID" entry

### internal/runner/provider_chain_test.go (modified)
- PASS: TestChain_RunAgent_FallsThrough (updated: PROVIDER_ALLOW_PAID_FALLBACK=true to preserve pre-m21 intent)
- PASS: TestChain_RunAgent_AllExhausted (updated: same)
- PASS: TestChain_RunAgent_PaidFallbackAllowed_ExplicitFlag
- PASS: TestChain_RunAgent_PaidFallbackGate_SameTierNotBlocked
- PASS: TestChain_RunAgent_PaidFallbackGate_ApiToApiNotBlocked
- FAIL: TestChain_RunAgent_PaidFallbackBlocked_DefaultBehavior — gate not implemented; claude called without PROVIDER_ALLOW_PAID_FALLBACK
- FAIL: TestChain_RunAgent_PaidFallbackBlocked_ErrorNamesEnvKey — gate not implemented; ErrorMessage is empty

### internal/preflight/claude_env_test.go (modified)
- PASS: TestClaudeEnv_RunsVersionCheckWhenClaudeInProviderSpec
- FAIL: TestClaudeEnv_SkipsVersionCheckWhenClaudeNotInProviderSpec — gate not implemented; returns StatusPass instead of StatusSkip
- FAIL: TestClaudeEnv_SkipsVersionCheckWhenLocalProviderOnly — gate not implemented; returns StatusPass instead of StatusSkip

### tests/test_quota_probe_gating.sh (new file)
- PASS: shim infrastructure self-check (direct call)
- PASS: shim infrastructure self-check (via PATH)
- PASS: baseline check: claude IS called when PROVIDER=claude
- PASS: paid-tier gate: version probe IS called at api tier (free probe stays active)
- PASS: QUOTA_PROBE_ALLOW_PAID=true: zero-turn probe IS called at api tier
- PASS: QUOTA_PROBE_ALLOW_PAID=true: fallback probe IS called at api tier
- PASS: subscription tier: zero-turn probe IS called (gate only fires at api tier)
- FAIL: chain-membership gate: claude not called when PROVIDER=codex — gate not implemented
- FAIL: chain-membership gate: no probe when PROVIDER=codex,qwen-local — gate not implemented
- FAIL: paid-tier gate: zero-turn probe not called when tier=api and QUOTA_PROBE_ALLOW_PAID unset — gate not implemented
- FAIL: paid-tier gate: fallback probe not called when tier=api and QUOTA_PROBE_ALLOW_PAID unset — gate not implemented

## Bugs Found

**BUG-m21-1**: `internal/supervisor/quota_probe.go` — `probe()` ignores PROVIDER spec; calls runner unconditionally even when claude is absent from the provider chain (e.g. PROVIDER=codex or PROVIDER=qwen-local). Acceptance criterion 1 of m21 requires the function return early without invoking the runner in this case.

**BUG-m21-2**: `internal/supervisor/quota_probe.go` — `probe()` ignores TEKHTON_CLAUDE_TIER and QUOTA_PROBE_ALLOW_PAID; zero-turn and fallback probe kinds run unconditionally at api tier. Acceptance criterion 2 of m21 requires ProbeZeroTurn and ProbeFallback to be skipped when tier==api and QUOTA_PROBE_ALLOW_PAID is not "true". Only ProbeVersion (zero-cost) may run in degraded mode.

**BUG-m21-3**: `internal/supervisor/quota_probe.go` — degraded-mode skip produces no log event. Acceptance criterion 2 requires "Log one line explaining the degraded probe mode." The causal log contains only the normal quota_probe event for the skipped attempt; nothing containing "degraded" or "QUOTA_PROBE_ALLOW_PAID" is emitted.

**BUG-m21-4**: `internal/runner/provider_chain.go` — `RunAgent()` ignores PROVIDER_ALLOW_PAID_FALLBACK; always falls through to higher-cost providers on OutcomeUpstreamError without checking the flag. Acceptance criterion 3 of m21 requires that chain fallthrough from a lower-tier to a TierAPI provider be blocked unless PROVIDER_ALLOW_PAID_FALLBACK=true.

**BUG-m21-5**: `internal/preflight/claude_env.go:92` — `checkClaudeVersion()` ignores PROVIDER spec; runs `claude --version` whenever the binary is discoverable on PATH, even when claude is absent from all stage specs (e.g. PROVIDER=codex, PROVIDER=qwen-local). Acceptance criterion 8 of m21 requires a StatusSkip finding instead of a version check in this case.

**BUG-m21-6**: `internal/config/defaults.go` — QUOTA_PROBE_ALLOW_PAID and PROVIDER_ALLOW_PAID_FALLBACK default entries are missing. Both new m21 config keys must be registered with default values (false) in the defaults table so they are exported in the bash env contract.

## Files Modified
- [x] `internal/supervisor/quota_probe_test.go` — new file, 252 lines
- [x] `internal/runner/provider_chain_test.go` — added 5 new tests, updated 2 existing tests
- [x] `internal/preflight/claude_env_test.go` — added 3 new tests
- [x] `tests/test_quota_probe_gating.sh` — new file, 313 lines
