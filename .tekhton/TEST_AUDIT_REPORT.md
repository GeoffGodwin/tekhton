## Test Audit Report

### Audit Summary
Tests audited: 13 files — `internal/detect/detect_test.go`, `internal/detect/languages_test.go`,
`internal/detect/report_test.go`, `internal/detect/readonly_test.go`,
`cmd/tekhton/detect_test.go`, `tests/test_detect_parity.sh`,
`internal/detect/workspaces_test.go`, `internal/detect/ci_test.go`,
`internal/detect/infrastructure_test.go`, `internal/detect/test_frameworks_test.go`,
`internal/detect/doc_quality_test.go`, `internal/detect/services_test.go`,
`internal/detect/ai_artifacts_test.go`; approximately 95 test functions across Go
and 1 bash parity gate covering 4 fixtures.
Verdict: PASS

### Findings

#### COVERAGE: Most m29.2 detector tests discard error returns from Run()
- File: `internal/detect/workspaces_test.go:37`, `ci_test.go:18`,
  `infrastructure_test.go:12`, `test_frameworks_test.go:12`, `services_test.go:43`,
  `ai_artifacts_test.go:33`, `doc_quality_test.go:13` (and most other sub-tests in
  these files)
- Issue: The pattern `r, _ := SomeDetector{}.Run(context.Background(), ...)` silently
  discards the error return. All eight m29.2 detectors return `nil` error
  unconditionally today, so no test is wrong. However, if any detector adds a
  non-nil error path in the future, these tests will proceed with a nil `r` and
  panic rather than failing with a useful message. `TestServicesDetector_DockerCompose`
  (services_test.go:19) correctly handles the error and should be the model for the
  others.
- Severity: LOW
- Action: Add `if err != nil { t.Fatalf("Run: %v", err) }` after each discarded
  error return, matching the pattern already used in `TestServicesDetector_DockerCompose`.
  No implementation changes needed.

#### COVERAGE: TestDocQualityDetector_RichReadme uses a weak aggregate score bound
- File: `internal/detect/doc_quality_test.go:21-35`
- Issue: The test creates a rich README (> 100 lines, ≥ 3 sections, code block,
  "install" keyword → readme subscore ≈ 25) plus a 40-line CONTRIBUTING.md (contrib
  subscore = 10), yielding a total expected score ≈ 35. The assertion is
  `score < 15`, meaning the test passes as long as the aggregate is ≥ 15. A README
  scorer that returned 0 would still let the test pass if contributing alone scores
  ≥ 15. The sister test `TestDocQualityDetector_ReadmeScoreCapAt30` uses
  `parseSubscore(details, "readme")` directly; that pattern is more precise.
- Severity: LOW
- Action: Replace (or supplement) the aggregate check with
  `parseSubscore(r.Findings[0]["details"], "readme")` and assert `readmeScore >= 20`
  to exercise the README scorer directly.

#### ISOLATION: doc_quality.go reads os.Getenv("DESIGN_FILE") during test execution
- File: `internal/detect/doc_quality.go:161` (affects
  `internal/detect/doc_quality_test.go:82-102`, `doc_quality_test.go:141-158`)
- Issue: `scoreArchitecture` appends `os.Getenv("DESIGN_FILE")` to its candidate-path
  list. If a CI environment has `DESIGN_FILE` set to a real file path (common in
  Tekhton self-hosted runs), the architecture detector evaluates that file in addition
  to the fixture. The tests use lower-bound assertions (`>= 15`, `>= 5`), so they
  remain green even with an extra score contribution, but the pass is
  environment-dependent and the dependency is invisible to the test reader. Note: this
  is NOT a filesystem isolation violation — no mutable pipeline state file is read —
  but it is an implicit environmental coupling.
- Severity: LOW
- Action: Add `t.Setenv("DESIGN_FILE", "")` at the top of
  `TestDocQualityDetector_ArchitectureDoc` and `TestDocQualityDetector_ADRDir` to
  neutralise any ambient value. No implementation changes needed.

None: INTEGRITY, SCOPE, WEAKENING, NAMING, EXERCISE violations — none found.

---

### Per-file notes

**`internal/detect/detect_test.go`** — Engine orchestration tests call the real
Engine via Register/Run/CachedResult/Summary.ProjectType with a minimal `stubDetector`
test double. `ErrLanguagesDetectorMissing` and error propagation are verified via
`errors.Is`. Cache-reset across consecutive `Run()` calls is verified by counting
actual detector invocations (not by inspecting cache internals). No hard-coded magic
values. PASS.

