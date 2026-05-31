## Test Audit Report

### Audit Summary
Tests audited: 2 files, 17 test functions (4 new top-level tests with 37 subtests in engine_readers_test.go; 3 new functions in diagnose_test.go)
Verdict: PASS

---

### Findings

#### COVERAGE: CLI test asserts wiring only, not classification correctness
- File: cmd/tekhton/diagnose_test.go:237 (`TestDiagnoseRun_PopulatedFixtureOutputsClassification`)
- Issue: The test materializes a real `LAST_FAILURE_CONTEXT.json` fixture and verifies the CLI
  emits `Classification:`, `Confidence:`, and `Stage:` header lines — but intentionally does not
  assert specific values. When `TEKHTON_HOME` is absent the engine falls through to `UNKNOWN`;
  when it is present the bash rules fire and the result is silently accepted regardless of value.
  This exercises CLI plumbing but not diagnostic accuracy on the populated-fixture path.
  The scope boundary is correctly documented in the test comment ("The test does not assert a
  specific classification because the BashRuleAdapter requires a resolvable TEKHTON_HOME…").
  Diagnostic accuracy on a real populated fixture is covered by
  `TestBashAdapterIntegration_MaxTurnsCoder` in `engine_test.go` (outside the audit boundary).
- Severity: LOW
- Action: No change required now. If `TestBashAdapterIntegration_MaxTurnsCoder` is ever removed,
  strengthen this test to assert a specific `Classification: UNKNOWN` when `TEKHTON_HOME` is
  unset so the CLI-accuracy signal is not lost.

#### COVERAGE: `extractKVLine` block-delimiter line not tested directly
- File: internal/diagnose/engine_readers_test.go:302 (`TestExtractKVLine`)
- Issue: `parseCauseBlock` splits its extracted block on `\n` and feeds each resulting line —
  including the opening `{` character — to `extractKVLine`. The behaviour for bare `{` and `}`
  inputs is implicitly exercised by every `TestParseCauseBlock` case, but `TestExtractKVLine`
  has no explicit row for these inputs. The implementation's `"([a-z_]+)"\s*:` key regex
  correctly returns `false` for them, making this a documentation gap rather than a correctness risk.
- Severity: LOW
- Action: Optional. Add two rows to the `TestExtractKVLine` table to document the contract:
  `{name: "opening brace", line: "{", wantOK: false}` and
  `{name: "closing brace", line: "  }", wantOK: false}`. Not blocking.

---

### No Issues Found In

**INTEGRITY — none.** All expected values in `engine_readers_test.go` are derived from the
documented regex semantics of the implementation: `extractJSONString` uses `[^"]*` capture so an
unclosed-quote value returns `""`; `extractJSONInt` uses `\d+` and returns the -1 sentinel on
absent or string-valued keys; `parseCauseBlock` scans to the first `{`…`}` block so a missing
closing brace returns zero values; `extractKVLine` key regex is `[a-z_]+` so a bare `{` line
returns `false`. No hard-coded magic numbers, no `assertTrue(true)` patterns.

**WEAKENING — none.** The 10 pre-existing test functions in `diagnose_test.go` (lines 33–186,
covering the m17 `classify` / `classify-agent` / `recovery` / `redact` / `is-transient`
subcommands) were not touched. The tester added 3 new functions only (`TestDiagnoseRun_HelpExits0`,
`TestDiagnoseRun_EmptyProjectDirReportsNoState`, `TestDiagnoseRun_PopulatedFixtureOutputsClassification`).
`engine_readers_test.go` is an entirely new file.

**SCOPE — none.** All four private functions under test exist in the current implementation:
`extractJSONString` (engine.go:232), `extractJSONInt` (engine.go:247),
`parseCauseBlock` (engine.go:269), `extractKVLine` (engine.go:306). The deleted file
`.tekhton/stage_results/stage_tester_r1_b0.json` is not referenced by any audited test.
No orphaned imports or stale symbol references detected.

**EXERCISE — none.** All four functions in `engine_readers_test.go` are called directly with
non-trivial inputs. The three new `diagnose_test.go` functions drive the real CLI through
`cmd.Execute()` against a real temp directory; no dependency is mocked.

**ISOLATION — none.** All `engine_readers_test.go` tests use inline string literals — zero file I/O,
zero environment dependencies, all subtests declared `t.Parallel()`. The two new
`diagnose_test.go` tests that call `t.Setenv` correctly omit `t.Parallel()` to prevent
process-level env-var races; `TestDiagnoseRun_HelpExits0` calls `t.Parallel()` safely because it
touches no environment variables. `TestDiagnoseRun_EmptyProjectDirReportsNoState` and
`TestDiagnoseRun_PopulatedFixtureOutputsClassification` both use `t.TempDir()` for fixture
materialization — no mutable project files are read without a controlled copy.

**NAMING — none.** All subtest names encode both scenario and expected outcome. Examples:
`"key absent returns negative one"`, `"malformed — no closing quote on value"`,
`"block key absent"`, `"multi-value nested — second cause block does not pollute first"`,
`TestDiagnoseRun_EmptyProjectDirReportsNoState`, `TestDiagnoseRun_PopulatedFixtureOutputsClassification`.
Top-level names follow the `TestSubject_Scenario` convention throughout.
