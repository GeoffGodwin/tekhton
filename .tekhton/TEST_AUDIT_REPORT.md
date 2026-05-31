## Test Audit Report

### Audit Summary
Tests audited: 3 files, 9 test functions (37 sub-test cases across 4 tables in engine_readers_test.go; 1 new function in diagnose_test.go; 4 new sub-tests added to TestPreflightInteractiveConfig_Match in resilience_test.go)
Verdict: PASS

---

### Findings

#### COVERAGE: CLI smoke test asserts wiring, not classification value
- File: `cmd/tekhton/diagnose_test.go:270` (`TestDiagnoseRun_PopulatedFixtureOutputsClassification`)
- Issue: The fixture writes `"classification":"MAX_TURNS_EXHAUSTED"` into
  `LAST_FAILURE_CONTEXT.json`, but the test only asserts that `"Classification:"`
  appears in stdout — not the specific value. The engine would return
  `Classification: MAX_TURNS_EXHAUSTED` when the `MaxTurns` rule fires correctly,
  or `Classification: UNKNOWN` when no rule matches. Both outputs satisfy the
  current assertion, so a rule-registry regression on the `MAX_TURNS_EXHAUSTED`
  path would not be caught here. Prior test coverage for this accuracy gap was
  `TestBashAdapterIntegration_MaxTurnsCoder` in `engine_test.go`, which was
  deleted in m32.2. That test's coverage moved to `TestParity_AllFixtures` in
  `internal/diagnose/rules/rules_test.go`, which does exercise the full
  15-fixture baseline — so accuracy IS covered, just not at the CLI layer.
- Severity: MEDIUM
- Action: Strengthen to assert the expected classification:
  `strings.Contains(out, "Classification: MAX_TURNS_EXHAUSTED")`. This gives
  the CLI smoke test meaningful regression signal independent of the parity gate.
  If the intentional-weakness argument is retained (the test is meant as a
  plumbing check only), add an inline comment cross-referencing
  `TestParity_AllFixtures` as the accuracy gate.

#### COVERAGE: `TestPreflightInteractiveConfig_Match` source-1 negative paths absent
- File: `internal/diagnose/rules/resilience_test.go:126` (`TestPreflightInteractiveConfig_Match`)
- Issue: Source 1 (RUN_SUMMARY `preflight_ui` section) is tested with one
  positive case (`interactive_config_detected:true, reporter_auto_patched:false`).
  Two negative branches of the `detected == "true" && patched == "false"` guard
  are not exercised: (a) `interactive_config_detected:false` (not detected →
  should not match), and (b) `reporter_auto_patched:true` (already patched →
  should not match). A logic inversion in either comparison would not be caught
  at this layer. The "no signal → no match" sub-test at line 177 uses an
  entirely empty context (no files at all) and therefore does not substitute
  for these.
- Severity: MEDIUM
- Action: Add two sub-tests under source 1:
  - `"source 1: detected=false → no match"`: write `interactive_config_detected:false`
    in the preflight_ui block and assert `!ok`.
  - `"source 1: patched=true → no match"`: write `reporter_auto_patched:true`
    and assert `!ok`.

---

### Non-Findings (all rubric points examined, no issues)

**INTEGRITY:** All expected values in the audit files derive from documented
implementation behavior. `extractJSONString` captures `[^"]*` so an unclosed
quote value returns `""` (`engine.go:249`). `extractJSONInt` returns the -1
sentinel on missing or string-valued keys (`engine.go:267`). `parseCauseBlock`
scans to the first `{`…`}` so a missing closing brace returns zero values
(`engine.go:291`). `extractKVLine` returns `(key, "", true)` for integer-valued
fields because `valRe` requires quoted values and falls back to the key-only path
(`engine.go:324`). No hard-coded magic numbers, no `assertTrue(true)` patterns.
The `parseCauseBlock` "first cause block does not pollute second" invariant is
correctly tested against the implementation's `strings.Index(tail[braceIdx:], "}")` 
first-match semantics.

**WEAKENING:** No pre-existing test assertions were broadened or removed.
`engine_readers_test.go` is entirely new. The tester added four new sub-tests to
`TestPreflightInteractiveConfig_Match` (sources 2, 2-negative, 3a, 3b) without
touching any existing assertion. The `diagnose_test.go` modification added one
new test function only; the 10 pre-existing `classify`/`classify-agent`/`recovery`/
`redact`/`is-transient` tests (lines 33–186) are untouched. The source-2 negative
sub-test ("header present but no fail word → no match") was not claimed in the
TESTER_REPORT but is a legitimate addition that correctly exercises the
`hasHeader && MatchPreflightReportFailWord` conjunction.

**SCOPE:** All symbols referenced in the audit files exist in the current codebase.
`extractJSONString`, `extractJSONInt`, `parseCauseBlock`, `extractKVLine` are
present in `engine.go:242–327`. `UIGateInteractiveReporter`, `BuildFixExhausted`,
`PreflightInteractiveConfig` are present in `resilience.go` and
`resilience_preflight.go`. The deleted files (`bash_rule_adapter.go`,
`bash_rule_adapter_test.go`, `.tekhton/stage_results/stage_tester_r1_b0.json`)
are not imported or referenced in any audit file.

**EXERCISE:** All test functions call real implementation code with non-trivial
inputs. `engine_readers_test.go` calls four unexported functions directly via
`package diagnose` (white-box). `resilience_test.go` invokes rule `Match()`
methods with real file I/O through `writeFile` + `t.TempDir()`. The new
`diagnose_test.go` test exercises the full CLI stack via `cmd.Execute()` against a
materialised temp-dir project — no dependencies mocked.

**ISOLATION:** `engine_readers_test.go` uses only inline string literals — zero
file I/O, zero environment dependencies, all tests and sub-tests declared
`t.Parallel()`. The new `diagnose_test.go` test omits `t.Parallel()` correctly
(uses `t.Setenv`) and creates a fresh `t.TempDir()` project root, writing its
own `LAST_FAILURE_CONTEXT.json`. `resilience_test.go` additions all use
`t.TempDir()` + `writeFile` for fixture setup; no test reads from live pipeline
artifacts, run logs, or mutable project state.

**NAMING:** All test and sub-test names encode both scenario and expected outcome.
Examples: `"malformed — no closing quote on value"`, `"block key absent"`,
`"multi-value nested — second cause block does not pollute first"`,
`"source 2: header present but no fail word → no match"`,
`TestDiagnoseRun_PopulatedFixtureOutputsClassification`. The `TestExtract*` and
`TestParse*` top-level names follow the `TestSubject` convention throughout.
