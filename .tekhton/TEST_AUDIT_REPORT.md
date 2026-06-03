## Test Audit Report

### Audit Summary
Tests audited: 1 file, 4 test functions
- `TestRunStage_FullSuccess_ReportParsedAndSaved` (full_flow_test.go:36)
- `TestSubprocessBuildGate_BinaryNotFound_ReturnsNil` (full_flow_test.go:151)
- `TestSubprocessBuildGate_BinaryFoundExitsZero` (full_flow_test.go:163)
- `TestSubprocessBuildGate_BinaryFoundExitsOne` (full_flow_test.go:175)

Verdict: CONCERNS

### Findings

#### ISOLATION: Full-success test pass/fail depends on ambient NON_BLOCKING_LOG_FILE
- File: `internal/stages/cleanup/full_flow_test.go:36`
- Issue: `TestRunStage_FullSuccess_ReportParsedAndSaved` calls `setupProject(t, 5)`,
  which writes the fixture document to `dir/.tekhton/NON_BLOCKING_LOG.md`
  (stage_test.go:85). The stage resolves the path via `nonBlockingLogPath`
  (stage.go:251–257):

  ```go
  name := envOrFromReq(req, "NON_BLOCKING_LOG_FILE", "NON_BLOCKING_LOG.md")
  ```

  The hardcoded fallback is `"NON_BLOCKING_LOG.md"` — not `.tekhton/NON_BLOCKING_LOG.md`.
  Neither the test (full_flow_test.go:37–39) nor `setupProject` (stage_test.go:97–108)
  sets `NON_BLOCKING_LOG_FILE` in the env or in `req.EnvOverrides`, so the fallback applies.
  In a clean `go test` environment the call chain is:

  1. `nonBlockingLogPath(dir, req)` → `dir/NON_BLOCKING_LOG.md` (file not present)
  2. `loadNonBlockingDoc` → empty Document (ErrNotFound handled silently at stage.go:241–244)
  3. `shouldRun(emptyDoc)` → `UnresolvedCount=0`, `CLEANUP_TRIGGER_THRESHOLD=0` → `0 > 0 = false`
  4. `RunStage` returns `verdict=skip, exit_reason="no-trigger"`
  5. Line 89 assertion `res.Verdict != proto.VerdictPass` fires → test FAILS

  All downstream assertions (ExitReason counts, agent/gate call counts, saved-file marker
  counts at lines 94–131) are unreachable. The test can only pass when `NON_BLOCKING_LOG_FILE`
  is already present in the shell environment — for example a developer session that has
  sourced `lib/config_defaults.sh` or a CI runner that sets pipeline env vars before
  invoking `go test`. This is environment pollution.

  Note: the same ambient dependency exists in `TestRunStage_NullRun` (stage_test.go:180,
  out of audit scope) — all `shouldRun`-sensitive tests share the gap, suggesting CI does
  supply the var and masked it. The tester's claim of "Passed: 505 (501 shell + 4 new Go)
  Failed: 0" cannot be reproduced in a clean environment.

  Also note: `cleanupReportPath` (stage.go:259–267) correctly constructs its default via
  `envOr("TEKHTON_DIR", ".tekhton")`, placing the report in `.tekhton/CLEANUP_REPORT.md`.
  `nonBlockingLogPath` is inconsistent — it does not consult `TEKHTON_DIR` at all, making
  the production default diverge from where the pipeline places the file.
- Severity: HIGH
- Action: Preferred fix — bring `nonBlockingLogPath` into consistency with
  `cleanupReportPath` by consulting `TEKHTON_DIR` (stage.go:251–257):

  ```go
  func nonBlockingLogPath(projectDir string, req *proto.StageRequestV1) string {
      tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
      name := envOrFromReq(req, "NON_BLOCKING_LOG_FILE",
          filepath.Join(tekhtonDir, "NON_BLOCKING_LOG.md"))
      if filepath.IsAbs(name) {
          return name
      }
      return filepath.Join(projectDir, name)
  }
  ```

  This closes both the production defect (wrong default path) and the test isolation
  gap simultaneously. Alternative: add `"NON_BLOCKING_LOG_FILE": ".tekhton/NON_BLOCKING_LOG.md"`
  to `setupProject`'s `req.EnvOverrides` in stage_test.go:97, which fixes the test without
  touching the production code — but leaves the production default wrong.

---

#### COVERAGE: TEKHTON_HOME binary resolution path not exercised by subprocess gate tests
- File: `internal/stages/cleanup/full_flow_test.go:151–182`
- Issue: `resolveTekhtonBin` (stage.go:218–234) has three resolution branches:
  `TEKHTON_BIN` stat, `TEKHTON_HOME/bin/tekhton` stat, and `exec.LookPath`.
  The three new tests cover the "all paths empty → nil error" case and the
  `TEKHTON_BIN` stat path (via `fakeBinScript`). Neither `TEKHTON_HOME` nor
  `exec.LookPath` is exercised. A defect in the `filepath.Join(home, "bin", "tekhton")`
  join (stage.go:225) would not be caught. The gap in `resolveTekhtonBin` itself is
  already partially covered by `TestResolveTekhtonBin_NotFound` and
  `TestResolveTekhtonBin_FromEnv` (helpers_test.go, out of audit scope), but those
  tests don't drive it through the subprocess gate's full Run path.
- Severity: LOW
- Action: Add a subprocess gate test that writes a fake binary to `<tmpdir>/bin/tekhton`,
  sets `TEKHTON_BIN=""` and `TEKHTON_HOME=<tmpdir>`, and asserts `gate.Run() == nil`.

---

### No Issues Found

The following rubric points are clean across all four test functions:

**Assertion Honesty** — All assertions derive from real implementation behavior.
`resolved=2` / `deferred=1` in ExitReason trace to the `fmt.Sprintf("resolved=%d
deferred=%d", res.Resolved, res.Deferred)` at stage.go:142, with counts produced by
`parseReport` → `notes.MarkResolved` / `notes.MarkDeferred` applied to the fixture
CLEANUP_REPORT.md content. The `[x]` / `[DEFERRED]` / `[ ]` marker counts verify
real state transitions via `Note.SetState` → `serialize()`. No hard-coded magic values.

**Test Weakening** — No existing tests were modified. No weakening found.

**Test Naming** — All four names encode the scenario and the expected outcome clearly.

**Scope Alignment** — Tests target `cleanup.RunStage` and `subprocessBuildGate`, both
present in the current codebase. No stale symbol references. The tests fill the
reviewer-identified gaps in m34.2 coverage; this is legitimate even though the coder
implemented nothing in the current run.

**Implementation Exercise** — `TestRunStage_FullSuccess_ReportParsedAndSaved` calls the
real `RunStage` entry point; agent and build gate are seamed (appropriate — real
infrastructure not available in unit tests). The three subprocess gate tests call
`subprocessBuildGate.Run` directly with real shell scripts and zero mocking.

**Test Isolation (subprocess gate tests)** — All three subprocess gate tests control
every external dependency via `t.Setenv` and `t.TempDir`. No ambient env state required.
