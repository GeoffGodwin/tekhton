## Test Audit Report

### Audit Summary
Tests audited: 8 files, ~75 test functions (6 Go files × ~10 functions each, 2 bash files × ~6 scenarios each)
Verdict: PASS

### Findings

#### COVERAGE: Parity baselines were self-captured from the Go implementation, not from pre-M35 bash
- File: tests/test_security_parity.sh:26-35 (header comment, bootstrap note)
- Issue: The nine baseline files under `tests/baselines/m35-security/` were captured
  from the current Go stage output, not from pre-M35 bash behavior (tag
  `v4.34.99-security-baseline` was never created — acknowledged meta-failure). The gate
  therefore detects Go-vs-Go regressions from the capture point forward but cannot detect
  behavioral differences that were introduced during the port. The partial mitigation —
  m35.1's 18 golden-file baselines in `internal/security/testdata/baselines/` establish
  byte-for-byte parity for ParseReport, BuildFixableBlock, BuildUnfixableBlock, and
  BuildNotesBlock — covers leaf functions but not stage-level orchestration (skip-check
  order, rework cycle accounting, HumanAction flag setting, exit-reason selection).
- Severity: MEDIUM
- Action: For m36+, create a `v4.<minor>.99-<stage>-baseline` capture tag before the Go
  port lands and diff against it in the parity gate. For m35 specifically, accept the
  transitive-baseline approach as the mitigation (already documented in the script header
  and `docs/go-migration.md`). No code change required unless a behavioral discrepancy
  surfaces during dogfood.

#### EXERCISE: TestResolveTekhtonBin_LookPath asserts suffix rather than exact path
- File: internal/stages/security/coverage_test.go:121-123
- Issue: After constraining `PATH` to only `binDir` (a temp dir containing one binary),
  the test asserts `strings.HasSuffix(got, "tekhton")` instead of `got == fakeBin`. If
  `exec.LookPath` were to return a symlink-resolved or otherwise canonicalized path
  different from `fakeBin`, the suffix check passes while the stronger invariant fails
  silently. In practice the controlled PATH prevents false passes today, but the assertion
  does not express the test's actual intent.
- Severity: LOW
- Action: Replace the two weak assertions (non-empty + suffix) with a single
  `if got != fakeBin { t.Errorf(...) }`. The equality check is both more precise and
  shorter.

#### SCOPE: TestSecurityHandleUnfixable_Removed duplicates a check inside TestSecurityCmd_RegisterAndVisibility
- File: cmd/tekhton/security_test.go:271-278
- Issue: `TestSecurityHandleUnfixable_Removed` iterates `c.Commands()` and fatals if
  `handle-unfixable` is registered. `TestSecurityCmd_RegisterAndVisibility` (lines 89-91)
  performs the identical check inside its broader visibility audit. The standalone test
  adds no new assertion surface.
- Severity: LOW
- Action: Remove `TestSecurityHandleUnfixable_Removed`. The deletion contract is fully
  preserved by `TestSecurityCmd_RegisterAndVisibility`.

#### ISOLATION: test_wedge_audit_m35.sh writes audit output to a fixed /tmp path
- File: tests/test_wedge_audit_m35.sh:52, 67, 87
- Issue: Tests 2, 3, and 4 redirect `bash "$AUDIT_SCRIPT"` output to
  `/tmp/wedge_audit_m35.out` — a path shared across any concurrent invocations on
  the same host (two CI workers, parallel `make test` shards). A race between a write
  and the subsequent `grep -qF` could produce a spurious pass or fail. The file is also
  not removed by the `cleanup` trap, leaving it on disk after the test exits.
- Severity: LOW
- Action: Add `AUDIT_OUT=$(mktemp)` near the top of the script (after the `cleanup`
  function but before test 1); add `"$AUDIT_OUT"` to the `rm -f` list in `cleanup`;
  replace the three `/tmp/wedge_audit_m35.out` references with `"$AUDIT_OUT"`.

### No Issues Found in the Following Areas

**Assertion Honesty (all 8 files)** — Every assertion derives from an actual function
call against controlled input. `TestRank_KnownSeverities` rank integers (4/3/2/1) are
anchored against `severityRank` in `severity.go:22-27`. `TestParseReport_Fixtures`
expected `Finding` structs were verified to match the fixture content in
`testdata/reports/`. `TestBlocks_Goldens` diffs against 18 golden files all present on
disk under `internal/security/testdata/baselines/`. Escalation description prefixes in
`TestHandleUnfixable_*` match the switch-branch string literals in `escalation.go:57-67`
exactly. `TestSecurityMeetsThreshold_ExitCodes` exit codes derive from `MeetsThreshold`
semantics verified in `severity_test.go`. No `assertEqual(x, x)`, no tautological
comparisons, no hard-coded magic values that bypass implementation logic.

**Test Weakening** — `cmd/tekhton/security_test.go` is the only file modified from a
prior run. Deleted tests (`TestSecurityHandleUnfixable_Escalate*`, `_Halt*`) exercised
the removed bash shim; they are replaced by `TestRunStage_UnfixableHalt` and
`TestRunStage_UnfixableEscalate` in `run_test.go` which exercise the in-process Go path.
`TestSecurityCmd_Hidden` was renamed to `TestSecurityCmd_RegisterAndVisibility` with
assertions expanded (not narrowed) to cover the m35.2 visibility split. No assertion
surface was removed without a documented replacement.

**Test Naming** — All test function names encode both the scenario and the expected
outcome. No opaque names (`test_1`, `test_thing`) found across any of the 8 files.

**Scope Alignment** — All imports and symbol references resolve against the current
codebase. `stages/security.sh` and `lib/security_helpers.sh` are deleted; no audited
test file imports or sources them. `handle-unfixable` subcommand removal is asserted in
`security_test.go`. `test_wedge_audit_m35.sh` references only `scripts/wedge-audit.sh`
and planted files that are created and removed within the test. No orphaned tests: the
deleted file (`.tekhton/stage_results/stage_tester_r1_b0.json`) is not imported by any
file under audit.

**Implementation Exercise** — Tests call real code. `fakeAgent` and `fakeBuildGate` in
`coverage_test.go` (shared from `run_test.go`) substitute only the I/O seams; `RunStage`
itself is the function under test. `fakeHumanAction` in `escalation_test.go` tests
policy-routing logic; `TestNewEscalator_WiresRealHumanAction` exercises the real
`drift.HumanAction` write path end-to-end in a temp dir. `buildTekhtonBinary` compiles
and executes the real binary for exit-code contracts. No test mocks every dependency and
then asserts only on the mock setup.

**Test Isolation (all 8 files)** — All Go tests use `t.TempDir()` for file I/O and
`t.Setenv()` for env changes. `test_security_parity.sh` uses `mktemp -d` with an EXIT
trap. `test_wedge_audit_m35.sh` plants files only in well-named locations inside the
repo tree (`lib/_m35_test_planted_security_fn.sh`) and removes them via an EXIT trap.
No test reads mutable pipeline artifacts (`.tekhton/CODER_SUMMARY.md`,
`.tekhton/REVIEWER_REPORT.md`, `.tekhton/BUILD_ERRORS.md`, `.claude/logs/*`) from the
live project directory without first writing controlled fixture content to a temp dir.
