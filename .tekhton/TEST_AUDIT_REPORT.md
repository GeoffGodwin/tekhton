## Test Audit Report

### Audit Summary
Tests audited: 5 files, 35 test functions
Verdict: PASS

### Findings

#### INTEGRITY: TestMeetsThreshold_AllKnownPairs uses circular expected-value derivation
- File: internal/security/severity_test.go:37
- Issue: Expected values are computed as `want := Rank(sev) >= Rank(thr)` — the same
  expression `MeetsThreshold` delegates to internally. A systematic bug affecting both
  `Rank` and `MeetsThreshold` identically (e.g., both use a wrong map key consistently)
  would not be caught. The risk is mitigated in practice by `TestRank_KnownSeverities`
  (lines 5–19), which independently asserts the absolute integer values (CRITICAL=4,
  HIGH=3, MEDIUM=2, LOW=1). The combination of both tests provides full coverage, but
  if `TestRank_KnownSeverities` is ever removed, `TestMeetsThreshold_AllKnownPairs`
  becomes a tautology.
- Severity: LOW
- Action: Add a comment on `TestMeetsThreshold_AllKnownPairs` noting its dependency on
  `TestRank_KnownSeverities` as the anchor. Optionally express the two most critical
  pairs (CRITICAL≥HIGH=true, HIGH≥CRITICAL=false) with hardcoded booleans alongside
  the loop so the test remains meaningful if the rank test is ever split or removed.

#### COVERAGE: NewEscalator and CLI handle-unfixable write to different default paths
- File: internal/security/escalation_test.go:189 and cmd/tekhton/security_test.go:267
- Issue: `NewEscalator(dir)` writes to `dir/.tekhton/HUMAN_ACTION_REQUIRED.md`
  (escalation.go:29). The CLI `handle-unfixable --project-dir dir` calls
  `humanActionPath(dir)` (drift.go:517) which defaults to `dir/HUMAN_ACTION_REQUIRED.md`
  (no `.tekhton/` prefix). Both code paths are individually tested against their
  respective correct paths, but no test asserts they agree. In m35.1 the bash shim is
  the only caller, so the CLI path is operative. When m35.2 ports the stage to Go and
  calls `NewEscalator` directly, it will silently write to a different file than the
  bash shim did. The test comment at security_test.go:268 documents the difference but
  does not flag it as a pre-m35.2 resolution requirement.
- Severity: MEDIUM
- Action: Record this path divergence as an explicit TODO comment on `NewEscalator`
  and in the m35.2 milestone acceptance criteria. Alternatively, unify by having
  `NewEscalator` call `humanActionPath` so both code paths share a single resolver
  — this eliminates the divergence class entirely.

#### COVERAGE: BuildUnfixableBlock threshold filtering has no dedicated unit test
- File: internal/security/blocks_test.go:72
- Issue: `TestBuildUnfixableBlock_ExcludesYes` (line 72) verifies that `fixable:yes`
  rows are excluded from the unfixable block but does not verify that below-threshold
  rows are excluded. For `BuildFixableBlock` the same scenario is directly tested by
  `TestBuildFixableBlock_Threshold` (line 48). For `BuildNotesBlock` threshold behavior
  is directly tested by `TestBuildNotesBlock_OnlyBelowThreshold` (line 89).
  `BuildUnfixableBlock` threshold enforcement is covered only indirectly through
  `TestBlocks_Goldens` — if `BuildUnfixableBlock` accidentally included below-threshold
  unfixable rows, the golden-file test would catch it, but the failure message would be
  harder to diagnose without a focused test.
- Severity: LOW
- Action: Add `TestBuildUnfixableBlock_Threshold` passing a CRITICAL threshold and
  asserting that HIGH unfixable rows are absent from the result, mirroring the
  `TestBuildFixableBlock_Threshold` pattern.

#### COVERAGE: CLI is-docs-only missing-file exit code not covered at subprocess level
- File: cmd/tekhton/security_test.go:221
- Issue: `TestSecurityIsDocsOnly_ExitCodes` exercises two cases (docs-only → exit 0,
  code-present → exit 1) but not the missing-file case. `IsDocsOnly` returns `(false, nil)`
  for a missing file, which the CLI handler converts to `os.Exit(1)`. The Go unit test
  `TestIsDocsOnly_MissingSummary` (findings_test.go:70) confirms the library behavior, but
  the subprocess exit-code contract for this path is not exercised. A future refactor that
  changes how the CLI handles `IsDocsOnly` returning false could break the bash shim without
  a failing test.
- Severity: LOW
- Action: Add a third subprocess case to `TestSecurityIsDocsOnly_ExitCodes` using a
  non-existent path and assert exit code 1.

#### COVERAGE: 06-truncated-section fixture does not test true mid-stream truncation
- File: internal/security/testdata/reports/06-truncated-section.md
- Issue: The fixture is named "truncated-section" but the content is an empty
  `## Findings` section (header immediately followed by `## Summary` with no rows).
  This exercises the same "findings present but empty body" path covered differently by
  `02-no-findings-header.md`. A true truncation scenario — a `## Findings` section that
  ends at EOF without a closing `## ` header — is not represented. `bufio.Scanner`
  handles EOF cleanly so this is not a defect risk, but the fixture name is misleading
  and the EOF path is not demonstrated by any named test case.
- Severity: LOW
- Action: Either rename `06-truncated-section.md` to `06-empty-findings-body.md` to
  match its actual content, or replace it with a fixture that has one or more rows
  followed by EOF (no closing `## ` header) to test actual mid-stream truncation, and
  add a corresponding expectation row in `TestParseReport_Fixtures`.

### No Issues Found in the following areas

**Assertion Honesty (all five files)** — Assertions derive from real function calls
against controlled inputs. `TestParseReport_Fixtures` expected values match the fixture
file content verbatim (verified against the fixture files). `TestBlocks_Goldens` diffs
against pre-captured bash baselines, not hard-coded strings. `TestHandleUnfixable_*`
expected prefixes match the `switch` branch literals in escalation.go:57–67.

**Test Weakening** — All five files are new. No existing tests were modified. No
weakening possible.

**Test Naming** — All 35 test function names encode the scenario and the expected
outcome clearly. No opaque names (`test_1`, `test_it_works`) found.

**Scope Alignment** — All imports and symbol references (`SeverityCritical`,
`ParseReport`, `BuildFixableBlock`, `Escalator`, `newSecurityCmd`) correspond to code
present in the current implementation files. No orphaned or stale references.

**Test Isolation** — All tests that write files use `t.TempDir()`. Fixture files in
`testdata/` are static committed data, not mutable project state. `filterEnv` in
security_test.go:53 correctly strips `HUMAN_ACTION_FILE` from the subprocess
environment to prevent developer-session contamination. The `buildTekhtonBinary`
helper (security_test.go:23) builds into a temp dir and is guarded by `sync.Once`.

**Implementation Exercise** — Tests call real implementation functions directly.
Mocking is targeted: `fakeHumanAction` in escalation_test.go exercises the
`HumanActionAppender` seam for policy-routing tests while real `drift.HumanAction`
writes are tested separately in `TestNewEscalator_WiresRealHumanAction` and
`TestSecurityHandleUnfixable_EscalateWritesHumanAction`.
