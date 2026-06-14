## Planned Tests
- [x] `internal/preflight/provider_cutover_test.go` — rule matrix: claude-in-spec × tier × override keys (PROVIDER_ALLOW_PAID_FALLBACK, TEKHTON_CLAUDE_PRE_JUNE_15)
- [x] `tests/test_no_claude_e2e_structure.sh` — structural: e2e self-skip, fixture integrity (pipeline.conf, MANIFEST.cfg, milestone, scripts/audit-raw-claude.sh)

## Test Run Results
Passed: 34  Failed: 5

### internal/preflight/provider_cutover_test.go (new file)

#### cutoverWarnApplies predicate (helper, all PASS)
- PASS: TestCutoverWarnApplies_NoClaudeInSpec_False
- PASS: TestCutoverWarnApplies_LocalProviderOnly_False
- PASS: TestCutoverWarnApplies_ClaudeInSpec_ApiTier_True
- PASS: TestCutoverWarnApplies_ClaudeInChain_ApiTier_True
- PASS: TestCutoverWarnApplies_SubscriptionTier_False
- PASS: TestCutoverWarnApplies_LocalTier_False
- PASS: TestCutoverWarnApplies_NoTierSet_False
- PASS: TestCutoverWarnApplies_AllowPaidFallback_False
- PASS: TestCutoverWarnApplies_PreJune15Override_False
- PASS: TestCutoverWarnApplies_TierApiCaseInsensitive

#### ProviderCutoverCheck.Run() integration (stub not implemented)
- FAIL: TestProviderCutover_ClaudeApiTier_EmitsWarn — stub Run() returns empty; expected WARN
- FAIL: TestProviderCutover_ClaudeInChain_ApiTier_EmitsWarn — stub Run() returns empty; expected WARN
- PASS: TestProviderCutover_NoClaudeInSpec_Silent
- PASS: TestProviderCutover_AllowPaidFallback_Silent
- PASS: TestProviderCutover_PreJune15Override_Silent
- PASS: TestProviderCutover_SubscriptionTier_Silent
- FAIL: TestProviderCutover_WarnMentionsEnvKeys — stub Run() returns empty; expected WARN detail

### tests/test_no_claude_e2e_structure.sh (new file)
- PASS: e2e script exists at tests/test_no_claude_e2e.sh
- PASS: e2e script has valid bash syntax
- PASS: e2e self-skips with exit 0 when TEKHTON_E2E=0
- PASS: e2e prints SKIP message when TEKHTON_E2E=0
- PASS: e2e self-skips with exit 0 when TEKHTON_E2E is unset
- PASS: fixture directory exists: tests/fixtures/cutover_project/
- PASS: fixture file exists: .claude/pipeline.conf
- PASS: fixture file exists: .claude/agents/coder.md
- PASS: fixture file exists: .claude/agents/reviewer.md
- PASS: fixture file exists: .claude/agents/tester.md
- PASS: fixture file exists: .claude/milestones/MANIFEST.cfg
- PASS: fixture file exists: .claude/milestones/m01-hello.md
- PASS: pipeline.conf disables intake agent (not needed for fake-codex run)
- PASS: pipeline.conf uses TEST_CMD=true (deterministic gate)
- PASS: pipeline.conf disables security agent
- PASS: MANIFEST.cfg has m01 entry
- PASS: MANIFEST.cfg m01 initial status is 'todo'
- PASS: m01-hello.md references hello.txt (the coder deliverable)
- PASS: m01-hello.md has Acceptance Criteria section
- PASS: scripts/audit-raw-claude.sh exists (referenced by e2e assertion)
- FAIL: docs/cutover-runbook.md missing (m23 Goal 3 not implemented)
- FAIL: docs/v5-polyglot.md missing cross-link to cutover-runbook.md

## Bugs Found
- BUG: [internal/preflight/provider_cutover.go:34] Run() is a no-op stub; never emits WARN when claude is in spec at api tier — m23 Goal 2 not implemented
- BUG: [docs/cutover-runbook.md] File does not exist — m23 Goal 3 (cutover checklist + stable-promotion procedure) not implemented
- BUG: [docs/v5-polyglot.md] Missing cross-link to cutover-runbook.md — m23 acceptance criterion 8 not met

## Files Modified
- [x] `internal/preflight/provider_cutover_test.go`
- [x] `tests/test_no_claude_e2e_structure.sh`

## Timing
- Test executions: 5
- Approximate total test execution time: 15s
- Test files written: 2
