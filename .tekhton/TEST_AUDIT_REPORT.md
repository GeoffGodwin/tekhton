## Test Audit Report

### Audit Summary
Tests audited: 9 files, 36 Go test functions + 3 shell parity assertions
Verdict: PASS

### Findings

#### COVERAGE: claudeMDFallback strategy 2 and 3 paths have no test coverage
- File: internal/detect/languages_test.go (TestLanguagesDetector_ClaudeMDFallback)
- Issue: `TestLanguagesDetector_ClaudeMDFallback` exercises only Strategy 1 — the
  `**Languages:**` structured-list block (`claudeMDStrategy1` at languages.go:395).
  `claudeMDStrategy2` (scanning a `## Project Identity` section for bullet-listed
  languages, languages.go:422) and `claudeMDStrategy3` (regex-anywhere sweep across
  the full CLAUDE.md body, languages.go:445) have zero test coverage. Both are real
  user-visible fallbacks invoked when Strategy 1 finds nothing — a CLAUDE.md without
  the structured header triggers them silently. All three strategies exist as
  separate functions; only Strategy 1 is reachable by the current test fixture.
- Severity: MEDIUM
- Action: Add two tests to `internal/detect/languages_test.go`:
  (a) `TestLanguagesDetector_ClaudeMD_Strategy2` — CLAUDE.md with a
      `# Project Identity` section followed by language bullets but no
      `**Languages:**` header. Assert detected languages use Manifest="CLAUDE.md"
      and Confidence="low".
  (b) `TestLanguagesDetector_ClaudeMD_Strategy3` — CLAUDE.md with language names
      scattered inline (no structured header, no `## Project Identity` section).
      Assert the regex sweep detects them at Confidence="low".

#### COVERAGE: TestMergeAndScore_SortByRank does not explicitly assert got[2].Name
- File: internal/detect/languages_test.go:166
- Issue: `got[1].Name != "go" || got[1].Name >= got[2].Name` verifies that the
  first medium-confidence entry is "go" and that alphabetical ordering holds, but
  never directly asserts `got[2].Name == "python"`. The test is logically correct
  (len == 3 is asserted at line 162, so got[2] can only be "python"), but a future
  reader must reconstruct that chain of reasoning rather than reading a direct
  assertion.
- Severity: LOW
- Action: Add `if got[2].Name != "python" { t.Errorf("expected python as second
  medium entry; got %q", got[2].Name) }` after the existing got[1] check.

None: No other issues found. Per-file summary:

- `internal/detect/detect_test.go` — five tests call the real Engine through
  Register/Run/CachedResult/Summary.ProjectType with stubDetector as a minimal
  test double. ErrLanguagesDetectorMissing and error propagation asserted via
  errors.Is; cache-reset verified by counting actual invocations. No hard-coded
  magic values. PASS.

- `internal/detect/languages_test.go` — all fixture-driven tests use t.TempDir()
  and the writeFile helper; no live project files read. Confidence levels and
  manifest names are grounded in mergeAndScore and detectManifests logic. The
  vendored-noise skip guard (no manifest, count < 3) is verified. MEDIUM and LOW
  coverage gaps noted above. PASS otherwise.

- `internal/detect/report_test.go` — Render() called with constructed Summary
  values and asserted against literal strings from report.go. TestRender_FrameworkNone
  Detected correctly checks "(none detected)" immediately after "### Frameworks"
  (no blank line between them) — matches renderFrameworks in report.go:53-64. PASS.

- `internal/detect/readonly_test.go` — reads the package's own stable source
  files via os.Getwd() (standard Go contract-test pattern; source files are not
  mutable pipeline run artifacts). _test.go files are correctly excluded, so the
  os.WriteFile call in languages_test.go:writeFile does not false-positive. The
  empty-Glob guard at line 48 (t.Fatalf) prevents a silent miss if the working
  directory is wrong. PASS.

- `cmd/tekhton/detect_test.go` — all four tests drive the real Cobra command tree
  via newRootCmd() with t.TempDir() fixtures. The "mutually exclusive" assertion in
  TestDetectCmd_BothFlagsRejected is grounded: detect.go:64 returns
  errExitCode{err: fmt.Errorf("--json and --markdown are mutually exclusive")},
  and errExitCode.Error() delegates to e.err.Error() (errors.go:18-22), so
  strings.Contains(err.Error(), "mutually exclusive") is an honest check. PASS.

- `tests/test_detect_parity.sh` — drives the real bin/tekhton binary against three
  checked-in fixture directories using byte-identical diff. _extract_sections limits
  comparison to the three m29.1-ported sections; this scope is correctly documented
  and the gate will broaden in m29.2. Cleanly self-skips when toolchain or binary
  are unavailable. PASS.

- `internal/dashboard/parse_intake_test.go` (freshness sample) — testdata fixtures
  are static checked-in files; mutable-content tests use t.TempDir(). PASS.

- `internal/dashboard/parse_reviewer_test.go` (freshness sample) — same pattern.
  PASS.

- `internal/dashboard/parse_security_test.go` (freshness sample) — the hard-coded
  count of 5 findings in TestParseSecurity_Golden is grounded in the fixture file
  (4 Findings + 1 Resolved Finding per inline comment). detectSeverity ordering
  verified via table-driven cases including the CRITICAL-before-HIGH precedence
  rule. PASS.
