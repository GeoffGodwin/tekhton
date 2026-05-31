## Test Audit Report

### Audit Summary
Tests audited: 8 files, 56 test functions
- `internal/crawler/rescan_test.go` — 16 functions (primary — modified this run)
- `internal/crawler/changes_test.go` — 7 functions (freshness sample)
- `internal/crawler/significance_test.go` — 2 functions (freshness sample)
- `internal/crawler/emit_test.go` — 8 functions (freshness sample)
- `internal/crawler/deps_test.go` — 10 functions (freshness sample)
- `internal/crawler/metadata_test.go` — 9 functions (freshness sample)
- `cmd/tekhton/crawler_test.go` — 4 functions
- `tests/test_crawler_parity.sh` — 1 bash parity gate (3 fixture × 7 artifact runs)

Verdict: PASS

---

### Findings

#### NAMING: Dead helper never invoked
- File: `internal/crawler/rescan_test.go:435`
- Issue: `ensureGitAvailable(t *testing.T)` is defined at package scope but called by
  no test function in the file. The git-availability guard is already embedded in
  `gitInit` (called transitively by `setupRescanRepo`), so this helper is unreachable
  dead code. It misleads future contributors into thinking an explicit skip guard is
  active somewhere it is not.
- Severity: LOW
- Action: Remove `ensureGitAvailable` (lines 435–440). The guard path is covered by
  `gitInit` in `changes_test.go:94-97`.

#### COVERAGE: Non-git sentinel branch assertion underspecified
- File: `internal/crawler/rescan_test.go:176` (`TestRescanBranchScanCommitNonGit`)
- Issue: The test only asserts `r.Mode == "full"`. It does not assert `FallbackReason`
  content. The implementation groups the `"non-git"` sentinel with the empty-scan-commit
  path at `rescan.go:154`, emitting FallbackReason `"no scan commit recorded"`. Because
  `TestRescanBranchNoScanCommit` (line 162) also expects mode="full" with the same reason,
  the two tests are indistinguishable by their assertions — neither proves the
  `lastScanCommit == "non-git"` arm specifically fires. An accidental reordering of the
  sentinel check would not be caught.
- Severity: LOW
- Action: Add `if !strings.Contains(r.FallbackReason, "no scan commit") { t.Errorf(...) }`
  to `TestRescanBranchScanCommitNonGit`, mirroring the pattern in
  `TestRescanBranchNoScanCommit`.

#### COVERAGE: rescan_scenarios fixture directories untested by any gate
- File: `tests/test_crawler_parity.sh` (gap)
- Issue: `internal/crawler/testdata/rescan_scenarios/{no_changes,trivial,moderate_manifest,
  major_manifest}/` exist as versioned fixture directories but are referenced by no test
  in the audited file set. The parity gate only exercises `tekhton crawler crawl` (not
  `rescan`) against three fixtures. The Go rescan unit tests build ad-hoc git repos via
  `setupRescanRepo` rather than using these fixtures, so the scenario directories are
  currently dead test data.
- Severity: LOW
- Action: Either (a) add a `test_rescan_parity.sh` gate that runs `tekhton crawler rescan
  --json` against each scenario and asserts expected `mode`/`significance` in the JSON
  output, or (b) remove the scenario directories if the Go unit tests are considered
  sufficient. Current Go coverage of the rescan branches is adequate — this is
  documentation/fixture debt, not a correctness gap.

---

### No Issues Found In

**INTEGRITY — none.** All assertions test real behavior derived from implementation
logic. The `"major structural changes detected"` string checked in
`TestRescanBranchMajorTriggersFullCrawl` (`rescan_test.go:231`) matches the literal
passed to `rescanFallToFull` at `rescan.go:177`. The dep-count `Deps == 3` assertion in
`deps_test.go:47` is explicitly explained by the `extractWithHeader` bash-parity
counting quirk documented in the test comment. The `emitMetaJSON` byte-shape assertion
in `emit_test.go:165-178` was verified against the hand-rolled template in `emit.go`
and is correct.

**WEAKENING — none.** The two cycle-2 tester additions both strengthen existing tests:
- `TestRescanBranchTrivialIncremental` (lines 279-281): added `manifest.json` in the
  `wrote` map assertion. Previously the test verified inventory/meta but not samples.
  Now it verifies samples regenerate when a sampled file is modified — matches the
  `regen.samples = true` path at `rescan.go:285-291`.
- `TestRescanBranchMajorTriggersFullCrawl` (lines 232-234): added FallbackReason
  assertion. This is a new positive assertion, not a relaxation of an existing one.
  No prior assertions were removed or broadened anywhere in the file.

**SCOPE — none.** All function references cross-checked against current implementation
files. `Rescan`, `ErrMissingProjectDir`, `ClassifyChanges`, `DetectChangedFiles`,
`ExtractScanMetadata`, `ExtractSampledFiles`, `IsManifestFile`, `IsConfigFile`,
`sampledFileTouched`, `highPriorityAdded`, `fileExists`, `gitCommitExists`, `isGitRepo`,
`parseDiffNameStatus`, `parsePorcelain`, `newRegenSetWithIndexDir`, `recordingWriter`,
all `emit*` functions — all present in the current package with matching signatures.
No test references `rescan_stub.go` (replaced) or any deleted bash function.

**EXERCISE — none.** All Go tests call real package functions. The `recordingWriter` in
`emit_test.go` is a purposeful test double for the `Writer` interface that enforces the
write-only-to-IndexDir safety invariant by returning an error on out-of-prefix writes
(`emit_test.go:38-43`). Tests for `Rescan` that take the full-crawl path (e.g.,
`TestRescanBranchMajorTriggersFullCrawl`) use the default `fsWriter{}` and run the real
`Crawl` implementation against the temp project.

**ISOLATION — none.** All Go tests create fixtures with `t.TempDir()`. The parity shell
test writes to `mktemp -d` with `trap 'rm -rf "${WORK}"' EXIT` and reads only from
version-controlled fixture and baseline directories. No test reads mutable pipeline
artifacts (`.tekhton/CODER_SUMMARY.md`, `.tekhton/BUILD_ERRORS.md`, `.claude/logs/*`,
or similar run-state files).

**PARITY GATE — properly structured.** `tests/test_crawler_parity.sh` self-skips when
the Go binary is not built (exits 0 with a SKIP message). Normalises volatile fields
(`scan_date`, `scan_commit`) before byte-diffing. Asserts 21 artifact pairs (3 fixtures
× 7 artifacts). Uses the `parity_assert_equal` / `parity_summary` harness from
`tests/lib/parity.sh`. Both `parity.sh` and `normalize_index.sh` confirmed present.
