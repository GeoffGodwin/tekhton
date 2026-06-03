## Test Audit Report

### Audit Summary
Tests audited: 8 files, ~95 test functions/cases
Verdict: PASS

### Findings

#### ISOLATION: Wedge-audit test plants files in the live repo working tree
- File: tests/test_wedge_audit_m35.sh:27-28, 51, 66
- Issue: `PLANT_STAGE` and `PLANT_HELPERS` resolve to `${TEKHTON_HOME}/stages/security.sh` and `${TEKHTON_HOME}/lib/security_helpers.sh` — the actual Tekhton working tree, not a temp copy. A concurrent invocation or SIGKILL before the EXIT trap fires leaves planted files on disk, dirtying the working tree and causing Test 1 ("clean HEAD exits 0") to fail spuriously for any process running simultaneously. The per-test `rm -f` after Tests 2 and 3 mitigates this within a single sequential run but does not eliminate the race window between the `printf` write and the `rm`.
- Severity: MEDIUM
- Action: Run the audit against a `git worktree add --detach <tmpdir>` copy (set TEKHTON_HOME to the copy for the duration of the test), or document the single-invocation assumption near the PLANT_ variable declarations. The existing EXIT trap is otherwise correct and should be preserved.

#### ISOLATION: Hardcoded /tmp scratch path shared across concurrent invocations
- File: tests/test_wedge_audit_m35.sh:52, 67, 87, 111
- Issue: Tests 2, 3, and 4 redirect audit output to the fixed path `/tmp/wedge_audit_m35.out`. Two concurrent invocations (parallel CI shards, or a manual run alongside `make dogfood`) can clobber each other's capture; the subsequent `grep -qF` may then read the wrong run's output, producing a spurious pass or fail. The file is not added to the `cleanup` trap's `rm -f` list, so it persists on disk after the test exits.
- Severity: LOW
- Action: Replace all three `/tmp/wedge_audit_m35.out` references with a per-invocation temp file created near the top of the script (after the `cleanup` function): `AUDIT_OUT=$(mktemp)`. Add `"$AUDIT_OUT"` to the `rm -f` list inside `cleanup`. Replace the hardcoded references with `"$AUDIT_OUT"`.

#### INTEGRITY: Parity baselines lock current Go output, not original bash captures
- File: tests/test_security_parity.sh:25-34
- Issue: The nine baselines under `tests/baselines/m35-security/` were captured from the current Go stage output via `M35_PARITY_CAPTURE=1`, not from the pre-M35 bash stage (the tag `v4.34.99-security-baseline` was never created — the acknowledged meta-failure documented in the script header and `docs/go-migration.md`). The gate detects Go-vs-Go regressions from the capture point forward but cannot detect behavioral differences introduced during the port itself. Leaf-function parity is covered transitively by m35.1's 18 golden-file baselines in `internal/security/testdata/baselines/`, so stage-level orchestration behaviors are not independently validated against bash output.
- Severity: MEDIUM
- Action: For m36+, create a `v4.<minor>.99-<stage>-baseline` capture tag before the Go port lands. For m35, accept the transitive-baseline approach already honestly documented. No code change required unless a behavioral discrepancy surfaces during dogfood.

#### EXERCISE: TestRunStage_ScanFailedOnCreateTempError — code path ambiguity
- File: internal/stages/security/coverage_test.go:260-290
- Issue: The test sets TMPDIR to a non-existent path to force `writePromptTmpFile` to fail inside `invokeScanAgent`. However, if `invokeScanAgent` calls `prompt.Render` before `writePromptTmpFile` and the prompts directory cannot be resolved, Render may fail first — exercising a different code path while producing the same observable outcome (err != nil, VerdictFail, "scan_failed", AgentCalls=0). The test outcome is never incorrect, but the specific branch being covered is ambiguous. `setupProject` in `run_test.go` does wire `TEKHTON_HOME` to `repoRoot(t)`, which confirms the real prompts directory is available, so the intended `writePromptTmpFile` arm is the one actually exercised — but this is non-obvious without reading across files.
- Severity: LOW
- Action: Add a brief inline comment in the test body: `// TEKHTON_HOME is wired to repoRoot(t) by setupProject, so prompt.Render succeeds; TMPDIR override then forces the CreateTemp arm of writePromptTmpFile.`