**`internal/detect/languages_test.go`** — All fixture-driven tests use `t.TempDir()`
and the `writeFile` helper; no live project files read. Confidence levels and manifest
names are grounded in `mergeAndScore` and `detectManifests` logic cross-checked against
`languages.go:199-248`. The vendored-noise skip guard (`no manifest && count < 3`) is
verified by `TestMergeAndScore_LowVendoredSkipped`. The CLAUDE.md fallback exercises
the Strategy-1 `**Languages:**` path; strategies 2 and 3 (lower-priority fallbacks)
were already reported as uncovered in the m29.1 audit — no regression introduced here.
PASS.

**`internal/detect/report_test.go`** — `Render()` called with constructed `Summary`
values and asserted against literal strings matching `report.go`'s output format.
`TestRender_FrameworkNoneDetected` correctly checks `"(none detected)"` immediately
after the `### Frameworks` header (no blank line between them), matching
`renderFrameworks`. PASS.

**`internal/detect/readonly_test.go`** — Scans all new m29.2 source files
(`ci.go`, `ai_artifacts.go`, `doc_quality.go`, `workspaces.go`, etc.) in addition to
the m29.1 files. Correctly excludes `_test.go` files, so `writeFixture`'s
`os.WriteFile`/`os.MkdirAll` calls do not false-positive. The empty-Glob guard
(`t.Fatalf` at line 48) prevents a silent miss if the working directory is wrong.
Note: `doc_quality.go` imports `"os"` and uses `os.Getenv` — this is an environment
read (not a write), not in the forbidden-API list, and is correctly not flagged. PASS.

**`cmd/tekhton/detect_test.go`** — All five tests drive the real Cobra command tree
via `newRootCmd()` with `t.TempDir()` fixtures. `TestRegistrationOrder` asserts the
exact 9-detector slice from `registeredDetectors()`, fails red on any reorder.
`TestDetectCmd_BothFlagsRejected`'s `"mutually exclusive"` string check is grounded
in the implementation's error message. PASS.

**`tests/test_detect_parity.sh`** — Drives the real `bin/tekhton` binary against all
four committed fixture directories (`monorepo-pnpm`, `polyglot-services`,
`ai-heavy-mess`, `empty`) using byte-identical diff against frozen baselines.
Self-skips cleanly when the Go toolchain or binary are unavailable. The `actual`
output is written to `mktemp` — no mutable project state is read or written. PASS.

**`internal/detect/workspaces_test.go`** — 8 tests covering pnpm, npm lerna, nx,
Cargo workspace, Gradle multi-project, Maven multi-module, and 2 negative cases.
`TestWorkspacesDetector_CargoTomlWithoutWorkspace` correctly guards against
single-crate Cargo.toml producing a workspace finding. PASS (LOW error-handling note
above applies).

**`internal/detect/ci_test.go`** — 8 tests covering all 6 CI systems plus a
secrets-skipping guard and a second Dockerfile language variant. The secrets-skip test
(`TestCIDetector_SecretsLinesSkipped`) verifies both that the secrets line is absent
AND that the non-secrets command still survives. PASS (LOW error-handling note above).

**`internal/detect/infrastructure_test.go`** — 7 tests covering Terraform (AWS and
GCP provider detection), Pulumi, CDK, CloudFormation, SAM, and Ansible (both
`ansible.cfg` and `playbooks/` detection paths). PASS (LOW error-handling note above).

**`internal/detect/test_frameworks_test.go`** — 10 tests covering pytest, Jest+Vitest
coexistence, go-test (high confidence from source files), cargo-test, rspec, JUnit,
xunit, flutter-test, shell-tests, and bats. PASS (LOW error-handling note above).

**`internal/detect/doc_quality_test.go`** — 8 tests covering missing README (score
0), rich README + CONTRIBUTING, empty dir, OpenAPI API-docs scoring, ARCHITECTURE.md
line-based scoring, ADR dir bonus, CONTRIBUTING subscore cap at 15, all-five-subscores
always-present shape, and README subscore cap at 30. LOW findings above apply. PASS.

**`internal/detect/services_test.go`** — 7 tests covering docker-compose with
tech-stack detection, Procfile parsing, Kubernetes Deployment + Service in `k8s/` and
`deploy/` dirs, k8s deduplication, ConfigMap exclusion, and source-field correctness.
PASS (LOW error-handling note above).

**`internal/detect/ai_artifacts_test.go`** — 16 tests covering all 6 heuristics in
the exact bash order, including known-dirs (Cursor, Windsurf, `.ai/` with and without
config files), known-files (.cursorrules, .windsurfrules, .roomodes), known-globs
(aider, aider history), claude-dir, claude-md, directive markdowns (with and without
sufficient markers), and the ordering invariant via `TestHeuristicOrder` + the
cross-heuristic ordering test. `TestClassifyAITool` verifies 8 path patterns against
the `ClassifyAITool` function directly. PASS (LOW error-handling note above).
