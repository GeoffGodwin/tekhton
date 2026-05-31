## Test Audit Report

### Audit Summary
Tests audited: 2 files, 14 test functions (cmd/tekhton/gate_test.go) + 11 scenarios (tests/test_gates_parity.sh)
Verdict: PASS

### Findings

#### COVERAGE: Build-gate parity scenarios do not directly assert exit code
- File: tests/test_gates_parity.sh:69-99 (_run_build_scenario)
- Issue: `result_exit` is captured but never directly asserted. The comment at line 93 says
  exit code is verified "indirectly" via file existence. This creates a blind spot: if the
  gate binary panics or exits non-zero without writing BUILD_ERRORS.md (e.g., an
  infrastructure error from `runner.Run` wrapping a non-sentinel error, per
  internal/gates/completion.go:186-188 comments), a clean-run scenario (analyze_clean,
  compile_clean) would record a spurious parity_pass. The "fail" scenarios are
  self-checking (missing report file would trigger parity_fail), but the clean-run path
  is not guarded. By contrast, the completion scenarios do directly assert exit code
  (lines 122-136), so the gap is specific to `_run_build_scenario`.
- Severity: MEDIUM
- Action: Add a direct exit-code assertion inside `_run_build_scenario`. When
  `expect_report` is `no_report`, assert `[[ "$result_exit" -eq 0 ]]` and call
  `parity_pass` / `parity_fail` accordingly. When `expect_report` is `report`, assert
  `[[ "$result_exit" -ne 0 ]]`. One assertion call per scenario suffices.

#### COVERAGE: IN PROGRESS completion branch not exercised in parity scenarios
- File: tests/test_gates_parity.sh (no scenario covers this branch)
- Issue: `CompletionGate.Run` (internal/gates/completion.go:145-147) has five documented
  branches. Scenarios 5-11 cover: COMPLETE+pass, COMPLETE+fail-tests, no-status, timeout,
  M92-nil, M105-nil, and M86-nil. The first branch — coder self-reporting "IN PROGRESS"
  (returns `ErrCompletionInProgress`) — has no scenario. A CODER_SUMMARY.md containing
  `## Status: IN PROGRESS` exercises distinct gate logic and a distinct sentinel error.
- Severity: LOW
- Action: Add scenario 12 using `_run_completion_scenario` with
  `summary="## Status: IN PROGRESS"` and `exit_check="nonzero"`. No fixtures needed.

#### COVERAGE: resolveUnder edge cases not unit-tested
- File: cmd/tekhton/gate_test.go (no test for resolveUnder)
- Issue: `resolveUnder` (gate.go:205-210) has three behavioral branches — absolute path
  returned unchanged, empty projectDir returns path unchanged, relative path joined under
  projectDir. All three are load-bearing: the env contract relies on them for
  BUILD_ERRORS.md and BUILD_RAW_ERRORS.txt landing in the correct project directory.
  The function is implicitly exercised by `TestBuildGateFromEnv_AssemblesAllPhases`, but
  none of its edge cases are directly asserted.
- Severity: LOW
- Action: Add a table-driven `TestResolveUnder` covering the three branches. This is a
  pure function with no subprocess dependency, so the test is trivial and deterministic.

#### COVERAGE: Gap-documentation tests — informational, no action required
- File: cmd/tekhton/gate_test.go:216-252
- Issue: (Non-finding, noted for completeness.) Three tests document known m31.1 gaps:
  `TestCompletionGateFromEnv_NilBaselinePreventsM92Accept`,
  `TestCompletionGateFromEnv_DedupNilDocumentsM105Gap`,
  `TestCompletionGateFromEnv_SubstantiveNilDocumentsM86Gap`. All three assert that the
  respective `CompletionGate` fields are nil and include explicit comment blocks saying
  "this test will fail once wired." The pattern is correctly applied — each gap-doc test
  creates a regression guard that goes red when m31.2 wires the concrete implementation,
  prompting the author to update parity scenarios.
- Severity: LOW (informational only)
- Action: None now. When m31.2 wires Baseline/Dedup/Substantive in
  `completionGateFromEnv()`, delete or update these three tests as the comments instruct,
  and add the corresponding parity scenarios for the newly active branches.

---

### No Issues Found In

**INTEGRITY — none.** All assertions test real behavior derived from implementation
logic. The `len(g.Phases) != 5` assertion in `TestBuildGateFromEnv_AssemblesAllPhases`
(gate_test.go:172) is derived from the five factory keys registered in
`buildGateFromEnv` (gate.go:132-174). The `exitUsage` constant checked in
`TestGateUI_StubReturnsNonZero` (gate_test.go:69) is the same constant the stub
returns at gate.go:99. The `envBool("anything")` → false table case follows the exact
switch statement in gate.go:238-244. No hard-coded magic values appear anywhere in
the audited tests.

**WEAKENING — none.** All 14 functions in gate_test.go and all 11 scenarios in
test_gates_parity.sh are new (confirmed by TESTER_REPORT and CODER_SUMMARY). No
prior assertions were removed or broadened.

**SCOPE — none.** All function references verified against the current implementation.
`newGateCmd`, `newGateUICmd`, `buildGateFromEnv`, `completionGateFromEnv`, `envOr`,
`envBool`, `envSeconds`, `readValidationCmd` — all present in cmd/tekhton/gate.go with
matching signatures. `errExitCode` and `exitUsage` are used package-wide (confirmed
present in cmd/tekhton/finalize_test.go:103 and gate.go:99 respectively). The deleted
file `.tekhton/stage_results/stage_tester_r1_b0.json` is not referenced by any audited
test.

**EXERCISE — none.** All Go tests call real implementation functions. No test mocks
the primary function under test. `TestBuildGateFromEnv_AssemblesAllPhases` calls the
real `BuildGate.Run` end-to-end with all-skip phases (gate.go:174). The parity shell
tests invoke the compiled `tekhton` binary via `env -i` with a clean environment and
real command arguments.

**ISOLATION — none.** All Go tests use `t.TempDir()` and `t.Setenv()`. The parity
shell tests write to `mktemp -d` directories and clean up via `rm -rf "$tmp"` at the
end of each scenario. `env -i` isolates each binary invocation from the host
environment. No test reads mutable pipeline state files
(.tekhton/CODER_SUMMARY.md, .tekhton/BUILD_ERRORS.md, .claude/logs/*, etc.) without
first creating a controlled copy in a temp directory.
