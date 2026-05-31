## Test Audit Report

### Audit Summary
Tests audited: 10 files (8 `internal/crawler/*_test.go`, 1 `cmd/tekhton/crawler_test.go`,
1 `tests/test_crawler_parity.sh`), 51 Go test functions + 21 shell parity assertions.
Verdict: PASS

---

### Findings

#### COVERAGE: `extractWithHeader` single-line collapsed-section edge case untested
- File: `internal/crawler/deps_test.go` (no specific line — gap in test matrix)
- Issue: `extractWithHeader` in `deps.go:38-45` has an explicit branch for a section
  whose opening brace appears on the same line as the key (`"dependencies": {}`). When
  that condition fires, the function emits the header line and immediately resets
  `inSection = false`. No test in `deps_test.go` exercises this path — all fixtures use
  multi-line sections where the closing `}` is on its own line. The coder explicitly
  called out `extractWithHeader` as a bash-parity quirk; the collapsed-section variant
  is the branch most likely to be "fixed" by a well-meaning future editor who doesn't
  know it needs to be preserved.
- Severity: MEDIUM
- Action: Add a `TestExtractWithHeaderCollapsedSection` test that calls
  `extractWithHeader` directly on a mini package.json string like
  `{"dependencies":{}}` (collapsed brace) and asserts (a) the header line is emitted
  once and (b) `countDepLines` returns 1, not 0 or more.

#### COVERAGE: `inventory` and `content` CLI subcommands have no functional smoke test
- File: `cmd/tekhton/crawler_test.go` (gap — no test for `inventory` or `content` subcommands)
- Issue: `TestCrawlerHelpListsSubcommands` confirms `inventory` and `content` appear in
  `--help` output, but no test actually invokes either subcommand with `--project-dir`
  and `--json` to validate its output. The `crawl` and `deps` subcommands each have a
  dedicated functional test (`TestCrawlerCrawlJSONOutput`, `TestCrawlerDepsJSON`). If
  the Cobra wiring, flag parsing, or JSON serialisation for `inventory` or `content`
  regresses, no test catches it.
- Severity: MEDIUM
- Action: Add `TestCrawlerInventoryJSON` and `TestCrawlerContentJSON` in
  `cmd/tekhton/crawler_test.go`, mirroring the pattern in `TestCrawlerDepsJSON` — create
  a temp dir with a minimal project, invoke the subcommand with `--project-dir ... --json`,
  assert the output parses as valid JSON and contains the expected top-level key(s).

#### NAMING: `min` helper in tree_test.go shadows Go 1.21+ built-in
- File: `internal/crawler/tree_test.go:69`
- Issue: `func min(a, b int) int` is defined at package scope in a test file. Go 1.21
  added `min` as a built-in; since this package targets Go 1.22+ (CLAUDE.md), the
  definition shadows the built-in across the entire `package crawler` test scope.
  `golangci-lint` will flag this. The only use is at `tree_test.go:56`:
  `got[:min(40, len(out))]`.
- Severity: LOW
- Action: Rename the helper to `minInt` or inline the ternary directly at its single
  call site.

#### EXERCISE: `TestCrawlerCrawlJSONOutput` merges stdout and stderr into one buffer
- File: `cmd/tekhton/crawler_test.go:57-58`
- Issue: `root.SetOut(&out)` and `root.SetErr(&out)` both point at the same buffer.
  If any diagnostic or Cobra error text appears on stderr, `json.Unmarshal(out.Bytes(), &got)`
  fails with a confusing JSON-parse error instead of a clear failure pointing at the root
  cause. The tests pass today because no such output is produced, but the fragility is
  latent (e.g., a future warning on stderr from the binary would cause a misleading
  failure).
- Severity: LOW
- Action: Use separate buffers (`var stdout, stderr bytes.Buffer`). Unmarshal only
  `stdout.Bytes()`. Optionally assert `stderr.String() == ""` to make unexpected stderr
  output an explicit failure.

---

### Absence of findings in other categories

**INTEGRITY — none.** Every expected value in the suite is derived from the implementation:
- `annotatePackage` expected strings cross-checked against `packagePurposes` /
  `packagePurposeGlobs` in `annotations.go` — all correct.
- `TestParseNodeDepsSimple` expects `Deps == 3` for a 2-dependency `package.json`. This
  is not a hard-coded magic number: `extractWithHeader` emits the section-header line
  (`"dependencies": {`) which `countDepLines` counts because it contains `:`. The test
  comment explains this explicitly. It is an honest assertion of intentional bash-parity
  behavior, not an integrity violation.
- `emitMetaJSON` / `emitInventoryJSONL` exact byte-shape assertions in `emit_test.go`
  were traced against the hand-rolled string-builders in `emit.go` and are correct.

**WEAKENING — none.** `tests/test_rescan.sh` was skip-stubbed at m30.1. This is correct:
the underlying bash rescan helpers were deleted as part of this milestone. Removing tests
for deleted code is the right action.

**SCOPE — none.** All function references (`annotatePackage`, `isBinary`, `readSampled`,
`sampleFiles`, `Crawl`, `ErrMissingProjectDir`, `parseDependencies` family, all `emit*`
functions, `buildFileInventory`, `buildConfigInventory`, `isTestFile`, `isTestDirName`,
`configPurpose`, `sizeCategory`, `annotateLine`, etc.) verified against current
implementation files — all present and aligned.

**ISOLATION — none.** All Go tests use `t.TempDir()` for project fixtures. The
`recordingWriter` fake in `emit_test.go` never touches the real filesystem. `readonly_test.go`
reads the package's own source files at test time; these are version-controlled sources,
not mutable pipeline artifacts, and this pattern is correct for a static-contract
enforcement test.

**Parity gate (`tests/test_crawler_parity.sh`) — properly structured.** Self-skips
cleanly when the Go binary is not built (exits 0). Uses `mktemp` for all actual output.
Reads only from version-controlled fixture directories and frozen baselines. Normalises
volatile `scan_date` / `scan_commit` fields before diffing. 21 assertions = 3 fixtures
× 7 artifacts, byte-level equality — the strongest parity test appropriate for a
port milestone. Registered in `run_tests.sh` via the `tests/test_*.sh` glob.
