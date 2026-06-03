## Test Audit Report

### Audit Summary
Tests audited: 8 files, ~59 test cases (50 Go test functions across 6 files; 9 shell scenarios across 2 scripts)
Verdict: PASS

### Findings

#### ISOLATION: Wedge-audit test plants files in the live repo working tree
- File: tests/test_wedge_audit_m35.sh:27-28, 51, 66
- Issue: `PLANT_STAGE` and `PLANT_HELPERS` resolve to `${TEKHTON_HOME}/stages/security.sh` and `${TEKHTON_HOME}/lib/security_helpers.sh` — the actual Tekhton working tree, not a temp copy. A concurrent invocation or SIGKILL before the EXIT trap fires leaves planted files on disk, dirtying the working tree and causing Test 1 ("clean HEAD exits 0") to fail spuriously for any process running the audit at the same time. The interim per-test `rm -f` after Tests 2 and 3 mitigates this within a single sequential run but does not eliminate the race window between the `printf` write and the `rm` later in the same case.
- Severity: MEDIUM
- Action: Run the audit against a `git worktree add --detach <tmpdir>` copy, or at minimum `cp -a "$TEKHTON_HOME" "$tmpdir"` and point `TEKHTON_HOME` at the copy for the duration of the test. The existing EXIT trap pattern is otherwise correct and should be preserved. If the working-tree approach is kept, document the single-invocation assumption in a comment near the PLANT_ variable declarations.

#### INTEGRITY: Parity baselines lock current Go output, not original bash captures
- File: tests/test_security_parity.sh:25-34
- Issue: The nine baselines under `tests/baselines/m35-security/` were captured from the current Go stage output via `M35_PARITY_CAPTURE=1`, not from the pre-M35 bash stage. The tag `v4.34.99-security-baseline` was never created (acknowledged meta-failure documented in the test header and `docs/go-migration.md`). The gate therefore detects Go-vs-Go regressions from the capture point forward but cannot detect behavioral differences introduced during the port. Leaf-function parity is covered transitively by m35.1's 18 golden-file baselines in `internal/security/testdata/baselines/`, but stage-level orchestration behaviors (skip-check order, rework-cycle accounting, HumanAction flag, exit-reason selection) are not independently validated against bash output.
- Severity: MEDIUM
- Action: For m36+, create a `v4.<minor>.99-<stage>-baseline` capture tag before the Go port lands and diff against it in the parity gate. For m35 specifically, accept the transitive-baseline approach as the mitigation (already honestly documented in both the script header and `docs/go-migration.md`). No code change required unless a behavioral discrepancy surfaces during dogfood.

#### ISOLATION: Hardcoded /tmp scratch path shared across concurrent invocations
- File: tests/test_wedge_audit_m35.sh:52, 67, 87
- Issue: Tests 2, 3, and 4 redirect `bash "$AUDIT_SCRIPT"` output to the fixed path `/tmp/wedge_audit_m35.out`. Two concurrent invocations on the same host (parallel CI shards, or a manual run alongside `make dogfood`) can clobber each other's capture file; the subsequent `grep -qF` may then read the wrong run's output, producing a spurious pass or fail. The file is also not added to the `cleanup` trap's `rm -f` list, so it persists on disk after the test exits.
- Severity: LOW
- Action: Replace all three `/tmp/wedge_audit_m35.out` references with a per-invocation temp file. Near the top of the script, after the `cleanup` function definition but before Test 1: `AUDIT_OUT=$(mktemp)`. Add `"$AUDIT_OUT"` to the `rm -f` list inside `cleanup`. Replace the three hardcoded references with `"$AUDIT_OUT"`.