---

### No Issues Found in the Following Areas

**Assertion Honesty (all 8 files)** — Every assertion derives from a real function call against controlled input. The rank integers (4/3/2/1) in `TestRank_KnownSeverities` are anchored directly against `severityRank` in severity.go:22-27. Expected `Finding` structs in `TestParseReport_Fixtures` match the fixture content in `testdata/reports/` and the `strings.Index(line, "] ")` Description-extraction logic in findings.go:69. `TestBlocks_Goldens` diffs against 18 golden baseline files confirmed present on disk. Escalation description prefixes in `TestHandleUnfixable_*` match the switch-branch string literals in escalation.go:57-67 exactly. No `assertEqual(x, x)`, no magic constants that bypass implementation logic, no always-passing assertions.

**Edge Case Coverage** — Covered: nil/empty findings slices; missing files for ParseReport, IsDocsOnly, and the escalator human-action path; the full 4×4 MeetsThreshold matrix; case-sensitive fallthrough to rank=0; the complete `docsExt` allowlist via loop; malformed and truncated report fixtures; error propagation for both EnsureFile and Append failures; writeHaltState store-failure silent-discard; subprocessBuildGate no-binary noop; and three end-to-end scenarios (no-findings, fixable-rework-resolved, unfixable-escalate). The ratio of error-path to happy-path tests is healthy across all six Go files.

**Test Weakening** — `cmd/tekhton/security_test.go` is the only file that modified existing tests. The deleted `TestSecurityHandleUnfixable_*` tests covered a shim-only subcommand that no longer exists; they are replaced by `TestRunStage_UnfixableHalt` and `TestRunStage_UnfixableEscalate` in `run_test.go` which exercise the equivalent in-process Go path. The visibility test was expanded (more subcommands covered), not narrowed. No assertion surface was removed without a documented replacement.

**Test Naming** — All 50 Go test function names encode both the scenario and the expected outcome (`TestMeetsThreshold_CaseSensitive`, `TestHandleUnfixable_HaltBranch`, `TestWriteHaltState_StoreFails`, etc.). No opaque names found in any of the 8 files.

**Scope Alignment** — All imports and symbol references resolve against the current codebase. `stages/security.sh` and `lib/security_helpers.sh` are deleted; no audited test file imports or sources them. `handle-unfixable` subcommand removal is asserted in security_test.go. The `docsExt` variable in `TestIsDocsOnly_CoversSecondaryExtensions` is the real package-level map (same package). No orphaned tests detected.

**Implementation Exercise** — Tests call real code. `fakeAgent` and `fakeBuildGate` substitute only external I/O seams; `RunStage` is the real function under test. `fakeHumanAction` tests policy routing in the real `HandleUnfixable`; `TestNewEscalator_WiresRealHumanAction` exercises the real `drift.HumanAction` write path and confirms via `CountUnchecked` that a disk write occurred. `buildTekhtonBinary` compiles and executes the real binary for all exit-code contract tests. No test mocks every dependency and then asserts only on the mock setup.

**Test Isolation** — All Go tests create fixtures via `t.TempDir()` and override env via `t.Setenv()`. No test reads mutable project files directly (no `.tekhton/CODER_SUMMARY.md`, no `.tekhton/REVIEWER_REPORT.md`, no live pipeline logs). `test_security_parity.sh` operates entirely within `mktemp -d` with a `trap 'rm -rf "$WORK"' EXIT`. The working-tree mutation in `test_wedge_audit_m35.sh` is flagged above (MEDIUM) but does not constitute an unmitigated isolation failure for sequential invocations.
