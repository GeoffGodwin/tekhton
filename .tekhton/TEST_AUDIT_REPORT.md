## Test Audit Report

### Audit Summary
Tests audited: 5 files, 23 test functions
(2 modified-this-run: `tests/test_m33_milestone_structure.sh`, `internal/dashboard/coverage_test.go`;
3 freshness-sample: `cmd/tekhton/dashboard_test.go`, `internal/detect/readonly_test.go`, `internal/detect/report_test.go`)

Verdict: CONCERNS

---

### Findings

#### ISOLATION: test_m33_milestone_structure.sh reads live mutable milestone files
- File: `tests/test_m33_milestone_structure.sh:54-57`
- Issue: The test binds directly to `$MILESTONE_DIR/m33-dashboard-port.md`, `m33.1-dashboard-emitters.md`, `m33.2-dashboard-parsers.md`, and `MANIFEST.cfg` — all live, writable project files managed by the finalize orchestrator. `MANIFEST.cfg` is updated on every milestone completion; milestone `.md` files are deleted when a milestone closes. The test's pass/fail outcome is therefore coupled to current pipeline state, not a stable fixture. Running this test after m33.1 closes (finalize advances its status to `done`) will cause the `status: "todo"` checks in AC1 and AC2 to fail with no code change whatsoever. By the rubric this is a Severity HIGH isolation violation.
- Severity: HIGH
- Action: Copy the milestone files and the relevant MANIFEST rows into a controlled fixture directory under `tests/fixtures/m33_structure/` at test setup. Drive all grep/awk calls against the fixture copies. When both milestone children are absent from the working tree (arc closed), emit a SKIP line and exit 0 instead of failing.

#### INTEGRITY: Unconditional pass() on line 220 always fires regardless of prior check outcome
- File: `tests/test_m33_milestone_structure.sh:220`
- Issue: `pass "m33 parent status verified via meta block (split)"` is called unconditionally — there is no enclosing `if`. If both prior conditional blocks in Suite 6 (lines 195–215) produce `fail` (parent file absent AND MANIFEST has no `done` row), this line still increments `PASS` and emits a message claiming verification succeeded. The result is an inflated pass count and a misleading audit trail without flipping the suite exit code (since `FAIL > 0` still triggers `exit 1`). This is structurally identical to `assertTrue(True)` — it cannot fail regardless of real state. The comment above ("positive check above is sufficient") describes the intent to remove a redundant negative check, but the implementation is an always-true stub.
- Severity: MEDIUM
- Action: Delete line 220. The two guarded blocks in Suite 6 are the real assertions. If a third confirmation pass is desired, move it inside the successful branch of one of the two conditional blocks rather than calling it unconditionally.

#### COVERAGE: cmd/tekhton/dashboard_test.go behavioral tests cover only init and run-state
- File: `cmd/tekhton/dashboard_test.go:27-93`
- Issue: Two of the four tests exercise only `--help` output (Cobra string matching, no I/O or filesystem state). Only `TestDashboardInit_CreatesDataDir` and `TestDashboardEmitRunState_WritesValidJSON` exercise real behavior. `cleanup`, `sync`, and all emit kinds beyond `run-state` have no behavioral test at the `cmd` layer. The gap is specifically flag-wiring and the subprocess path for the other subcommands.
- Severity: LOW
- Action: Add one behavioral test each for `dashboard cleanup` (verifies data dir removal) and `dashboard sync` (verifies data dir is re-created). No need to add per-emit-kind behavioral tests at the `cmd` layer since `internal/dashboard/*_test.go` already exercises those paths directly.

---

### Files with No Findings

**`internal/dashboard/coverage_test.go`** — All five test functions call real implementations
with proper `t.TempDir()` isolation. Assertions are honest: values checked in JSON output
(`"code_dominant"`, `"security"`, `"auth module"`) are all derived from fixture data passed
into real function calls, not hardcoded against implementation internals. `TestWriteJSFile_ConcurrentAtomicity`
correctly verifies the tempfile+rename atomicity guarantee by checking that every non-empty
read starts with the generated header before attempting JSON parsing. `TestEmitTeamState_DelegatesToEmitRunState`
accurately documents the nil-map safety assumption for stage-level team maps and verifies both
`parallel_mode:true` and the team key in JSON output. No issues.

**`cmd/tekhton/dashboard_test.go`** — Four tests; the two `--help` smoke tests and the two
behavioral tests all use `t.TempDir()` and real command execution. Assertions against seed file
names match the `seedFiles` slice in `dashboard.go` exactly. The `"pipeline_status":"running"`
assertion in `TestDashboardEmitRunState_WritesValidJSON` is derived from the real implementation
path (`envOr("PIPELINE_STATUS", "running")` with no env var set in test). Low behavioral
coverage noted above but no integrity issues.

**`internal/detect/readonly_test.go`** — Policy enforcement test that reads package source files
(stable between test runs; not mutable run artifacts). The trailing-`(` anchoring of forbidden
patterns is correct: it prevents doc-comment references to the APIs from tripping the check.
Excluding `_test.go` files from the scan is appropriate. No issues.

**`internal/detect/report_test.go`** — Three honest tests against `Render()` with in-memory
`Summary` structs. `TestRender_FrameworkNoneDetected` traverses output lines to verify the
`(none detected)` line is immediately after the `### Frameworks` header — a precise structural
assertion. Perfect isolation, no file I/O. No issues.
