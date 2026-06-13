## Test Audit Report

### Audit Summary
Tests audited: 2 files, 5 test functions (3 Go, 5 bash assertions A–E)
Verdict: PASS

### Findings

#### COVERAGE: Test E grep scope is wider than its description implies
- File: tests/test_gitkeep_fixture_dirs.sh:108
- Issue: `grep -q 'make lint' "$PIPELINE_CONF"` searches the entire pipeline.conf, but the pass/fail message says "ANALYZE_CMD contains 'make lint'". A `make lint` string in a comment or an unrelated variable line would cause a false pass. The intent is clearly to verify the ANALYZE_CMD assignment; the grep should be narrowed to the ANALYZE_CMD line (e.g., `grep -q '^ANALYZE_CMD=.*make lint' "$PIPELINE_CONF"`).
- Severity: LOW
- Action: Tighten the grep pattern to `^ANALYZE_CMD=.*make lint` so the test only passes when the assignment itself contains the string, not a comment elsewhere in the file.

#### ISOLATION: Tests A–D check committed fixture assets, not runtime artifacts — acceptable by design
- File: tests/test_gitkeep_fixture_dirs.sh:44–102
- Issue: Tests A–D read real paths inside `internal/diagnose/testdata/fixtures_v3/` and `tests/fixtures/qwen_local_smoke/`. These are git-committed fixture assets, not pipeline-run artifacts (no CAUSAL_LOG, no BUILD_ERRORS, no RUN_SUMMARY). They fail precisely because the coder has not yet created the `.gitkeep` files — which is the correct acceptance-test behavior for TDD: red before green. The tester accurately reports all five failures and does not claim false passes. No isolation problem; this is the intended signal.
- Severity: LOW
- Action: No change required. Note added for documentation.

#### EXERCISE: Go tests call real Engine.ReadContext and Helpers.CollectAgentLogTails implementations
- File: internal/diagnose/gitkeep_inert_test.go:19, 54, 79
- Issue: None — positive finding. Each Go test constructs its own temp dir, places exactly the files it needs, and calls the real production code. `TestGitkeepInert_ReadContextNoState` correctly verifies the `hasState` path by controlling all four state-file env vars via `t.Setenv`. `TestGitkeepInert_CollectAgentLogTails` and `_Mixed` directly exercise the `logFileBasenameRe` (`\.log$`) filter in helpers.go:114. Assertions check real outputs from real function calls.
- Severity: N/A
- Action: No action required.

#### COVERAGE: No error-path test for CollectAgentLogTails when logDir is unreadable
- File: internal/diagnose/gitkeep_inert_test.go
- Issue: All three Go tests exercise the success path (directory exists, readable). The `!st.IsDir()` branch (helpers.go:195) and the `os.ReadDir` error branch (helpers.go:201) are not covered. Both return an empty map, which is the correct bash-parity behavior and low risk; adding a test where `logsDir` is a file rather than a directory would close the gap.
- Severity: LOW
- Action: Optional follow-up. Not required for this milestone.

---

## Planned Tests
- [x] `tests/test_gitkeep_fixture_dirs.sh` — verify all 16 .gitkeep files exist, are not gitignored, and pipeline.conf has make lint
- [x] `internal/diagnose/gitkeep_inert_test.go` — verify .gitkeep in agent_logs/ does not affect no-state verdict (behavioral-inertness claim)

## Test Run Results
Passed: 3  Failed: 5

### test_gitkeep_fixture_dirs.sh — 0 PASS, 5 FAIL
Tests A–E: ALL FAIL. The Coder has not implemented m25.
- A: 15 of 15 `inputs/agent_logs/.gitkeep` files missing (none created)
- B: `tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep` missing
- C: total count 0 of 16 required .gitkeep files
- D: skipped (depends on A)
- E: `.claude/pipeline.conf` ANALYZE_CMD still reads `shellcheck …` only — `make lint` not appended

### internal/diagnose/gitkeep_inert_test.go — 3 PASS (NEW)
Tests: TestGitkeepInert_ReadContextNoState, TestGitkeepInert_CollectAgentLogTails,
TestGitkeepInert_CollectAgentLogTailsMixed. ALL PASS. The behavioral-inertness
claim (`.gitkeep` skipped by `\.log$` filter in `CollectAgentLogTails`, and not
triggering `hasState=true` in `ReadContext`) is confirmed by the existing code.

### Full suite — 507 Shell PASS, 1 Shell FAIL (test_gitkeep_fixture_dirs.sh), Go PASS
No regressions. The only failure is the new m25 acceptance test.

## Bugs Found
- BUG: [internal/diagnose/testdata/fixtures_v3/*/inputs/agent_logs] all 15 .gitkeep files are missing — fresh-clone CI failure not fixed
- BUG: [tests/fixtures/qwen_local_smoke/.claude/logs] .gitkeep missing — same empty-dir trap class as diagnose fixtures
- BUG: [.claude/pipeline.conf:51] ANALYZE_CMD does not contain `make lint` — m25 Goal 3 not applied

## Missing Deliverables (not testable locally — lint arbiter is CI-pinned v1.64.5)
- `internal/diagnose/engine_test.go:230,265,294,318` — orphaned `materializeFixture`, `mapFixturePath`, `readExpected`, `findTekhtonHome` not deleted; golangci-lint `unused` findings remain
- `internal/diagnose/rules/helpers.go:83,91,109` — `pathFromEnvOr`, `containsLineMatching`, `countLinesMatching` not deleted
- `internal/diagnose/rules/resilience.go:310` — `projectFilePath` not deleted
- All other 31-item burn-down fixes (errcheck, ineffassign, gosimple, staticcheck) not applied; local golangci-lint v1.62.2 errors on typecheck before reaching these

## Files Modified
- [x] `tests/test_gitkeep_fixture_dirs.sh`
- [x] `internal/diagnose/gitkeep_inert_test.go`

## Timing
- Test executions: 4
- Approximate total test execution time: 90s
- Test files written: 2