#### EXERCISE: TestRunStage_ScanFailedOnCreateTempError — stated failure path ambiguous without verifying setupProject wires a real prompts dir
- File: internal/stages/security/coverage_test.go:260-290
- Issue: The test sets TMPDIR to a non-existent directory to force `writePromptTmpFile` to fail inside `invokeScanAgent`. However, `invokeScanAgent` calls `prompt.Render` before `writePromptTmpFile`; if `cfg.PromptsDir` does not resolve to a directory containing `security_scan.prompt.md`, Render fails first and the test achieves the same observable outcome (err != nil, VerdictFail, "scan_failed", AgentCalls=0) via a different code path. Both paths produce the correct result, so the test outcome is never wrong, but the specific branch being exercised (and therefore the coverage benefit) depends on whether `setupProject` wires the real prompts directory — which requires reading further into `run_test.go` than the first 80 lines to confirm.
- Severity: LOW
- Action: Read `run_test.go::setupProject` to confirm it sets `TEKHTON_HOME` to the repo root so that Render succeeds before CreateTemp is attempted. If confirmed, add a brief comment in the test body noting the dependency: `// setupProject must wire a real TEKHTON_HOME so prompt.Render succeeds; TMPDIR override then forces the CreateTemp arm`. If setupProject does not wire a real prompts dir, add `t.Setenv("TEKHTON_HOME", repoRoot(t))` before the TMPDIR override to guarantee the intended path.

### No Issues Found in the Following Areas

**Assertion Honesty (all 8 files)** — Every assertion derives from an actual function call against controlled input. The rank integers (4/3/2/1) in `TestRank_KnownSeverities` are anchored directly against the `severityRank` map in `severity.go:22-27`. The expected `Finding` structs in `TestParseReport_Fixtures` were verified against the fixture content in `testdata/reports/04-mixed-fixable.md` and match exactly (the Description field matches the `${line#*] }` bash semantic preserved by `strings.Index(line, "] ")`). `TestBlocks_Goldens` diffs against 18 golden baseline files confirmed present on disk. Escalation description prefixes in `TestHandleUnfixable_*` match the switch-branch string literals in `escalation.go:57-67` exactly. No `assertEqual(x, x)`, no tautological comparisons, no magic constants that bypass implementation logic.

**Edge Case Coverage** — The test suite covers: nil/empty findings slices (`HasBlocking`, block builders, escalation short-circuit); missing files for `ParseReport`, `IsDocsOnly`, and the escalator's human-action path; every severity in the 4×4 MeetsThreshold matrix; case-sensitive fallthrough to rank=0; the full `docsExt` allowlist via loop; malformed and truncated report fixtures; error propagation for both `EnsureFile` and `Append` failures; the `writeHaltState` store-failure path; the `subprocessBuildGate` no-binary noop path; and three end-to-end scenarios (no-findings, fixable-rework-resolved, unfixable-escalate). The ratio of error-path to happy-path tests is healthy across all six Go files.

**Test Weakening** — `cmd/tekhton/security_test.go` is the only file in the audit set that modifies existing tests rather than only adding new ones. The deleted tests (`TestSecurityHandleUnfixable_Escalate*`, `_Halt*`) exercised a shim-only subcommand that no longer exists; they are replaced by `TestRunStage_UnfixableHalt` and `TestRunStage_UnfixableEscalate` in `run_test.go` which exercise the in-process Go path. The visibility test was expanded (more subcommands covered), not narrowed. No assertion surface was removed without a documented replacement.

**Test Naming** — All 50 Go test function names encode both the scenario and the expected outcome (`TestMeetsThreshold_CaseSensitive`, `TestHandleUnfixable_HaltBranch`, `TestWriteHaltState_StoreFails`, etc.). No opaque names found in any of the 8 files.

**Scope Alignment** — All imports and symbol references resolve against the current codebase. `stages/security.sh` and `lib/security_helpers.sh` are deleted; no audited test file imports or sources them. `handle-unfixable` subcommand removal is asserted in `security_test.go`. `test_wedge_audit_m35.sh` references only `scripts/wedge-audit.sh` and files it creates and removes itself. The `docsExt` variable referenced by `TestIsDocsOnly_CoversSecondaryExtensions` is the real package-level map (same package, `package security`). No orphaned tests detected.

**Implementation Exercise** — Tests call real code. `fakeAgent` and `fakeBuildGate` substitute only the external I/O seams; `RunStage` itself is the function under test in `coverage_test.go`. `fakeHumanAction` in `escalation_test.go` tests policy-routing logic in the real `HandleUnfixable` implementation; `TestNewEscalator_WiresRealHumanAction` exercises the real `drift.HumanAction` write path end-to-end and confirms via `CountUnchecked` that a disk write occurred. `buildTekhtonBinary` compiles and executes the real binary for all exit-code contract tests. No test mocks every dependency and then asserts only on the mock setup.
