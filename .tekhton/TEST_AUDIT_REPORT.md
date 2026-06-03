## Test Audit Report

### Audit Summary
Tests audited: 6 files, 68 test functions
Verdict: PASS

### Findings

#### ISOLATION: `TestExportEnvBlocks` leaves process env dirty after the test
- File: internal/stages/security/run_test.go:551-585
- Issue: The test calls `os.Unsetenv` to clear three env vars at the top, then calls
  `exportEnvBlocks` which sets them via `os.Setenv`. Neither call registers a cleanup
  with the testing framework, so `SECURITY_REWORK_CYCLES_DONE=2`,
  `SECURITY_FINDINGS_BLOCK=…`, and `SECURITY_FIXES_BLOCK=…` persist in process env
  after the test exits. Any subsequent test that reads these vars without first
  resetting them can observe stale values. Practical impact is low today because all
  RunStage tests call `setupProject`, which resets all three via `t.Setenv`
  (auto-restored). However, any new test that calls `exportEnvBlocks` directly and
  omits `setupProject` will read stale state.
- Severity: MEDIUM
- Action: Replace the manual `os.Unsetenv` preamble and the sub-test's reliance on
  `os.Setenv` side-effects with `t.Setenv` calls (or register `t.Cleanup(func() {
  os.Unsetenv("SECURITY_REWORK_CYCLES_DONE") })` etc.). `exportEnvBlocks` must keep
  using `os.Setenv` in production to reach downstream bash stages, but the test can
  protect itself with explicit cleanups.

#### COVERAGE: `TestSecurityCmd_AllSubcommandsHelp` makes a vacuous assertion
- File: cmd/tekhton/security_test.go:105-116
- Issue: `sub.Execute()` with `--help` always returns `nil` in Cobra by design — it
  prints help and exits cleanly. The assertion `if err := sub.Execute(); err != nil`
  is structurally equivalent to `assert(True)` for any properly-registered command.
  The test adds no correctness signal beyond "the command tree doesn't panic during
  registration," which is already implied by `TestSecurityCmd_RegisterAndVisibility`
  traversing the same command slice.
- Severity: LOW
- Action: Either remove the test (its smoke-test value is fully covered by
  `TestSecurityCmd_RegisterAndVisibility`) or strengthen it by capturing stdout and
  asserting the help output contains the subcommand's name string — this would at
  least catch a command registered with an empty `Use:` field.

#### ISOLATION: RunStage tests leave env vars set via `os.Setenv` in process state
- File: internal/stages/security/run_test.go:294 (TestRunStage_FixableReworkPass), and
  indirectly from any RunStage call that reaches `exportEnvBlocks`
- Issue: `RunStage` calls `exportEnvBlocks` → `os.Setenv(…)` for the three SECURITY_*
  vars. These are not cleaned up by the test framework. `TestRunStage_FixableReworkPass`
  reads `os.Getenv("SECURITY_REWORK_CYCLES_DONE")` directly (line 294) rather than from
  the returned result struct. If test execution order changes or parallelism is
  introduced, this could produce a false positive from a prior test's stale value.
  Current mitigation: `setupProject` resets all three via `t.Setenv`, protecting every
  test that calls it.
- Severity: LOW
- Action: Where `os.Getenv` post-RunStage is intentional (asserting the downstream bash
  env-export contract), add `t.Cleanup(func() { os.Unsetenv("SECURITY_REWORK_CYCLES_DONE")
  })` etc. at the start of the affected sub-tests. For the assertion itself, prefer reading
  `res.AgentCalls` and related result-struct fields over re-reading process env where the
  information is available from both sources — the result struct is never stale.

### No Issues Found in the Following Areas

**Assertion Honesty (all six files)** — Every assertion derives from an actual function
call with controlled inputs. `TestParseReport_Fixtures` expected values match the fixture
file content verbatim (verified against testdata/reports/). `TestBlocks_Goldens` diffs
against 18 bash-captured baseline files (all present in testdata/baselines/); the baseline
approach is sound for a port-parity test. `TestHandleUnfixable_*` expected description
prefixes match the `switch` branch string literals in escalation.go:57–67 exactly.
`TestClampTurns_MilestoneModeDoubles` expected values are derivable from the doubling/
clamping rules in scan.go. No `assertTrue(True)`, tautological comparisons, or hard-coded
"magic" values that bypass implementation logic were found (the rank integers 4/3/2/1 in
`TestRank_KnownSeverities` are anchored against the `severityRank` map in severity.go).

**Test Weakening** — The only existing test file that was modified is
`cmd/tekhton/security_test.go`. The changes are: `TestSecurityCmd_Hidden` renamed to
`TestSecurityCmd_RegisterAndVisibility` with updated assertions reflecting the m35.2
visibility split; `TestSecurityHandleUnfixable_Escalate*` and `_Halt*` deleted alongside
the bash shim they exercised; `filterEnv` helper removed (only the deleted tests used it);
`TestSecurityHandleUnfixable_Removed` added. None of these weaken coverage — the deleted
shim tests are replaced by `TestRunStage_UnfixableHalt` and `TestRunStage_UnfixableEscalate`
in `run_test.go` which exercise the in-process path the Go stage actually uses. The rename
expands rather than narrows the assertion surface.

**Test Naming** — All 68 test function names clearly encode the scenario and expected
outcome. No opaque or ambiguous names found.

**Scope Alignment** — All imports and symbol references resolve correctly against the
current codebase. `stages/security.sh` and `lib/security_helpers.sh` are deleted;
`tests/test_security_stage.sh` is also deleted per CODER_SUMMARY.md; no orphaned test
file imports the deleted symbols. `handle-unfixable` subcommand removal is positively
asserted by `TestSecurityHandleUnfixable_Removed`. `DefaultStageDefs[proto.StageSecurity]`
routing is asserted by `TestDefaultStageDefs_SecurityHasGoImpl` (in
`internal/stagerunner/helpers_test.go`, not listed in this audit but referenced as
in-scope by the coder summary). All six audited files reference only live symbols.

**Implementation Exercise** — Tests call real functions. Mocking is targeted: `fakeAgent`
and `fakeBuildGate` in `run_test.go` substitute the seams defined in `run.go` without
mocking the function under test (`RunStage`). `fakeHumanAction` in `escalation_test.go`
tests policy-routing logic while `TestNewEscalator_WiresRealHumanAction` exercises the
real `drift.HumanAction` write path end-to-end in a temp dir. `buildTekhtonBinary` in
`security_test.go` compiles and runs the real binary for exit-code contracts that
cannot be intercepted in-process. No test mocks every dependency and then asserts
only on the mock setup.

**Fixture Integrity** — All 6 report fixtures (testdata/reports/01–06.md) and all 18
baseline files (testdata/baselines/01–06 × fixable/unfixable/notes) are present on
disk (verified via glob). `TestParseReport_Fixtures` will fail with a descriptive error
rather than silently pass if a fixture file goes missing.
