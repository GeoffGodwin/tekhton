## Test Audit Report

### Audit Summary
Tests audited: 4 files, 33 test functions (20 Go, 7 bash test cases + 2 shim self-checks)
Verdict: PASS

---

### Context
All 13 failing tests are intentional TDD red-phase tests. The tester report explicitly names each failing test and maps it to an unimplemented gate (BUG-m21-1 through BUG-m21-6). The auditor's role is to verify the tests are honest, well-isolated, and will correctly validate the implementation once it lands — not to treat "currently failing" as an integrity problem.

---

### Findings

#### COVERAGE: Vacuous positive tests for the chain-membership gate (quota_probe_test.go)
- File: internal/supervisor/quota_probe_test.go:80–119
- Issue: `TestProbe_ChainMembershipGate_RunnerCalledWhenClaudePresent`, `ClaudeInMultiProviderSpec`, and `DefaultSpecIncludesClaude` all assert `rec.called == true`. These pass now because `probe()` calls the runner unconditionally (no gate exists). They provide zero discriminating signal until the gate is implemented. They will provide correct positive-path signal after the gate lands.
- Severity: LOW
- Action: No change needed. Document in the milestone implementation note that positive-path tests will provide real coverage once the PROVIDER gate is added to `probe()` in `quota_probe.go`.

#### COVERAGE: Vacuous positive tests in provider_chain_test.go
- File: internal/runner/provider_chain_test.go:345–403
- Issue: `TestChain_RunAgent_PaidFallbackAllowed_ExplicitFlag`, `PaidFallbackGate_SameTierNotBlocked`, and `PaidFallbackGate_ApiToApiNotBlocked` pass because the paid-fallback gate isn't in `RunAgent()` — not because the gate correctly allows them. Same TDD-cycle concern as above.
- Severity: LOW
- Action: No change needed. All three tests are correctly designed to continue passing after the gate is added to `provider_chain.go`.

#### COVERAGE: `TestChain_RunAgent_PaidFallbackGate_ApiToApiNotBlocked` omits TierUsed assertion
- File: internal/runner/provider_chain_test.go:389–403
- Issue: The test verifies `Outcome == Success` but doesn't assert `res.TierUsed == provider.TierAPI`. After the gate lands, a mis-stamped `TierUsed` field would go undetected by this test.
- Severity: LOW
- Action: Add `if res.TierUsed != provider.TierAPI { t.Errorf(...) }` after the Outcome check to close the gap.

#### COVERAGE: Bash test missing positive multi-provider case
- File: tests/test_quota_probe_gating.sh (structural gap — no specific line)
- Issue: The bash test covers `PROVIDER=codex` (gate fires) and `PROVIDER=claude` (gate doesn't fire), but has no case for `PROVIDER=codex,claude` or `PROVIDER=claude,codex` (multi-provider spec that includes claude). The Go side covers this in `TestProbe_ChainMembershipGate_ClaudeInMultiProviderSpec`. The bash side has a gap.
- Severity: LOW
- Action: Add a second assertion inside Test A after the baseline check: set `PROVIDER="codex,claude"`, run `_quota_probe`, assert CLAUDE_LOG is non-empty.

---

### Positive findings (no issues)

**Seam design is correct** (`quota_probe_test.go`): The `recordingRunner` / `probeRunner` injection matches the documented test seam at `quota_probe.go:89–91`. No real network calls are made.

**Helper functions exist and are in scope**: `newSupForTest` and `readQuotaLog` are defined in `quota_test.go` (same package, automatically included in the test binary). `StatusSkip` is defined in `orchestrator.go:50`. All references resolve.

**`TestProbe_PaidTier_DegradedModeLogsWarning` is well-designed** (line 230): Asserts both that the runner was NOT called AND that the causal log contains "degraded" or "QUOTA_PROBE_ALLOW_PAID". The current implementation emits neither — the test fails for the right reasons and will catch the real log emission once the gate lands.

**Existing test modifications are not weakenings**: `TestChain_RunAgent_FallsThrough` and `TestChain_RunAgent_AllExhausted` were updated to add `t.Setenv("PROVIDER_ALLOW_PAID_FALLBACK", "true")`. These tests were already testing sub→api fallthrough; the env var is correct pre-emptive accommodation of the m21 gate default. Test intent is fully preserved.

**preflight test isolation is correct**: All `claude_env_test.go` tests use `t.TempDir()`. `Input.Getenv` reads from the injected `Env` map before falling back to `os.Getenv` (orchestrator.go:107–114), so PROVIDER and TEKHTON_CLAUDE_BIN are injectable without process-level env mutation. No real claude binary on PATH is required.

**Bash test isolation is correct**: `TMPDIR=$(mktemp -d)` with `trap 'rm -rf "$TMPDIR"' EXIT`, per-test SHIM_DIR creation, `reset_probe_state` (zeroing `_QUOTA_PROBE_MODE`, `_QUOTA_PROBE_LAST_TS`, and CLAUDE_LOG), and PATH restoration after each section provide correct isolation between cases.

**No mutable project files read by any test**: No test reads live `pipeline.conf`, run artifacts, causal logs, or build reports from the project tree. All file assertions go through temp directories.
