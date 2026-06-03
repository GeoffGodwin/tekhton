## Test Audit Report

### Audit Summary
Tests audited: 1 file, 4 test functions
Verdict: CONCERNS

### Findings

#### ISOLATION: TestRunStage_FullSuccess_ReportParsedAndSaved fails in a clean environment due to path mismatch
- File: internal/stages/cleanup/full_flow_test.go:36
- Issue: `setupProject` (stage_test.go:85) writes the NON_BLOCKING_LOG fixture to
  `dir/.tekhton/NON_BLOCKING_LOG.md`. The stage comment at stage_test.go:80 explains
  this is intended to honor the config default. However, `nonBlockingLogPath` in
  stage.go:252 uses a hardcoded fallback of `"NON_BLOCKING_LOG.md"` — not
  `.tekhton/NON_BLOCKING_LOG.md`. Unlike `cleanupReportPath` (stage.go:259-267), which
  correctly derives its default via `envOr("TEKHTON_DIR", ".tekhton")`, `nonBlockingLogPath`
  ignores `TEKHTON_DIR`. The config default in `internal/config/defaults.go:229` is
  `tdFile("NON_BLOCKING_LOG.md")` = `.tekhton/NON_BLOCKING_LOG.md`.

  In a clean `go test` run where `NON_BLOCKING_LOG_FILE` is not exported by the parent
  process:
  1. `nonBlockingLogPath(dir, req)` resolves to `dir/NON_BLOCKING_LOG.md` (file absent)
  2. `loadNonBlockingDoc` returns an empty Document (ErrNotFound path)
  3. `shouldRun(emptyDoc)`: UnresolvedCount=0, CLEANUP_TRIGGER_THRESHOLD=0 → `0 > 0` = false
  4. `RunStage` returns `verdict=skip, exit_reason="no-trigger"`
  5. Assertion at line 89 (`res.Verdict != proto.VerdictPass`) fires → test fails

  The primary assertions (verdict=pass, ExitReason counts, marker counts in the saved file)
  are unreachable. The test only passes in environments where `NON_BLOCKING_LOG_FILE` is
  already set — e.g. a terminal that sourced `lib/config_defaults.sh`. This is environment
  pollution. The tester's claim of "Passed: 505 (501 shell + 4 new Go) Failed: 0" is
  inconsistent with a clean `go test ./internal/stages/cleanup/...` run.
- Severity: HIGH
- Action: Either (a) fix `nonBlockingLogPath` in stage.go:251-257 to honour TEKHTON_DIR
  consistently with cleanupReportPath (preferred — closes a production defect too):

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

  Or (b) set `NON_BLOCKING_LOG_FILE` in the test:
  - In `setupProject`, add `"NON_BLOCKING_LOG_FILE": ".tekhton/NON_BLOCKING_LOG.md"` to
    `req.EnvOverrides`, or add `t.Setenv("NON_BLOCKING_LOG_FILE", ".tekhton/NON_BLOCKING_LOG.md")`
    in `TestRunStage_FullSuccess_ReportParsedAndSaved` before `setupProject` is called.

  Fix (a) also benefits the pre-existing `TestRunStage_NoEligible` and `TestRunStage_NullRun`
  tests in stage_test.go (out of scope for this audit), which call `setupProject` and share
  the same implicit dependency.

---

#### No Issues Found

The three `subprocessBuildGate` tests are well-constructed:

- **TestSubprocessBuildGate_BinaryNotFound_ReturnsNil** (line 151): Clears TEKHTON_BIN,
  TEKHTON_HOME, and PATH via `t.Setenv`; drives the real `subprocessBuildGate{}.Run`;
  asserts nil error. Self-contained. Assertion is honest — `resolveTekhtonBin` returns ""
  when all three resolution paths are blocked; the implementation short-circuits with `return nil`.
- **TestSubprocessBuildGate_BinaryFoundExitsZero** (line 163): Creates a real `exit 0`
  shell stub via `fakeBinScript`; points `TEKHTON_BIN` at it; asserts nil error. Self-contained.
  Assertion is honest — `cmd.Run()` returns nil on exit 0.
- **TestSubprocessBuildGate_BinaryFoundExitsOne** (line 175): Same pattern with `exit 1`;
  asserts non-nil error. Self-contained. Assertion is honest — `cmd.Run()` returns
  `*exec.ExitError` on non-zero exit.

All three test names encode the scenario and expected outcome. The file adds new tests only
(no modification of existing tests; no weakening). No live project files are read — each
test uses `t.TempDir()` for fixtures and `t.Setenv` for env isolation.
