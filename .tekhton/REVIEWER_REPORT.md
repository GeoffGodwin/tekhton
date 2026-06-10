## Test Audit Report

### Audit Summary
Tests audited: 2 files, 27 test functions (cmd/tekhton/run_test.go, internal/runner/provider_select_test.go)
Verdict: PASS

### Findings

#### EXERCISE: TestProviderFlagEnvOverride tests a local copy, not the implementation
- File: cmd/tekhton/run_test.go:120
- Issue: The test defines a local `apply` closure that literally duplicates the three-if block
  from run.go's RunE body (lines 88–96). It never invokes `newRunCmd()` or the real RunE —
  it calls its own copy, then reads back the env vars it just set. If the implementation
  changes env-var names (e.g. "PROVIDER" → "CLAUDE_PROVIDER") or reorders the conditions,
  every sub-test in this function passes while the production code silently drops the flag value.
  The test comment acknowledges this: "We replicate the exact three-if block from run.go."
  Replication-based tests have no ability to catch drift.
- Severity: MEDIUM
- Action: Extract the three-if block from RunE into a named function
  (e.g. `applyProviderEnvOverrides(override, chain, tier string)`) in run.go, then call
  that function from both RunE and from this test. Alternatively, drive `newRunCmd()` via
  cobra's test harness with --provider/--provider-chain/--require-tier flags and assert the
  resulting env vars. Either approach eliminates the drift risk.

All other rubric points pass for both audited files.

**Assertion Honesty**: Every assertion is derived from real function calls; no hard-coded
magic values unmoored from implementation logic.
- `TestBuildRunRequestExactlyOne` covers 8 flag combinations against `buildRunRequest`'s
  switch logic (run.go:211–228); wantMode strings are proto constants, not literals.
- `TestBuildRunRequestRequiresTekhtonHome` verifies error contains "TEKHTON_HOME" — matched
  against run.go:253 `fmt.Errorf("--tekhton-home or TEKHTON_HOME required")`.
- `TestBuildRunRequestAutoAdvanceWithoutMilestone` relies on `proto.RunRequestV1.Validate()`
  (run_v1.go:160–162) which enforces `AutoAdvance && Mode != milestone → error`. Confirmed
  the proto validation exists.
- `TestNormalizeMilestoneID` cases exactly match the implementation's three branches
  (run.go:463–477): strip leading m/M when next char is digit; pass bare digit through;
  lowercase unknown shapes.
- Sentinel names in `TestClearAutoAdvanceIterationState_*` match the literal slice in
  `clearAutoAdvanceIterationState` (run.go:767–770).
- Banner strings in `TestEmitAutoAdvanceCommitBanner_*` match fmt.Fprintf templates at
  run.go:806, 812, 818; the ✓/⚠ prefix characters match exactly.
- `TestResolveProvider_ChainWithRequiredTier` asserts `c.RequiredTier == "subscription"`
  against provider_select.go:48–50 which reads TEKHTON_REQUIRE_TIER and assigns it directly.

**Edge Case Coverage**: Both suites cover error paths in meaningful proportion.
- run_test.go: none/two-flags conflict (4 error cases in table), missing tekhton-home,
  autoAdvance without milestone, non-git directory, HEAD-read failure, partial sentinels.
- provider_select_test.go: unknown provider name returns error; single, chain, stage-override,
  and default chain cover all branching in ResolveProvider.

**Implementation Exercise**: All tests other than TestProviderFlagEnvOverride call real
implementation functions — `buildRunRequest`, `buildRunner`, `clearAutoAdvanceIterationState`,
`emitAutoAdvanceCommitBanner`, `readGitHead`, `normalizeMilestoneID`, `suggestionsFromArgs`,
`runner.ResolveProvider`. The git-based tests drive actual git repos.

**Test Weakening**: No existing test assertions were removed or broadened. The modifications
added new test functions and did not alter prior expected values.

**Test Naming**: All 27 test function names encode both the scenario and expected outcome
(e.g. `TestResolveProvider_ChainWithRequiredTier`, `TestClearAutoAdvanceIterationState_PartialSentinels`,
`TestEmitAutoAdvanceCommitBanner_ManifestWriteByNonFinalizeSource`).

**Scope Alignment**: All tested symbols exist in the current implementation with the signatures
the tests assume. No orphaned or stale references detected.

**Test Isolation**: Every test uses `t.TempDir()` for filesystem state; git repos are
initialised fresh in temp directories. `t.Setenv` is used for all env-var mutations and
restores after each test. No test reads from live pipeline artifacts, `.claude/logs/`,
`.tekhton/`, or any mutable project-state file.
